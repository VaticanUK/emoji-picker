import AppKit
import Carbon.HIToolbox
import PickerCore

/// A button that shows a shortcut and records the next key combination when clicked.
/// Rejects combos with no modifier, and Shift-only combos (they would block normal typing).
@MainActor
final class ShortcutRecorder: NSButton {
    /// Called with a valid combo. Returns an error message to show, or nil when it was applied.
    var onRecord: ((Shortcut) -> String?)?
    var onError: ((String?) -> Void)?
    /// Called when recording starts / stops, so the global hotkey can be paused meanwhile.
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var shortcut: Shortcut = .default {
        didSet { refreshTitle() }
    }
    private var isRecording = false {
        didSet { refreshTitle(); onRecordingChange?(isRecording) }
    }

    override var acceptsFirstResponder: Bool { true }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func display(_ s: Shortcut) { shortcut = s }

    private func refreshTitle() {
        title = isRecording ? "Press a shortcut…" : shortcut.displayString
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else {
            onError?(nil)
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    private func stopRecording() { if isRecording { isRecording = false } }

    /// Idempotent: safe to call when not recording.
    func cancelRecording() { stopRecording() }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .option, .control, .shift]) {
            stopRecording()
            return
        }
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
        if let message = candidate.validationError {
            onError?(message)
            return // stay in recording mode
        }
        stopRecording()
        if let message = onRecord?(candidate) {
            onError?(message)
        } else {
            onError?(nil)
            shortcut = candidate
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}
