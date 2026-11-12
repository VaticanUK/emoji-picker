import Foundation

public struct TextItemSection: Codable, Sendable {
    public let title: String
    public let items: [TextItem]

    public init(title: String, items: [TextItem]) {
        self.title = title
        self.items = items
    }
}

/// One kaomoji or symbol. `s` is the exact string to insert; `k` are search keywords.
public struct TextItem: Codable, Hashable, Sendable {
    public let s: String
    public let k: [String]

    public init(s: String, k: [String]) {
        self.s = s
        self.k = k
    }
}

/// A sectioned catalog of text items, shared by the Kaomoji and Symbols tabs.
public struct TextItemCatalog: Sendable {
    public let sections: [TextItemSection]
    private let index: [(item: TextItem, folded: String, words: [String])]

    public init(sections: [TextItemSection]) {
        self.sections = sections
        var seen = Set<String>()
        index = sections.flatMap(\.items).compactMap { item in
            guard seen.insert(item.s).inserted else { return nil }
            return (item, Self.fold(item.s), item.k.flatMap(Self.words))
        }
    }

    /// `name` is the bundled JSON file's name without extension (`kaomoji` or `symbols`).
    public static func load(_ name: String) throws -> TextItemCatalog {
        guard let url = ResourceLocator.url(name, ext: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return TextItemCatalog(sections: try JSONDecoder().decode([TextItemSection].self, from: data))
    }

    /// Every query word must prefix-match a keyword, or the query must appear in the item itself
    /// (so pasting `€` finds `€`). Items with an exact keyword match come first.
    public func search(_ q: String) -> [TextItem] {
        let query = Self.words(q)
        let whole = Self.fold(q).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        var exact: [TextItem] = []
        var rest: [TextItem] = []
        for entry in index {
            let byKeyword = !query.isEmpty && query.allSatisfy { w in entry.words.contains { $0.hasPrefix(w) } }
            guard byKeyword || entry.folded.contains(whole) else { continue }
            if !query.isEmpty, query.allSatisfy({ entry.words.contains($0) }) {
                exact.append(entry.item)
            } else {
                rest.append(entry.item)
            }
        }
        return exact + rest
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
