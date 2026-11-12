import Foundation
import Testing
@testable import PickerCore

@Suite struct RecentsTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString)/recents-test.json")
    }

    @Test func recentsDedupesAndCaps() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentsStore<String>(fileURL: url, limit: 36)
        store.record("a"); store.record("b"); store.record("a")
        #expect(store.items == ["a", "b"])
        for i in 0..<40 { store.record("e\(i)") }
        #expect(store.items.count == 36)
        #expect(store.items.first == "e39")
        #expect(RecentsStore<String>(fileURL: url, limit: 36).items == store.items)
    }
}
