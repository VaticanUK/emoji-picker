import Foundation
import Testing
@testable import PickerCore

struct GiphyKeyStoreTests {
    private func makeStore() -> (GiphyKeyStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("giphykey-\(UUID().uuidString)", isDirectory: true)
        return (GiphyKeyStore(fileURL: dir.appendingPathComponent("giphy-key")), dir)
    }

    @Test func missingFileLoadsNil() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.load() == nil)
    }

    @Test func savesAndLoadsTrimmed() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save("  abc123\n")
        #expect(store.load() == "abc123")
    }

    @Test func fileAndFolderAreOwnerOnly() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save("abc123")
        let fm = FileManager.default
        let filePerms = try fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        let dirPerms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(filePerms == 0o600)
        #expect(dirPerms == 0o700)
    }

    @Test func doesNotWriteThroughASymlink() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim")
        try Data("original".utf8).write(to: victim)
        try fm.createSymbolicLink(at: store.fileURL, withDestinationURL: victim)
        try store.save("abc123")
        #expect(try String(contentsOf: victim, encoding: .utf8) == "original")
        #expect(store.load() == "abc123")
        let perms = try fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func savingEmptyRemovesTheKey() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save("abc123")
        try store.save("   ")
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
