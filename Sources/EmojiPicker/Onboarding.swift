import AppKit
import ApplicationServices

/// First-run window explaining why Accessibility access is needed. Shown only while it is missing.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private var window: NSWindow?

    private var pollTimer: Timer?

    func show() {
        if window == nil { build() }
        // An accessory app launched from Terminal or Finder can't always activate itself, and then
        // a normal window would open behind the frontmost app. Float it and order it front regardless.
        window?.level = .floating
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKey()
        startPolling()
    }

    /// Closes the window by itself once access is granted in System Settings.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.window?.close()
            }
        }
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Emoji Picker"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let text = NSTextField(wrappingLabelWithString:
            "Emoji Picker needs Accessibility access to find your text cursor and to paste for you. Without it, picking something only copies it, and you press ⌘V yourself.")
        let button = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(grant))
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [text, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = w.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        w.center()
        window = w
    }

    @objc private func grant() {
        Self.requestAccess()
        window?.orderOut(nil) // not close(): keep polling so it can tidy up once access is granted
        NSWorkspace.shared.open(Self.settingsURL)
    }

    /// Shows macOS's own "would like to control this computer" prompt and adds the app to the
    /// Accessibility list, so the user only has to flip its switch.
    static func requestAccess() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt (a C global
        // that Swift 6 flags as shared mutable state).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.hide(nil) // give focus back to the app the user was in
    }
}
