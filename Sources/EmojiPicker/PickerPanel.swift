import AppKit
import os

/// Background view that can take first responder so key events (Esc) reach the panel.
private final class PickerBackgroundView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event]) // routes Esc to cancelOperation(_:) up the responder chain
    }
}

final class PickerPanel: NSPanel {
    static let size = CGSize(width: 360, height: 420)

    var onDismiss: (() -> Void)?
    private var isDismissing = false
    private weak var focusView: NSView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = PickerBackgroundView(frame: CGRect(origin: .zero, size: Self.size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        contentView = background
        initialFirstResponder = background
    }

    /// Hosts the picker's content over the background and gives `focus` the keyboard on every present.
    func setContent(_ view: NSView, focus: NSView) {
        guard let background = contentView else { return }
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        focusView = focus
        initialFirstResponder = focus
    }

    /// Orders the panel in once, invisibly, so the first real open doesn't pay for creating its
    /// window-server backing and first draw. Never becomes key, so it can't take focus.
    func warmUp() {
        animationBehavior = .none // no show/hide animation, so the warm-up can't flash a frame
        alphaValue = 0
        setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) // off-screen, never at (0,0)
        orderFrontRegardless()
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    /// `hotkeyTime` is the `mach_absolute_time()` captured when the hotkey fired.
    func present(at frame: CGRect, hotkeyTime: UInt64) {
        setFrame(frame, display: false)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(focusView ?? contentView)
        displayIfNeeded()
        #if DEBUG
        let ms = Self.milliseconds(from: hotkeyTime, to: mach_absolute_time())
        Self.log.info("picker shown in \(ms, privacy: .public) ms")
        #endif
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        orderOut(nil) // may re-enter via resignKey
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    #if DEBUG
    private static let log = Logger(subsystem: "com.emojipicker.app", category: "timing")

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = (end &- start) &* UInt64(info.numer) / UInt64(info.denom)
        return Int((Double(nanos) / 1_000_000).rounded())
    }
    #endif
}
