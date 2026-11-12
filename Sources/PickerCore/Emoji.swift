import CoreText
import Foundation

public enum EmojiCategory: String, Codable, CaseIterable, Sendable {
    case smileys, people, animals, food, travel, activities, objects, symbols, flags
}

public enum SkinTone: Int, Codable, CaseIterable, Sendable {
    case none = -1, light, mediumLight, medium, mediumDark, dark
}

public struct Emoji: Codable, Hashable, Sendable {
    public let e: String
    public let n: String
    public let k: [String]
    public let c: EmojiCategory
    /// Five skin-tone variants, light to dark, when the emoji supports them.
    public let v: [String]?

    public init(e: String, n: String, k: [String], c: EmojiCategory, v: [String]? = nil) {
        self.e = e; self.n = n; self.k = k; self.c = c; self.v = v
    }
}

public struct EmojiCatalog: Sendable {
    public let emojis: [Emoji]

    private struct Indexed: Sendable {
        let name: String
        let nameWords: [String]
        let keywordWords: [String]
    }
    private let index: [Indexed]

    public init(emojis: [Emoji]) {
        self.emojis = emojis
        self.index = emojis.map { e in
            Indexed(
                name: Self.fold(e.n),
                nameWords: Self.words(e.n),
                keywordWords: e.k.flatMap(Self.words)
            )
        }
    }

    public static func loadBundled() throws -> EmojiCatalog {
        guard let url = ResourceLocator.url("emoji", ext: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return EmojiCatalog(emojis: try JSONDecoder().decode([Emoji].self, from: data))
    }

    public func inCategory(_ c: EmojiCategory) -> [Emoji] {
        emojis.filter { $0.c == c }
    }

    /// Every query word must prefix-match a word of the name or keywords.
    /// Ranked: exact name, then all words match name words, then keyword matches.
    public func search(_ q: String) -> [Emoji] {
        let query = Self.words(q)
        guard !query.isEmpty else { return [] }
        let whole = Self.fold(q).trimmingCharacters(in: .whitespacesAndNewlines)
        var buckets: [[Emoji]] = [[], [], []]
        for (i, entry) in index.enumerated() {
            let allInName = query.allSatisfy { w in entry.nameWords.contains { $0.hasPrefix(w) } }
            let matchesAll = query.allSatisfy { w in
                entry.nameWords.contains { $0.hasPrefix(w) } || entry.keywordWords.contains { $0.hasPrefix(w) }
            }
            guard matchesAll else { continue }
            if entry.name == whole { buckets[0].append(emojis[i]) }
            else if allInName { buckets[1].append(emojis[i]) }
            else { buckets[2].append(emojis[i]) }
        }
        return buckets.flatMap { $0 }
    }

    public static func apply(_ t: SkinTone, to e: Emoji) -> String {
        guard t != .none, let v = e.v, v.indices.contains(t.rawValue) else { return e.e }
        return v[t.rawValue]
    }

    /// Drops emoji the system cannot draw. Runs CoreText per emoji, so call it off the main thread.
    public func renderableOnly() -> EmojiCatalog {
        EmojiCatalog(emojis: emojis.filter { Self.isRenderable($0.e) })
    }

    // CTFont is thread-safe and immutable; created once rather than per call.
    nonisolated(unsafe) private static let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, 16, nil)

    private static let emojiFontName = CTFontCopyPostScriptName(emojiFont) as String

    /// True when the emoji font itself draws the whole string as exactly one visible glyph. Every
    /// run must use the emoji font: CoreText silently substitutes the LastResort font for
    /// characters the emoji font lacks (emoji newer than the installed OS), and that font's glyph
    /// is a boxed question mark. No glyph may be the missing glyph (0), and exactly one may have a
    /// non-zero advance. Some real sequences (kiss, couple-with-heart) lay out as a zero-advance
    /// glyph plus the visible one; an unsupported ZWJ sequence falls apart into several
    /// advancing component glyphs.
    public static func isRenderable(_ s: String) -> Bool {
        let attributed = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): emojiFont,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
        var visible = 0
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { return false }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] as! CTFont?,
                  CTFontCopyPostScriptName(runFont) as String == emojiFontName
            else { return false }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &advances)
            for i in 0..<n {
                if glyphs[i] == 0 { return false }
                if advances[i].width > 0 { visible += 1 }
            }
        }
        return visible == 1
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
