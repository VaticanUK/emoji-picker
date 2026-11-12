import Foundation

/// A GIF search string split into what GIPHY is asked and what must match locally.
public struct GifQuery: Equatable, Sendable {
    /// The query sent to GIPHY, with quote characters removed.
    public let apiQuery: String
    /// Lowercased words that must all appear in a result's searchable text.
    public let requiredWords: [String]

    public init(apiQuery: String, requiredWords: [String]) {
        self.apiQuery = apiQuery
        self.requiredWords = requiredWords
    }

    private static let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    /// Text inside `"..."` is required. An unbalanced quote runs to the end;
    /// empty quotes are ignored.
    public static func parse(_ raw: String) -> GifQuery {
        var required: [String] = []
        var inQuotes = false
        var segment = ""

        func flush() {
            if inQuotes { required.append(contentsOf: tokens(segment)) }
            segment = ""
        }
        for ch in raw {
            if Self.quoteChars.contains(ch) {
                flush()
                inQuotes.toggle()
            } else {
                segment.append(ch)
            }
        }
        flush()

        let api = raw.map { Self.quoteChars.contains($0) ? " " : $0 }.map(String.init).joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return GifQuery(apiQuery: api, requiredWords: required)
    }

    /// True when every required word is a whole word (or its simple plural)
    /// in the title, slug words or tags. Always true without required words.
    public func matches(_ gif: GifResult) -> Bool {
        guard !requiredWords.isEmpty else { return true }
        var searchable = Set(Self.tokens(gif.title))
        var slugParts = gif.slug.split(separator: "-").map(String.init)
        if slugParts.last == gif.id { slugParts.removeLast() }
        for part in slugParts { searchable.formUnion(Self.tokens(part)) }
        for tag in gif.tags { searchable.formUnion(Self.tokens(tag)) }
        return requiredWords.allSatisfy { word in
            searchable.contains(word) || searchable.contains(word + "s")
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }
}
