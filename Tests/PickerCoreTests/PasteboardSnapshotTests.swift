import AppKit
import Testing
@testable import PickerCore

@Suite @MainActor struct PasteboardSnapshotTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("test-\(UUID())"))
    }

    @Test func roundTripsMultipleTypes() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let rtf = Data("{\\rtf1 hello}".utf8)
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(rtf, forType: .rtf)
        pb.clearContents()
        #expect(pb.writeObjects([item]))

        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("other", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.pasteboardItems?.count == 1)
        let restored = pb.pasteboardItems?.first
        #expect(restored?.string(forType: .string) == "hello")
        #expect(restored?.data(forType: .rtf) == rtf)
    }

    @Test func roundTripsEmpty() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.setString("something", forType: .string)
        snapshot.restore(to: pb)
        #expect((pb.pasteboardItems ?? []).isEmpty)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func restoreOnlyIfUnchanged() {
        #expect(shouldRestore(currentChangeCount: 5, ourChangeCount: 5))
        #expect(!shouldRestore(currentChangeCount: 6, ourChangeCount: 5))
    }

    @Test func detectsSensitiveTypes() {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let plain = PasteboardSnapshot(items: [[.string: Data("a".utf8)]])
        let secretA = PasteboardSnapshot(items: [[.string: Data("a".utf8), concealed: Data()]])
        let secretB = PasteboardSnapshot(items: [[.string: Data("a".utf8)], [transient: Data()]])
        #expect(!plain.containsSensitiveTypes)
        #expect(secretA.containsSensitiveTypes)
        #expect(secretB.containsSensitiveTypes)
    }

    @Test func capturedSensitiveTypesAreDetected() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("pw", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.clearContents()
        pb.writeObjects([item])
        #expect(PasteboardSnapshot.capture(pb).containsSensitiveTypes)
    }

    @Test func typelessItemsAreNotWritten() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let snapshot = PasteboardSnapshot(items: [[:], [:]])
        pb.clearContents()
        pb.setString("something", forType: .string)
        snapshot.restore(to: pb)
        #expect((pb.pasteboardItems ?? []).isEmpty)
    }
}
