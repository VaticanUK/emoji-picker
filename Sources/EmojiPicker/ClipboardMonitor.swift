import AppKit
import PickerCore

/// Polls the general pasteboard's changeCount every 0.5 s and feeds new copies to `ClipboardHistory`.
/// Skips writes the `Inserter` made (including its clipboard restores, which carry no marker).
@MainActor
final class ClipboardMonitor {
    static let interval: TimeInterval = 0.5

    private let history: ClipboardHistory
    private let inserter: Inserter
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?

    init(history: ClipboardHistory, inserter: Inserter, pasteboard: NSPasteboard = .general) {
        self.history = history
        self.inserter = inserter
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    /// Starts polling and ingests what is on the clipboard right now.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        ingestCurrent()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !inserter.ownChangeCounts.contains(count) else { return }
        ingestCurrent()
    }

    private func ingestCurrent() {
        let items = pasteboard.pasteboardItems ?? []
        guard let first = items.first else { return }
        // Decide from type lists alone, across every item, before reading any data.
        if items.contains(where: { PasteboardSnapshot.isSensitive(types: $0.types) }) { return }
        // Read one type at a time and give up on the whole change as soon as one is oversized.
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        for type in ClipboardHistory.typesToRead(available: Set(first.types)) {
            guard let data = first.data(forType: type) else { continue }
            if data.count > ClipboardHistory.maxItemBytes { return }
            types[type] = data
        }
        history.ingest(types: types)
    }
}
