import Foundation
import CoreGraphics

public struct GifResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let slug: String
    public let tags: [String]
    public let previewURL: URL
    public let previewWidth: Double
    public let previewHeight: Double
    public let originalURL: URL
    /// GIPHY's `downsized` rendition (under 2 MB), used when the original is too big to paste.
    /// Optional so recents saved before it existed still decode.
    public let downsizedURL: URL?

    public var previewSize: CGSize { CGSize(width: previewWidth, height: previewHeight) }

    /// Renditions to try for pasting, best first.
    public var pasteURLs: [URL] { [originalURL] + (downsizedURL.map { [$0] } ?? []) }

    public init(id: String, title: String, slug: String, tags: [String] = [],
                previewURL: URL, previewSize: CGSize, originalURL: URL, downsizedURL: URL? = nil) {
        self.id = id
        self.title = title
        self.slug = slug
        self.tags = tags
        self.previewURL = previewURL
        self.previewWidth = Double(previewSize.width)
        self.previewHeight = Double(previewSize.height)
        self.originalURL = originalURL
        self.downsizedURL = downsizedURL
    }
}

public enum GiphyError: Error, Equatable, Sendable {
    case missingKey, invalidKey, rateLimited, offline
    case server(Int)
}

public protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPFetching {
    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Wire format

private struct GiphyPage: Decodable {
    struct Pagination: Decodable {
        let total_count: Int?
        let count: Int?
        let offset: Int?
    }
    let data: [GiphyGifDTO]
    let pagination: Pagination?
}

private struct GiphyGifDTO: Decodable {
    struct Rendition: Decodable {
        let url: String?
        let webp: String?
        let width: String?
        let height: String?
    }
    struct Images: Decodable {
        let fixed_width: Rendition?
        let original: Rendition?
        let downsized: Rendition?
    }
    let id: String
    let title: String?
    let slug: String?
    let tags: [String]?
    let images: Images?

    func toResult() -> GifResult? {
        guard let fixed = images?.fixed_width,
              // GIF first: NSImageView animates GIF but shows only the first frame of an animated webp.
              let preview = (fixed.url ?? fixed.webp).flatMap(URL.init(string:)),
              let original = images?.original?.url.flatMap(URL.init(string:))
        else { return nil }
        return GifResult(
            id: id, title: title ?? "", slug: slug ?? "", tags: tags ?? [],
            previewURL: preview,
            previewSize: CGSize(width: Double(fixed.width ?? "") ?? 0,
                                height: Double(fixed.height ?? "") ?? 0),
            originalURL: original,
            downsizedURL: images?.downsized?.url.flatMap(URL.init(string:)))
    }
}

// MARK: - Client

public struct GiphyClient: Sendable {
    private let apiKey: String?
    private let rating: String
    private let http: HTTPFetching

    public init(apiKey: String?, rating: String = "pg-13", http: HTTPFetching) {
        self.apiKey = apiKey
        self.rating = rating
        self.http = http
    }

    public func search(_ q: String, offset: Int, limit: Int = 50) async throws
        -> (results: [GifResult], nextOffset: Int?) {
        try await fetch(path: "search", q: q, offset: offset, limit: limit)
    }

    public func trending(offset: Int, limit: Int = 50) async throws
        -> (results: [GifResult], nextOffset: Int?) {
        try await fetch(path: "trending", q: nil, offset: offset, limit: limit)
    }

    private func fetch(path: String, q: String?, offset: Int, limit: Int) async throws
        -> (results: [GifResult], nextOffset: Int?) {
        guard let key = apiKey, !key.isEmpty else { throw GiphyError.missingKey }
        var c = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)")!
        var items = [URLQueryItem(name: "api_key", value: key)]
        if let q { items.append(URLQueryItem(name: "q", value: q)) }
        items += [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: rating),
            URLQueryItem(name: "lang", value: "en"),
        ]
        c.queryItems = items
        guard let url = c.url else { throw GiphyError.server(0) }

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.get(url)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw GiphyError.offline
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw GiphyError.invalidKey
        case 429: throw GiphyError.rateLimited
        default: throw GiphyError.server(response.statusCode)
        }
        guard let page = try? JSONDecoder().decode(GiphyPage.self, from: data) else {
            throw GiphyError.server(response.statusCode)
        }
        let results = page.data.compactMap { $0.toResult() }
        let count = page.pagination?.count ?? page.data.count
        let next = offset + count
        var more = page.data.count >= limit && count > 0
        if let total = page.pagination?.total_count, next >= total { more = false }
        return (results, more ? next : nil)
    }
}

// MARK: - Search session

/// Pages through GIPHY results, filtering with the query's required words.
public actor GifSearchSession {
    private let client: GiphyClient
    private let query: GifQuery
    private let target: Int
    private let maxPages: Int
    private let pageSize = 50
    private var nextOffset: Int? = 0
    private var pagesFetched = 0
    private var failure: GiphyError?
    private var deferred: GiphyError?

    public init(client: GiphyClient, query: GifQuery, target: Int = 24, maxPages: Int = 5) {
        self.client = client
        self.query = query
        self.target = target
        self.maxPages = maxPages
    }

    /// Matches gathered by this call. Empty means exhausted.
    public func nextBatch() async throws -> [GifResult] {
        if failure == .rateLimited { throw GiphyError.rateLimited }
        if let e = deferred { deferred = nil; throw e }
        var batch: [GifResult] = []
        let unfiltered = query.requiredWords.isEmpty
        while let offset = nextOffset, pagesFetched < maxPages {
            pagesFetched += 1
            let page: (results: [GifResult], nextOffset: Int?)
            do {
                page = try await client.search(query.apiQuery, offset: offset, limit: pageSize)
            } catch let e as GiphyError {
                if e == .rateLimited { failure = e }
                if batch.isEmpty { throw e }
                deferred = e
                return batch
            }
            nextOffset = page.nextOffset
            batch += page.results.filter { query.matches($0) }
            if unfiltered || batch.count >= target { break }
        }
        return batch
    }
}
