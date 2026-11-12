import AppKit
import Foundation
import Testing
@testable import PickerCore

@MainActor
@Suite struct ClipboardHistoryTests {
    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)")
    }

    private func text(_ s: String) -> [NSPasteboard.PasteboardType: Data] { [.string: Data(s.utf8)] }

    private func strings(_ h: ClipboardHistory) -> [String] {
        h.items.compactMap { if case .text(let s) = $0.kind { s } else { nil } }
    }

    @Test func ingestsText() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        #expect(h.ingest(types: text("hi")))
        #expect(h.items.count == 1)
        #expect(h.items[0].kind == .text("hi"))
        let perms = try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test func skipsConcealed() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        var t = text("secret"); t[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")] = Data()
        #expect(!h.ingest(types: t))
        #expect(h.items.isEmpty)
    }

    @Test func skipsTransient() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        var t = text("temp"); t[NSPasteboard.PasteboardType("org.nspasteboard.TransientType")] = Data()
        #expect(!h.ingest(types: t))
    }

    @Test func skipsOwnMarker() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        var t = text("ours"); t[OwnMarker.type] = Data()
        #expect(!h.ingest(types: t))
    }

    @Test func skipsOtherContent() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        #expect(!h.ingest(types: [.fileURL: Data("file:///tmp/x".utf8)]))
        #expect(h.items.isEmpty)
    }

    @Test func dedupesMovesToTop() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("a")); h.ingest(types: text("b")); h.ingest(types: text("a"))
        #expect(strings(h) == ["a", "b"])
    }

    @Test func duplicateKeepsPinned() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("a")); h.ingest(types: text("b"))
        h.togglePin(h.items[1].id)
        h.ingest(types: text("a"))
        #expect(strings(h) == ["a", "b"])
        #expect(h.items[0].pinned)
    }

    @Test func dedupesImagesByHash() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: [.png: Data([1, 2, 3])]); h.ingest(types: [.png: Data([4])])
        h.ingest(types: [.png: Data([1, 2, 3]), .tiff: Data([9])])
        #expect(h.items.count == 2)
    }

    @Test func capsUnpinned() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("pinned"))
        h.togglePin(h.items[0].id)
        for i in 0..<30 { h.ingest(types: text("t\(i)")) }
        #expect(h.items.filter { !$0.pinned }.count == 25)
        #expect(h.items.filter(\.pinned).count == 1)
        #expect(h.items.count == 26)
        // evicted items lose their files: 26 items x 1 type + history.json
        h.flush()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(files.count == 27)
        h.clearUnpinned()
        #expect(strings(h) == ["pinned"])
    }

    @Test func deleteRemovesFiles() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("a"))
        h.delete(h.items[0].id)
        #expect(h.items.isEmpty)
        h.flush()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["history.json"])
    }

    @Test func skipsOversized() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let big = Data(repeating: 0x41, count: ClipboardHistory.maxItemBytes + 1)
        #expect(!h.ingest(types: [.string: big]))
        #expect(!h.ingest(types: [.png: big]))
        #expect(h.items.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("a")); h.ingest(types: text("b"))
        h.togglePin(h.items[1].id)
        let again = ClipboardHistory(directory: dir)
        #expect(again.items == h.items)
        #expect(again.items[1].pinned)
    }

    @Test func payloadRoundTrip() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), tiff = Data([0x49, 0x49, 0x2A, 0, 7, 8])
        #expect(h.ingest(types: [.png: png, .tiff: tiff]))
        let payload = h.payload(for: h.items[0].id)
        #expect(payload.count == 1)
        #expect(payload[0][.png] == png)
        #expect(payload[0][.tiff] == nil) // PNG present: TIFF is dropped by design
        let tiffDir = makeDir(); defer { try? FileManager.default.removeItem(at: tiffDir) }
        let tiffOnly = ClipboardHistory(directory: tiffDir)
        #expect(tiffOnly.ingest(types: [.tiff: tiff]))
        #expect(tiffOnly.payload(for: tiffOnly.items[0].id)[0][.tiff] == tiff)
        if case .image(let name) = h.items[0].kind { #expect(h.fileData(name) == png) } else { Issue.record("not an image") }
    }

    @Test func textPayloadKeepsStoredTypes() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let rtf = Data("{\\rtf1 hi}".utf8)
        h.ingest(types: [.string: Data("hi".utf8), .rtf: rtf, .html: Data("<b>x</b>".utf8)])
        let payload = h.payload(for: h.items[0].id)
        #expect(Set(payload[0].keys) == [.string, .rtf])
    }

    @Test func sectionsFilterAndPin() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("Hello World")); h.ingest(types: [.png: Data([1])]); h.ingest(types: text("other"))
        h.togglePin(h.items[2].id) // Hello World
        let all = h.sections(query: "")
        #expect(all.pinned.count == 1 && all.recent.count == 2)
        let found = h.sections(query: "WORLD")
        #expect(found.pinned.count == 1 && found.recent.isEmpty)
    }

    @Test func pngWithHugeTiffStoresPngOnly() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let png = Data(repeating: 1, count: 1024), tiff = Data(repeating: 2, count: 11_000_000)
        #expect(h.ingest(types: [.png: png, .tiff: tiff]))
        #expect(Set(h.items[0].types.keys) == [NSPasteboard.PasteboardType.png.rawValue])
        #expect(h.payload(for: h.items[0].id)[0][.tiff] == nil)
    }

    @Test func sweepsOrphanFiles() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        h.ingest(types: text("keep"))
        let stray = dir.appendingPathComponent("stray-0.bin")
        try Data([1]).write(to: stray)
        let again = ClipboardHistory(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(again.payload(for: again.items[0].id).count == 1)
    }

    @Test func corruptIndexKeepsDataFiles() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("x-0.bin")
        try Data([1]).write(to: bin)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("history.json"))
        let h = ClipboardHistory(directory: dir)
        #expect(h.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bin.path))
        #expect(h.ingest(types: text("fresh")))
        let again = ClipboardHistory(directory: dir)
        #expect(strings(again) == ["fresh"])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let backups = names.filter { $0.hasPrefix("history.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(backups.first.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) } == Data("not json".utf8))
    }

    @Test func unreadableIndexIsBackedUpNotSwept() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("x-0.bin")
        try Data([1]).write(to: bin)
        // A directory named history.json exists but can't be read as a file.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("history.json"), withIntermediateDirectories: false)
        _ = ClipboardHistory(directory: dir)
        #expect(FileManager.default.fileExists(atPath: bin.path))
    }

    private func backups(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("history.json.corrupt-") }
    }

    @Test func failedBackupMoveNeverOverwritesIndex() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("x-0.bin")
        try Data([1]).write(to: bin)
        let index = dir.appendingPathComponent("history.json")
        let garbage = Data("not json".utf8)
        try garbage.write(to: index)
        struct MoveFailed: Error {}
        let h = ClipboardHistory(directory: dir, limit: 25, moveItem: { _, _ in throw MoveFailed() })
        #expect(h.ingest(types: text("in memory")))
        #expect(strings(h) == ["in memory"])
        #expect(try Data(contentsOf: index) == garbage)
        _ = ClipboardHistory(directory: dir)
        #expect(FileManager.default.fileExists(atPath: bin.path))
    }

    @Test func backupNameIsUnique() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: dir.appendingPathComponent("history.json"))
        _ = ClipboardHistory(directory: dir)
        let name = try #require(backups(in: dir).first)
        #expect(name.range(of: #"^history\.json\.corrupt-\d{8}-\d{6}-[0-9a-f]{8}$"#, options: .regularExpression) != nil)
    }

    @Test func newCorruptionKeepsOneBackup() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("history.json.corrupt-20261111-000000-aaaaaaaa"))
        try Data("new".utf8).write(to: dir.appendingPathComponent("history.json"))
        _ = ClipboardHistory(directory: dir)
        let names = backups(in: dir)
        #expect(names.count == 1)
        #expect(names.first.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) } == Data("new".utf8))
    }

    @Test func clearUnpinnedRemovesBackups() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: dir.appendingPathComponent("history.json"))
        let h = ClipboardHistory(directory: dir)
        #expect(backups(in: dir).count == 1)
        h.clearUnpinned()
        #expect(backups(in: dir).isEmpty)
    }

    @Test func oldBackupsRemovedOnInit() throws {
        let fm = FileManager.default
        let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("history.json.corrupt-20261104-000000-aaaaaaaa")
        let recent = dir.appendingPathComponent("history.json.corrupt-20261111-000000-bbbbbbbb")
        try Data("old".utf8).write(to: old)
        try Data("recent".utf8).write(to: recent)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-1 * 86_400)], ofItemAtPath: recent.path)
        _ = ClipboardHistory(directory: dir)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: recent.path))
    }

    @Test func sensitiveTypesAreInspectedAndDetected() {
        let marked: [NSPasteboard.PasteboardType] = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
            "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
            "Pasteboard generator type", "net.antelle.keeweb",
        ].map { NSPasteboard.PasteboardType($0) } + [OwnMarker.type]
        for t in marked {
            #expect(ClipboardHistory.inspectedTypes.contains(t))
            #expect(PasteboardSnapshot.isSensitive(types: [.string, t]))
        }
        #expect(!PasteboardSnapshot.isSensitive(types: [.string, .png]))
        #expect(!PasteboardSnapshot.isSensitive(types: [OwnMarker.type], includeOwnMarker: false))
        #expect(PasteboardSnapshot.isSensitive(
            types: [.string, NSPasteboard.PasteboardType("com.agilebits.onepassword")], includeOwnMarker: false))
    }

    @Test func readPlanSkipsTiffWhenPngPresent() {
        #expect(ClipboardHistory.typesToRead(available: [.png, .tiff]) == [.png])
        #expect(ClipboardHistory.typesToRead(available: [.tiff]) == [.tiff])
        #expect(ClipboardHistory.typesToRead(available: [.fileURL]).isEmpty)
    }

    // MARK: Change notifications

    @Test func onChangeFiresForEveryEdit() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        var calls = 0
        h.onChange = { calls += 1 }
        h.ingest(types: text("a")); #expect(calls == 1)
        h.ingest(types: text("a")); #expect(calls == 2) // duplicate moved to the top
        #expect(!h.ingest(types: [.fileURL: Data()])); #expect(calls == 2)
        h.togglePin(h.items[0].id); #expect(calls == 3)
        h.ingest(types: text("b")); #expect(calls == 4)
        h.delete(h.items[0].id); #expect(calls == 5)
        h.clearUnpinned(); #expect(calls == 6)
        h.delete(UUID()); #expect(calls == 6) // unknown id: nothing changed
    }

    // MARK: Large text

    private func indexData(_ dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("history.json"))
    }

    @Test func largeTextKeepsFullPayloadAndSmallIndex() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let big = String(repeating: "abcdefghé", count: 2_000_000 / 10) // ~2 MB
        #expect(h.ingest(types: text(big)))
        guard case .text(let preview) = h.items[0].kind else { Issue.record("not text"); return }
        #expect(preview.utf8.count <= ClipboardHistory.previewBytes)
        #expect(big.hasPrefix(preview))
        #expect(h.payload(for: h.items[0].id).first?[.string] == Data(big.utf8))
        h.flush()
        #expect(try indexData(dir).count < 8_192)
        let again = ClipboardHistory(directory: dir)
        #expect(again.payload(for: again.items[0].id).first?[.string] == Data(big.utf8))
        #expect(again.sections(query: "abcdefgh").recent.count == 1)
    }

    @Test func dedupeComparesFullTextNotPreview() {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let prefix = String(repeating: "x", count: ClipboardHistory.previewBytes + 10)
        h.ingest(types: text(prefix + "one")); h.ingest(types: text(prefix + "two"))
        #expect(h.items.count == 2)
        h.ingest(types: text(prefix + "one"))
        #expect(h.items.count == 2)
        #expect(h.payload(for: h.items[0].id).first?[.string] == Data((prefix + "one").utf8))
    }

    @Test func oldFormatIndexLoadsAndMigrates() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let full = String(repeating: "old text ", count: 1_000) // 9 KB, stored whole in the old index
        try Data(full.utf8).write(to: dir.appendingPathComponent("aaaa-0.bin"))
        // The index exactly as earlier versions wrote it: full text inline, no contentHash.
        let old: [String: Any] = [
            "id": "11111111-2222-3333-4444-555555555555", "pinned": true, "date": 0,
            "kind": ["text": ["_0": full]], "types": ["public.utf8-plain-text": "aaaa-0.bin"],
        ]
        try JSONSerialization.data(withJSONObject: [old]).write(to: dir.appendingPathComponent("history.json"))

        let h = ClipboardHistory(directory: dir)
        #expect(h.items.count == 1)
        #expect(h.items[0].pinned)
        guard case .text(let preview) = h.items[0].kind else { Issue.record("not text"); return }
        #expect(preview.utf8.count <= ClipboardHistory.previewBytes)
        #expect(h.items[0].contentHash != nil)
        #expect(h.payload(for: h.items[0].id).first?[.string] == Data(full.utf8))
        h.ingest(types: text(full)) // still recognised as the same item
        #expect(h.items.count == 1)
        h.flush()
        #expect(try indexData(dir).count < 8_192) // migrated copy was saved
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("aaaa-0.bin").path))
    }

    // MARK: Thumbnails and backup

    private func pngData(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func imageIngestWritesSmallThumbnail() async throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = ClipboardHistory(directory: dir)
        let png = try pngData(width: 1000, height: 400)
        #expect(h.ingest(types: [.png: png]))
        await h.waitForThumbnails()
        let name = try #require(h.items[0].thumbnail)
        #expect(h.thumbnailSourceURL(for: h.items[0].id)?.lastPathComponent == name)
        let thumbData = try #require(h.fileData(name))
        let thumb = try #require(NSBitmapImageRep(data: thumbData))
        #expect(max(thumb.pixelsWide, thumb.pixelsHigh) <= ClipboardHistory.thumbnailMaxPixels)
        #expect(Set(h.payload(for: h.items[0].id)[0].keys) == [.png]) // thumbnail isn't pasted
        let again = ClipboardHistory(directory: dir) // persisted, and not swept as an orphan
        #expect(again.items[0].thumbnail == name)
        #expect(again.fileData(name) != nil)
        again.delete(again.items[0].id)
        again.flush()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["history.json"])
    }

    @Test func missingThumbnailIsBackfilledOnLoad() async throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pngData(width: 300, height: 300).write(to: dir.appendingPathComponent("img-0.bin"))
        let old: [String: Any] = [
            "id": "11111111-2222-3333-4444-555555555555", "pinned": false, "date": 0,
            "kind": ["image": ["fileName": "img-0.bin"]], "types": ["public.png": "img-0.bin"],
            "contentHash": "abc",
        ]
        try JSONSerialization.data(withJSONObject: [old]).write(to: dir.appendingPathComponent("history.json"))
        let h = ClipboardHistory(directory: dir)
        #expect(h.thumbnailSourceURL(for: h.items[0].id)?.lastPathComponent == "img-0.bin")
        await h.waitForThumbnails()
        #expect(h.items[0].thumbnail != nil)
    }

    @Test func directoryIsExcludedFromBackup() throws {
        let dir = makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = ClipboardHistory(directory: dir)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
