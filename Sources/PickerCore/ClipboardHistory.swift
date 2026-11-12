import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os

/// One remembered clipboard entry. Its pasteboard data lives in files next to the index.
public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// A preview of at most `ClipboardHistory.previewBytes` UTF-8 bytes; the full text is in
        /// the item's data files.
        case text(String)
        /// `fileName` is the data file of the image type used for thumbnails (png if present, else tiff).
        case image(fileName: String)
    }

    public let id: UUID
    public let date: Date
    public var pinned: Bool
    public let kind: Kind
    /// Pasteboard type raw value → file name in the store directory.
    public let types: [String: String]
    /// SHA-256 (hex) of the full text or the image data, used to dedupe.
    public var contentHash: String?
    /// File name of a small PNG thumbnail (image items only; nil until it has been made).
    public var thumbnail: String?

    public init(id: UUID = UUID(), date: Date = Date(), pinned: Bool = false, kind: Kind,
                types: [String: String], contentHash: String? = nil, thumbnail: String? = nil) {
        self.id = id
        self.date = date
        self.pinned = pinned
        self.kind = kind
        self.types = types
        self.contentHash = contentHash
        self.thumbnail = thumbnail
    }

    /// The files this item owns: its pasteboard data plus its thumbnail.
    var fileNames: [String] { Array(types.values) + (thumbnail.map { [$0] } ?? []) }
}

/// Clipboard history: newest first, `limit` unpinned items (pinned ones don't count), persisted as
/// `history.json` plus one `<uuid>-<n>.bin` file per stored pasteboard type (and a
/// `<uuid>-thumb.bin` PNG thumbnail for images). The index holds only text previews, so it stays
/// small. Kept in memory; the clipboard monitor feeds it. History can hold private text, so the
/// directory is 0700 and excluded from backups.
@MainActor
public final class ClipboardHistory {
    public static let maxItemBytes = 10_000_000
    /// Text items keep at most this many UTF-8 bytes in the index (for display and search).
    public static let previewBytes = 4_096
    public nonisolated static let thumbnailMaxPixels = 128
    /// Index writes and file deletions run here, in order, off the main thread. Shared by all
    /// instances so a new one can wait for an old one's writes (`init` flushes it).
    private static let ioQueue = DispatchQueue(label: "com.emojipicker.clipboard-io", qos: .utility)
    private nonisolated static let log = Logger(subsystem: "com.emojipicker.app", category: "clipboard")

    static let utf8Type = NSPasteboard.PasteboardType("public.utf8-plain-text")
    /// `.string` is `public.utf8-plain-text` on current macOS; listing both keeps older systems
    /// covered, and the list is de-duplicated so one type never gets two files.
    private static let textTypes: [NSPasteboard.PasteboardType] =
        [.string, utf8Type, .rtf].reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// The pasteboard types the monitor needs to read: the ones that decide whether to skip an
    /// item (their data is irrelevant) and the ones that get stored.
    public static let inspectedTypes: Set<NSPasteboard.PasteboardType> =
        Set(textTypes + imageTypes + [OwnMarker.type]).union(PasteboardSnapshot.sensitiveTypes)

    private static let backupPrefix = "history.json.corrupt-"
    private static let backupMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private let directory: URL
    private let limit: Int
    /// False when an unreadable index couldn't be moved aside: `save()` then never writes
    /// history.json this session, so the original stays on disk and history lives in memory only.
    private var indexWritable = true
    /// Newest first (pinned and unpinned interleaved by recency).
    public private(set) var items: [ClipItem]
    /// Called after every change to `items`: ingest, delete, pin toggle and clear.
    public var onChange: (() -> Void)?
    private var pendingThumbnails: [UUID: Task<Void, Never>] = [:]

    public convenience init(directory: URL, limit: Int = 25) {
        self.init(directory: directory, limit: limit,
                  moveItem: { try FileManager.default.moveItem(at: $0, to: $1) })
    }

