import AppKit

/// A small non-activating, click-through message that disappears by itself.
@MainActor
final class Toast {
    static let duration: TimeInterval = 1.5
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Shows `message` centred on `anchor` (screen coordinates), clamped to the screen's visible area.
    func show(_ message: String, centeredOn anchor: CGPoint) {
        hideWork?.cancel()
        window?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 28, height: label.frame.height + 16)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        bg.layer?.cornerRadius = 8
        label.frame.origin = CGPoint(x: 14, y: 8)
        bg.addSubview(label)
        panel.contentView = bg

        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        window = panel

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
                self?.window = nil
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }
}
