import Testing
import Foundation
@testable import PickerCore

private actor Counter {
    private(set) var urls: [URL] = []
    func record(_ u: URL) { urls.append(u) }
}

private struct StubHTTP: Sendable {
    let counter = Counter()
    let handler: @Sendable (URL, Int) throws -> (Data, Int)
}

extension StubHTTP: HTTPFetching {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        await counter.record(url)
        let n = await counter.urls.count
        let (data, status) = try handler(url, n)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

private func offset(of url: URL) -> Int {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    return Int(items?.first { $0.name == "offset" }?.value ?? "") ?? -1
}

private func fixtureStub() -> StubHTTP {
    StubHTTP { url, _ in (fixture(offset(of: url) == 0 ? "search-page0" : "search-page1"), 200) }
}

@Suite struct GiphyTests {
    @Test func decodesFixture() async throws {
        let client = GiphyClient(apiKey: "k", http: fixtureStub())
        let page = try await client.search("cat", offset: 0, limit: 50)
        #expect(page.results.count == 50)
        #expect(page.results[0].previewURL.pathExtension == "gif") // NSImageView animates GIF, not webp
        #expect(page.results[0].originalURL.pathExtension == "gif")
        #expect(page.results[0].previewSize.width == 200)
        #expect(page.results[0].tags == [])
        #expect(page.nextOffset == 50)
    }

    @Test func previewFallsBackToWebpWithoutGifURL() async throws {
        let json = #"{"data":[{"id":"a","images":{"fixed_width":{"webp":"https://m/a.webp","width":"200","height":"100"},"original":{"url":"https://m/a.gif"}}}]}"#
        let client = GiphyClient(apiKey: "k", http: StubHTTP { _, _ in (Data(json.utf8), 200) })
        let page = try await client.search("x", offset: 0, limit: 50)
        #expect(page.results.map(\.previewURL.absoluteString) == ["https://m/a.webp"])
    }

    @Test func decodesDownsizedURL() async throws {
        let json = #"{"data":[{"id":"a","images":{"fixed_width":{"url":"https://m/a/200w.gif","width":"200","height":"100"},"original":{"url":"https://m/a/giphy.gif"},"downsized":{"url":"https://m/a/giphy-downsized.gif"}}}]}"#
        let client = GiphyClient(apiKey: "k", http: StubHTTP { _, _ in (Data(json.utf8), 200) })
        let gif = try #require(try await client.search("x", offset: 0, limit: 50).results.first)
        #expect(gif.downsizedURL?.absoluteString == "https://m/a/giphy-downsized.gif")
        #expect(gif.pasteURLs.map(\.absoluteString) == ["https://m/a/giphy.gif", "https://m/a/giphy-downsized.gif"])
    }

    @Test func downsizedIsOptional() async throws {
        let page = try await GiphyClient(apiKey: "k", http: fixtureStub()).search("cat", offset: 0, limit: 50)
        #expect(page.results[0].downsizedURL == nil)
        #expect(page.results[0].pasteURLs == [page.results[0].originalURL])
    }

    @Test func recentsSavedBeforeDownsizedStillDecode() throws {
        let old = #"[{"id":"a","title":"t","slug":"s","tags":[],"previewURL":"https://m/a.gif","previewWidth":200,"previewHeight":100,"originalURL":"https://m/o.gif"}]"#
        let decoded = try JSONDecoder().decode([GifResult].self, from: Data(old.utf8))
        #expect(decoded.count == 1 && decoded[0].downsizedURL == nil)
    }

    @Test func requestShape() async throws {
        let stub = fixtureStub()
        _ = try await GiphyClient(apiKey: "k", http: stub).search("a b", offset: 0, limit: 50)
        let url = await stub.counter.urls[0]
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(c.path == "/v1/gifs/search")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(q["q"] == "a b" && q["rating"] == "pg-13" && q["limit"] == "50" && q["lang"] == "en")
    }