    /// `moveItem` moves an unreadable index aside; tests inject a failing one.
    init(directory: URL, limit: Int, moveItem: (URL, URL) throws -> Void) {
        self.directory = directory
        self.limit = limit
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var backupExcluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? backupExcluded.setResourceValues(values)
        Self.ioQueue.sync {} // another instance's pending writes to this directory land first
        let index = directory.appendingPathComponent("history.json")
        var indexTrusted = true
        items = []
        removeBackups { date in date.map { Date().timeIntervalSince($0) > Self.backupMaxAge } ?? false }
        if fm.fileExists(atPath: index.path) {
            if let data = try? Data(contentsOf: index),
               let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
                items = decoded.map(Self.migrated)
                if items != decoded { save() }
            } else {
                // Unreadable or undecodable index: keep one backup, start fresh, and don't sweep on
                // this launch since the data files may still matter.
                indexTrusted = false
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
                let name = "\(Self.backupPrefix)\(stamp.string(from: Date()))-\(suffix)"
                do {
                    try moveItem(index, directory.appendingPathComponent(name))
                    removeBackups(except: name) // history can hold private text: keep only the newest
                    Self.log.error("clipboard index unreadable; moved to \(name, privacy: .public)")
                } catch {
                    indexWritable = false
                    Self.log.error("clipboard index unreadable and could not be moved; history is not saved this session: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if indexTrusted { sweepOrphans() }
        for item in items where item.thumbnail == nil {
            if case .image(let name) = item.kind, !name.isEmpty { makeThumbnail(for: item.id, from: name) }
        }
    }

    /// Items from indexes written before previews: the index held the full text and no hash.
    /// The full text is also in the item's data file, so the index copy is just truncated.
    private static func migrated(_ item: ClipItem) -> ClipItem {
        guard case .text(let s) = item.kind else { return item }
        let preview = preview(of: s)
        guard item.contentHash == nil || preview.utf8.count != s.utf8.count else { return item }
        return ClipItem(id: item.id, date: item.date, pinned: item.pinned, kind: .text(preview),
                        types: item.types, contentHash: item.contentHash ?? hash(Data(s.utf8)),
                        thumbnail: item.thumbnail)
    }

    /// The longest prefix of `s` (whole Unicode scalars) that fits in `previewBytes` UTF-8 bytes.
    static func preview(of s: String) -> String {
        guard s.utf8.count > previewBytes else { return s }
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in s.unicodeScalars {
            let n = UTF8.width(scalar)
            if bytes + n > previewBytes { break }
            bytes += n
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes `history.json.corrupt-*` backups other than `except` for which `shouldRemove`
    /// (given the file's modification date) is true.
    private func removeBackups(except: String? = nil, where shouldRemove: (Date?) -> Bool = { _ in true }) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.backupPrefix) && name != except {
            let path = directory.appendingPathComponent(name).path
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if shouldRemove(modified) { removeFile(name) }
        }
    }

    /// Deletes `.bin` files the index doesn't reference (left by a crash between write and save).
    private func sweepOrphans() {
        let referenced = Set(items.flatMap(\.fileNames))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".bin") && !referenced.contains(name) { removeFile(name) }
    }

    // MARK: Ingest

    /// Adds the first pasteboard item's data. Returns false (and stores nothing) for concealed,
    /// transient or own-marker items, oversized items, and anything that isn't text or an image.
    @discardableResult
    public func ingest(types: [NSPasteboard.PasteboardType: Data]) -> Bool {
        if PasteboardSnapshot.isSensitive(types: Array(types.keys)) { return false }

        let kind: ClipItem.Kind
        let stored: [(NSPasteboard.PasteboardType, Data)]
        let hashed: Data
        if let data = types[.string], let string = String(data: data, encoding: .utf8),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .text(Self.preview(of: string))
            stored = Self.textTypes.compactMap { t in types[t].map { (t, $0) } }
            hashed = Data(string.utf8)
        } else if let png = types[.png] {
            // PNG wins; the TIFF a screenshot also carries is huge and redundant.
            kind = .image(fileName: "") // file name is assigned when the files are written
            stored = [(.png, png)]
            hashed = png
        } else if let tiff = types[.tiff] {
            kind = .image(fileName: "")
            stored = [(.tiff, tiff)]
            hashed = tiff
        } else {
            return false
        }
        // Size check on what would be stored, before any hashing.
        guard stored.allSatisfy({ $0.1.count <= Self.maxItemBytes }) else { return false }
        let hash = Self.hash(hashed)

        if let index = items.firstIndex(where: { Self.isDuplicate($0, of: kind, hash: hash) }) {
            var item = items.remove(at: index)
            item = ClipItem(id: item.id, date: Date(), pinned: item.pinned, kind: item.kind,
                            types: item.types, contentHash: item.contentHash, thumbnail: item.thumbnail)
            items.insert(item, at: 0)
            save()
            onChange?()
            return true
        }

        let id = UUID()
        var files: [String: String] = [:]
        do {
            for (n, (type, data)) in stored.enumerated() {
                let name = "\(id.uuidString)-\(n).bin"
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                files[type.rawValue] = name
            }
        } catch {
            Self.log.error("could not store clipboard item: \(String(describing: error), privacy: .public)")
            for name in files.values { removeFile(name) }
            return false
        }
        var finalKind = kind
        if case .image = kind, let name = files.values.first {
            finalKind = .image(fileName: name)
            makeThumbnail(for: id, from: name)
        }
        items.insert(ClipItem(id: id, kind: finalKind, types: files, contentHash: hash), at: 0)
        let evicted = enforceLimit()
        save(thenRemove: evicted.flatMap(\.fileNames))
        onChange?()
        return true
    }

    /// The types worth reading from a pasteboard item, in reading order: text types, else PNG, else
    /// TIFF (TIFF is only read when there is no PNG). Lets the monitor avoid reading big redundant data.
    public static func typesToRead(available: Set<NSPasteboard.PasteboardType>) -> [NSPasteboard.PasteboardType] {
        if available.contains(.string) { return textTypes.filter(available.contains) }
        if available.contains(.png) { return [.png] }
        if available.contains(.tiff) { return [.tiff] }
        return []
    }

    /// Same kind and same full content (by hash; text previews alone could collide).
    private static func isDuplicate(_ item: ClipItem, of kind: ClipItem.Kind, hash: String) -> Bool {
        switch (item.kind, kind) {
        case (.text, .text), (.image, .image): return item.contentHash == hash
        default: return false
        }
    }

    // MARK: Editing

    public func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        let evicted = enforceLimit() // unpinning can push the unpinned count over the cap
        save(thenRemove: evicted.flatMap(\.fileNames))
        onChange?()
    }

