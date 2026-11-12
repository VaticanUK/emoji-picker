import Testing
@testable import PickerCore

@Suite struct EmojiCatalogTests {
    @Test func loadsBundled() throws {
        let cat = try EmojiCatalog.loadBundled()
        #expect(cat.emojis.count > 1800)
        #expect(cat.inCategory(.smileys).contains { $0.e == "😀" })
        #expect(!cat.inCategory(.people).contains { $0.e.contains("🏻") })
    }

    @Test func searchByNameAndKeyword() throws {
        let cat = try EmojiCatalog.loadBundled()
        #expect(cat.search("thumbs").first?.e == "👍")
        #expect(cat.search("laugh").contains { $0.e == "😂" })
        #expect(cat.search("").isEmpty)
    }

    @Test func searchIsPrefixPerWord() throws {
        let cat = try EmojiCatalog.loadBundled()
        #expect(cat.search("thu up").contains { $0.e == "👍" })
    }

    @Test func exactNameRanksFirst() throws {
        let cat = try EmojiCatalog.loadBundled()
        #expect(cat.search("cat").first?.n == "cat")
    }

    @Test func skinTone() throws {
        let cat = try EmojiCatalog.loadBundled()
        let thumbs = try #require(cat.emojis.first { $0.e == "👍" })
        #expect(EmojiCatalog.apply(.medium, to: thumbs) == "👍🏽")
        #expect(EmojiCatalog.apply(.none, to: thumbs) == "👍")
        let grin = try #require(cat.emojis.first { $0.e == "😀" })
        #expect(grin.v == nil)
        #expect(EmojiCatalog.apply(.dark, to: grin) == "😀")
    }

    @Test func renderability() throws {
        #expect(EmojiCatalog.isRenderable("😀"))
        #expect(EmojiCatalog.isRenderable("🇬🇧"))
        #expect(EmojiCatalog.isRenderable("#️⃣"))
        #expect(!EmojiCatalog.isRenderable("🐈\u{200D}🍕"))
        #expect(EmojiCatalog.isRenderable("👩\u{200D}❤\u{FE0F}\u{200D}💋\u{200D}👨"))
        #expect(EmojiCatalog.isRenderable("👨\u{200D}👩\u{200D}👧"))
        #expect(EmojiCatalog.isRenderable("❤\u{FE0F}"))
        // A character the emoji font lacks is drawn by the LastResort fallback font as a boxed
        // question mark: one visible, non-zero glyph, but not renderable. U+F0000 is private-use,
        // so no emoji font will ever contain it.
        #expect(!EmojiCatalog.isRenderable("\u{F0000}"))
        let full = try EmojiCatalog.loadBundled()
        let cat = full.renderableOnly()
        #expect(cat.emojis.contains { $0.e == "😀" })
        // Emoji newer than the installed font are dropped; everything older must survive. The
        // bundled data is a release or two ahead of the OS, so a few dozen drops are expected.
        #expect(cat.emojis.count >= full.emojis.count - 60, "silent drops of legitimate emoji")
        #expect(cat.emojis.count < full.emojis.count || EmojiCatalog.isRenderable("\u{1FAEB}"))
    }
}