    @Test(arguments: [(401, GiphyError.invalidKey), (403, .invalidKey), (429, .rateLimited), (500, .server(500))])
    func statusMapping(status: Int, expected: GiphyError) async {
        let client = GiphyClient(apiKey: "k", http: StubHTTP { _, _ in (Data("{}".utf8), status) })
        await #expect(throws: expected) { try await client.search("x", offset: 0, limit: 50) }
    }

    @Test func offlineAndMissingKey() async {
        let off = GiphyClient(apiKey: "k", http: StubHTTP { _, _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: GiphyError.offline) { try await off.search("x", offset: 0, limit: 50) }
        let stub = fixtureStub()
        await #expect(throws: GiphyError.missingKey) {
            try await GiphyClient(apiKey: nil, http: stub).search("x", offset: 0, limit: 50)
        }
        #expect(await stub.counter.urls.isEmpty)
    }

    @Test func sessionFiltersAcrossPages() async throws {
        let stub = fixtureStub()
        let query = GifQuery.parse("\"cat dancing\"")
        let session = GifSearchSession(client: GiphyClient(apiKey: "k", http: stub), query: query)
        let batch = try await session.nextBatch()
        #expect(batch.count == 7)
        #expect(batch.allSatisfy { query.matches($0) })
        #expect(await stub.counter.urls.count == 2)
        #expect(try await session.nextBatch().isEmpty)
        #expect(await stub.counter.urls.count == 2)
    }

    @Test func unquotedIsOnePagePerBatch() async throws {
        let stub = fixtureStub()
        let session = GifSearchSession(client: GiphyClient(apiKey: "k", http: stub), query: .parse("cat"))
        #expect(try await session.nextBatch().count == 50)
        #expect(await stub.counter.urls.count == 1)
        #expect(try await session.nextBatch().count == 50)
        #expect(try await session.nextBatch().isEmpty)
    }

    @Test func sessionStopsAtMaxPages() async throws {
        let page0 = String(decoding: fixture("search-page0"), as: UTF8.self)
        let stub = StubHTTP { url, _ in
            // Always 50 non-matching results, with a total large enough to keep paging.
            let json = page0.replacingOccurrences(of: "\"total_count\": 100", with: "\"total_count\": 10000")
            return (Data(json.utf8), 200)
        }
        let session = GifSearchSession(client: GiphyClient(apiKey: "k", http: stub),
                                       query: .parse("\"zebra\""))
        #expect(try await session.nextBatch().isEmpty)
        #expect(await stub.counter.urls.count == 5)
        #expect(try await session.nextBatch().isEmpty)
        #expect(await stub.counter.urls.count == 5)
    }

    @Test func sessionStopsOnRateLimit() async throws {
        let stub = StubHTTP { url, n in
            n == 1 ? (fixture("search-page0"), 200) : (Data(), 429)
        }
        let session = GifSearchSession(client: GiphyClient(apiKey: "k", http: stub),
                                       query: .parse("\"zebra\""))
        await #expect(throws: GiphyError.rateLimited) { try await session.nextBatch() }
        #expect(await stub.counter.urls.count == 2)
        await #expect(throws: GiphyError.rateLimited) { try await session.nextBatch() }
        #expect(await stub.counter.urls.count == 2)
    }

    @Test func partialBatchSurvivesLaterFailure() async throws {
        let stub = StubHTTP { url, n in
            n == 1 ? (fixture("search-page0"), 200) : (Data(), 500)
        }
        let session = GifSearchSession(client: GiphyClient(apiKey: "k", http: stub),
                                       query: .parse("\"cat dancing\""))
        #expect(try await session.nextBatch().count == 3)
        await #expect(throws: GiphyError.server(500)) { try await session.nextBatch() }
        #expect(await stub.counter.urls.count == 2)
    }

    @Test func cancelledIsNotOffline() async {
        let client = GiphyClient(apiKey: "k", http: StubHTTP { _, _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { try await client.search("x", offset: 0, limit: 50) }
    }
}
