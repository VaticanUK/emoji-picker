import Testing
import Foundation
@testable import PickerCore

@Suite struct GifQueryTests {
    private func gif(_ title: String, slug: String = "x-id1", tags: [String] = [], id: String = "id1") -> GifResult {
        let u = URL(string: "https://example.com/a.gif")!
        return GifResult(id: id, title: title, slug: slug, tags: tags,
                         previewURL: u, previewSize: .init(width: 1, height: 1), originalURL: u)
    }

    @Test func parsesPlainAndQuoted() {
        #expect(GifQuery.parse("cat dancing") == GifQuery(apiQuery: "cat dancing", requiredWords: []))
        #expect(GifQuery.parse("\"cat dancing\"") == GifQuery(apiQuery: "cat dancing", requiredWords: ["cat", "dancing"]))
        #expect(GifQuery.parse("\"thumbs up\" happy") == GifQuery(apiQuery: "thumbs up happy", requiredWords: ["thumbs", "up"]))
    }

    @Test func oddQueries() {
        #expect(GifQuery.parse("\"cat dancing").requiredWords == ["cat", "dancing"])
        let empty = GifQuery.parse("\"\" cat")
        #expect(empty.requiredWords == [] && empty.apiQuery == "cat")
        #expect(GifQuery.parse("\"Cat,\" dance").requiredWords == ["cat"])
        #expect(GifQuery.parse("\"a\" b \"c d\"").requiredWords == ["a", "c", "d"])
    }

    @Test func curlyQuotesCountAsQuotes() {
        #expect(GifQuery.parse("\u{201C}cat dancing\u{201D}") == GifQuery(apiQuery: "cat dancing", requiredWords: ["cat", "dancing"]))
    }

    @Test func matching() {
        let q = GifQuery.parse("\"cat dancing\"")
        #expect(q.matches(gif("Dancing Cat GIF")))
        #expect(!q.matches(gif("Cat GIF", tags: ["cute"])))
        #expect(q.matches(gif("GIF", slug: "happy-cat-dancing-abc123", id: "abc123")))
        #expect(!GifQuery.parse("\"cat\"").matches(gif("Category GIF")))
        #expect(GifQuery.parse("\"cat\"").matches(gif("Cats GIF")))
        #expect(GifQuery.parse("\"cute\"").matches(gif("Cat GIF", tags: ["Cute"])))
        #expect(GifQuery.parse("cat").matches(gif("Anything")))
    }

    @Test func slugLastSegmentKeptWhenNotId() {
        let q = GifQuery.parse("\"dancing\"")
        #expect(q.matches(gif("GIF", slug: "happy-cat-dancing", id: "other")))
        #expect(!GifQuery.parse("\"abc123\"").matches(gif("GIF", slug: "happy-abc123", id: "abc123")))
    }
}
