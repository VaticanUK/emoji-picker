import AppKit
import os
import PickerCore
import ServiceManagement

/// The Settings window: shortcut, GIPHY key, GIF rating, launch at login. Built lazily on first open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let log = Logger(subsystem: "com.emojipicker.app", category: "settings")
    static let shortcutKey = "shortcut"
    static let giphyKeyURL = URL(string: "https://developers.giphy.com/dashboard/")!
    static let ratings = ["g", "pg", "pg-13", "r"]

    /// Applies a new shortcut (registers it). Returns false if it could not be registered.
    var applyShortcut: ((Shortcut) -> Bool)?
    var pauseHotkey: ((Bool) -> Void)?
    /// Called after the GIF rating was changed and saved.
    var onRatingChange: (() -> Void)?

    private var window: NSWindow?
    private var recorder: ShortcutRecorder!
    private let shortcutError = NSTextField(labelWithString: "")
    private let keyField = NSTextField()
    private let keyStatus = NSTextField(labelWithString: "")
    private let ratingPopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginError = NSTextField(labelWithString: "")
    private var savedKey = ""

    static func loadShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: shortcutKey),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
        return s
    }

    static func saveShortcut(_ s: Shortcut) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: shortcutKey) }
    }

    func show(currentShortcut: Shortcut) {
        if window == nil { build(currentShortcut) }
        refresh(currentShortcut)
        endRecording()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Stops any recording and always un-pauses the global hotkey, whatever path got us here.
    private func endRecording() {
        recorder?.cancelRecording()
        pauseHotkey?(false)
    }

    // MARK: Build

    private func build(_ shortcut: Shortcut) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Emoji Picker Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.endRecording() } }

        recorder = ShortcutRecorder(shortcut: shortcut)
        recorder.onRecord = { [weak self] s in
            guard let self else { return nil }
            if self.applyShortcut?(s) == false { return "That shortcut is in use by another app" }
            return nil
        }
        recorder.onError = { [weak self] message in self?.shortcutError.stringValue = message ?? "" }
        recorder.onRecordingChange = { [weak self] on in self?.pauseHotkey?(on) }
        shortcutError.textColor = .systemRed
        shortcutError.font = .systemFont(ofSize: 11)

        keyField.placeholderString = "GIPHY API key"
        keyField.delegate = self
        keyField.target = self
        keyField.action = #selector(commitKey)
        keyStatus.font = .systemFont(ofSize: 11)
        let link = NSButton(title: "Get a free key", target: self, action: #selector(openKeyPage))
        link.isBordered = false
        link.contentTintColor = .linkColor

        ratingPopup.addItems(withTitles: Self.ratings)
        ratingPopup.target = self
        ratingPopup.action = #selector(ratingChanged)

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        loginError.textColor = .systemRed
        loginError.font = .systemFont(ofSize: 11)

        let grid = NSGridView(views: [
            [label("Shortcut"), vstack([recorder, shortcutError])],
            [label("GIPHY key"), vstack([keyField, hstack([link, keyStatus])])],
            [label("GIF rating"), ratingPopup],
            [NSView(), vstack([loginCheckbox, loginError])],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 270
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = w.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        w.center()
        window = w
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func refresh(_ shortcut: Shortcut) {
        recorder.display(shortcut)
        shortcutError.stringValue = ""
        savedKey = GiphyKeyStore.standard.load() ?? ""
        keyField.stringValue = savedKey
        keyStatus.stringValue = ""
        let rating = UserDefaults.standard.string(forKey: GifTab.ratingKey) ?? "pg-13"
        ratingPopup.selectItem(withTitle: Self.ratings.contains(rating) ? rating : "pg-13")
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginError.stringValue = ""
    }

    // MARK: Actions

    @objc private func openKeyPage() { NSWorkspace.shared.open(Self.giphyKeyURL) }

    @objc private func commitKey() {
        // Flush the field editor so stringValue holds any in-progress edit.
        if window?.firstResponder === keyField.currentEditor() || keyField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != savedKey else { return }
        do {
            try GiphyKeyStore.standard.save(value)
            savedKey = value
            keyStatus.textColor = .secondaryLabelColor
            keyStatus.stringValue = value.isEmpty ? "Key removed" : "Saved"
        } catch {
            Self.log.error("couldn't save the GIPHY key: \(error.localizedDescription, privacy: .public)")
            keyStatus.textColor = .systemRed
            keyStatus.stringValue = "Couldn't save the key"
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitKey() }

    func windowWillClose(_ notification: Notification) {
        endRecording()
        commitKey()
        NSApp.hide(nil) // give focus back to the app the user was in
    }

    func windowDidResignKey(_ notification: Notification) { endRecording() }

    @objc private func ratingChanged() {
        guard let title = ratingPopup.titleOfSelectedItem,
              title != UserDefaults.standard.string(forKey: GifTab.ratingKey) else { return }
        UserDefaults.standard.set(title, forKey: GifTab.ratingKey)
        onRatingChange?()
    }

    @objc private func loginChanged() {
        let wantOn = loginCheckbox.state == .on
        do {
            if wantOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError.stringValue = ""
        } catch {
            loginError.stringValue = "Couldn't change launch at login"
            loginCheckbox.state = wantOn ? .off : .on
        }
    }
}
