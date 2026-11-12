import Foundation

/// Stores the GIPHY API key in a file only the user's account can read (folder 0700, file 0600).
///
/// It doesn't use the login keychain. A self-signed local build looks like a new app to the
/// keychain after every rebuild, so each read prompted for the login keychain password. The key is
/// free, rate-limited and revocable, so a private file is protection enough.
public struct GiphyKeyStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/EmojiPicker/giphy-key`
    public static var standard: GiphyKeyStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return GiphyKeyStore(fileURL: support
            .appendingPathComponent("EmojiPicker", isDirectory: true)
            .appendingPathComponent("giphy-key"))
    }

    /// The saved key, or nil if none is saved.
    public func load() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Saves the key (trimmed). An empty value removes the saved key.
    public func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if key.isEmpty {
            if fm.fileExists(atPath: fileURL.path) { try fm.removeItem(at: fileURL) }
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Write a fresh owner-only temp file (O_EXCL|O_NOFOLLOW: never an existing file or a
        // symlink), then rename it over the key file. rename replaces a symlink itself rather than
        // writing through it, and the key is never readable by anyone else, even briefly.
        let temp = dir.appendingPathComponent(".giphy-key-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let bytes = Array(key.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let closed = close(fd)
        guard written == bytes.count, closed == 0, rename(temp.path, fileURL.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