    public func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: i)
        save(thenRemove: removed.fileNames)
        onChange?()
    }

    /// Removes every unpinned item, plus any backup of an unreadable index.
    public func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        save(thenRemove: removed.flatMap(\.fileNames))
        removeBackups()
        onChange?()
    }

    // MARK: Reading

    /// Items for display: pinned first, then recent, both newest first. Text items are filtered by
    /// case-insensitive substring; images show only when the query is empty.
    public func sections(query: String) -> (pinned: [ClipItem], recent: [ClipItem]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = items.filter { item in
            guard !q.isEmpty else { return true }
            guard case .text(let s) = item.kind else { return false }
            return s.range(of: q, options: .caseInsensitive) != nil
        }
        return (shown.filter(\.pinned), shown.filter { !$0.pinned })
    }

    /// Bytes of the file behind `fileName`.
    public func fileData(_ fileName: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    /// The file to draw an image item's thumbnail from: the small thumbnail once it exists, else
    /// the full image. Read it off the main thread.
    public func thumbnailSourceURL(for id: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == id }), case .image(let name) = item.kind else { return nil }
        return directory.appendingPathComponent(item.thumbnail ?? name)
    }

    /// The stored pasteboard types of an item as one pasteboard item, ready for `Inserter`. Reads
    /// the data files, so text comes back in full, not as the index preview.
    public func payload(for id: UUID) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        var dict: [NSPasteboard.PasteboardType: Data] = [:]
        for (type, name) in item.types {
            if let data = fileData(name) { dict[NSPasteboard.PasteboardType(type)] = data }
        }
        return dict.isEmpty ? [] : [dict]
    }

    // MARK: Persistence

    /// Drops the oldest unpinned items beyond the cap; the caller saves the index, then deletes their files.
    private func enforceLimit() -> [ClipItem] {
        var removed: [ClipItem] = []
        while items.filter({ !$0.pinned }).count > limit,
              let i = items.lastIndex(where: { !$0.pinned }) {
            removed.append(items.remove(at: i))
        }
        return removed
    }

    private func removeFile(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// Encodes the index now (it is small: text is only a preview), then writes it and deletes
    /// `names` on the IO queue, in that order, so a crash leaves orphans rather than an index
    /// pointing at deleted files.
    private func save(thenRemove names: [String] = []) {
        let data: Data?
        do {
            data = indexWritable ? try JSONEncoder().encode(items) : nil
        } catch {
            data = nil
            Self.log.error("could not encode clipboard index: \(String(describing: error), privacy: .public)")
        }
        guard data != nil || !names.isEmpty else { return }
        let directory = directory
        Self.ioQueue.async {
            if let data {
                do {
                    try data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
                } catch {
                    Self.log.error("could not save clipboard index: \(String(describing: error), privacy: .public)")
                }
            }
            for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    /// Blocks until queued index writes and deletions are on disk (call before quitting).
    public func flush() {
        Self.ioQueue.sync {}
    }

    // MARK: Thumbnails

    /// Makes a small PNG of the image in `source` off the main thread, then records it on the item.
    private func makeThumbnail(for id: UUID, from source: String) {
        let sourceURL = directory.appendingPathComponent(source)
        let name = "\(id.uuidString)-thumb.bin"
        let destination = directory.appendingPathComponent(name)
        let work = Task.detached(priority: .utility) {
            Self.writeThumbnail(from: sourceURL, to: destination)
        }
        pendingThumbnails[id] = Task { [weak self] in
            let ok = await work.value
            guard let self else { return }
            self.pendingThumbnails[id] = nil
            guard ok else { return }
            guard let i = self.items.firstIndex(where: { $0.id == id }) else {
                self.save(thenRemove: [name]) // deleted meanwhile
                return
            }
            self.items[i].thumbnail = name
            self.save()
        }
    }

    /// Waits until every thumbnail being made has been recorded.
    func waitForThumbnails() async {
        while let task = pendingThumbnails.values.first { await task.value }
    }

    private nonisolated static func writeThumbnail(from source: URL, to destination: URL) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
        ]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return false }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        return (try? (data as Data).write(to: destination, options: .atomic)) != nil
    }
}
