import Foundation
import Testing
@testable import PickerCore

@Suite struct SimpleItemsTests {
    @Test func kaomojiLoadsWithManySections() throws {
        let cat = try TextItemCatalog.load("kaomoji")
        #expect(cat.sections.count >= 10)
        #expect(cat.sections.allSatisfy { !$0.items.isEmpty })
    }

    @Test func kaomojiSearchFindsShrug() throws {
        let cat = try TextItemCatalog.load("kaomoji")
        #expect(cat.search("shrug").contains { $0.s == #"¯\_(ツ)_/¯"# })
        #expect(cat.search("tableflip").contains { $0.s == "(╯°□°)╯︵ ┻━┻" })
        #expect(cat.search("").isEmpty)
    }

    @Test func symbolsSearch() throws {
        let cat = try TextItemCatalog.load("symbols")
        #expect(cat.sections.count >= 7)
        #expect(cat.search("euro").contains { $0.s == "€" })
        #expect(cat.search("degree").contains { $0.s == "°" })
        #expect(cat.search("arrow").contains { $0.s == "→" })
        #expect(cat.search("€").contains { $0.s == "€" })
    }

    @Test(arguments: ["kaomoji", "symbols"])
    func noDuplicateItemsWithinAFile(name: String) throws {
        let all = try TextItemCatalog.load(name).sections.flatMap(\.items).map(\.s)
        #expect(Set(all).count == all.count)
    }

    @Test func shrugKeepsBackslashAndUnderscoresThroughJSON() throws {
        let shrug = #"¯\_(ツ)_/¯"#
        let json = try JSONEncoder().encode([TextItemSection(title: "t", items: [TextItem(s: shrug, k: ["shrug"])])])
        #expect(String(decoding: json, as: UTF8.self).contains(#"¯\\_(ツ)_"#))
        let decoded = try JSONDecoder().decode([TextItemSection].self, from: json)
        #expect(decoded[0].items[0].s == shrug)
        #expect(decoded[0].items[0].s.contains("\\"))

        let raw = try String(contentsOf: #require(ResourceLocator.url("kaomoji", ext: "json")), encoding: .utf8)
        #expect(raw.contains(#"¯\\_(ツ)_/¯"#)) // JSON-escaped backslash on disk

        let bundled = try TextItemCatalog.load("kaomoji").search("shrug").first { $0.s == shrug }
        #expect(bundled?.s.unicodeScalars.contains("\\") == true)
        #expect(bundled?.s.filter { $0 == "_" }.count == 2)
    }
}
