import Foundation

/// Most-recently-used list persisted as JSON. Newest first, deduplicated, capped at `limit`.
public final class RecentsStore<T: Codable & Hashable> {
    public static var emojiLimit: Int { 36 }
    public static var kaomojiLimit: Int { 18 }
    public static var symbolsLimit: Int { 36 }
    public static var gifLimit: Int { 20 }

    private let fileURL: URL
    private let limit: Int
    public private(set) var items: [T]

    public init(fileURL: URL, limit: Int) {
        self.fileURL = fileURL
        self.limit = limit
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([T].self, from: data) {
            items = Array(decoded.prefix(limit))
        } else {
            items = []
        }
    }

    public func record(_ x: T) {
        items.removeAll { $0 == x }
        items.insert(x, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // Recents are a convenience; failing to persist must never disturb the picker.
        }
    }
}
