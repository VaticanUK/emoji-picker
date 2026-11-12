import AppKit
import PickerCore
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let log = Logger(subsystem: "com.emojipicker.app", category: "picker")

    private var statusItem: NSStatusItem?
    private var hotkey: HotkeyManager?
    private var panel: PickerPanel?
    private var picker: PickerViewController?
    private let inserter = Inserter()
    private var clipboardMonitor: ClipboardMonitor?
    private var clipboardHistory: ClipboardHistory?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var gifTab: GifTab?
    private let toast = Toast()
    /// Shown at the top of the menu-bar menu while no shortcut is registered.
    private let shortcutWarning = NSMenuItem(title: "Shortcut unavailable – open Settings", action: nil, keyEquivalent: "")
    /// Shown at the top of the menu-bar menu while Accessibility access is missing.
    private lazy var accessibilityItem: NSMenuItem = {
        let item = NSMenuItem(title: "Grant Accessibility… (needed to paste)", action: #selector(grantAccessibilityFromMenu), keyEquivalent: "")
        item.target = self
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji Picker")

        let menu = NSMenu()
        for entry in [
            NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","),
            NSMenuItem(title: "Clear clipboard history", action: #selector(clearClipboardHistory), keyEquivalent: ""),
        ] {
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Emoji Picker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item

        buildPicker()

        let manager = HotkeyManager { [weak self] hotkeyTime in self?.togglePicker(hotkeyTime: hotkeyTime) }
        let shortcut = SettingsWindowController.loadShortcut()
        do {
            try manager.register(shortcut)
            NSLog("hotkey registered: %@ (OSStatus 0)", shortcut.displayString)
        } catch {
            NSLog("hotkey registration failed for %@: %@; falling back to default",
                  shortcut.displayString, String(describing: error))
            if shortcut != .default {
                do { try manager.register(.default) } catch {
                    NSLog("default hotkey registration failed: %@", String(describing: error))
                }
            }
        }
        hotkey = manager
        updateShortcutWarning()

        setUpLaunchAtLoginOnFirstRun()
        let trusted = AXIsProcessTrusted()
        Logger(subsystem: "com.emojipicker.app", category: "launch")
            .info("launch: accessibilityTrusted=\(trusted, privacy: .public)")
        if !trusted { showAccessibilityOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardHistory?.flush() // index writes are queued off the main thread
    }

    /// Launch at login is on by default: register once, on the first run only.
    private func setUpLaunchAtLoginOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didSetupLogin") else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            Self.log.error("launch at login registration failed: \(String(describing: error), privacy: .public)")
        }
        defaults.set(true, forKey: "didSetupLogin")
    }

    /// Builds the whole picker once; opening it later only resets cheap state.
    private func buildPicker() {
        let catalog: EmojiCatalog
        do {
            catalog = try EmojiCatalog.loadBundled()
        } catch {
            Self.log.error("emoji catalog failed to load: \(String(describing: error), privacy: .public)")
            catalog = EmojiCatalog(emojis: [])
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmojiPicker", isDirectory: true)
        let recents = RecentsStore<String>(
            fileURL: support.appendingPathComponent("recents-emoji.json"),
            limit: RecentsStore<String>.emojiLimit)

        let emojiTab = EmojiTab(
            frame: NSRect(origin: .zero, size: PickerViewController.contentSize),
            catalog: catalog, recents: recents,
            commit: { [weak self] payload in self?.commit(payload) })
        let kaomojiTab = makeTextTab(
            "kaomoji", file: "recents-kaomoji.json", directory: support,
            limit: RecentsStore<TextItem>.kaomojiLimit, columns: TextItemTab.kaomojiColumns,
            cellHeight: 32, fontSize: 13, empty: "No kaomoji found")
        let symbolsTab = makeTextTab(
            "symbols", file: "recents-symbols.json", directory: support,
            limit: RecentsStore<TextItem>.symbolsLimit, columns: TextItemTab.symbolsColumns,
            cellHeight: 38, fontSize: 20, empty: "No symbols found")
        let gifTab = GifTab(
            frame: NSRect(origin: .zero, size: PickerViewController.contentSize),
            recents: RecentsStore<GifResult>(
                fileURL: support.appendingPathComponent("recents-gif.json"),
                limit: RecentsStore<String>.gifLimit),
            commit: { [weak self] payload in self?.commit(payload) })
        gifTab.onOpenSettings = { [weak self] in self?.openSettings() }
        self.gifTab = gifTab
        // History stays in memory and the monitor (started at launch) keeps it current, so
        // opening the picker never touches the disk.
        let history = ClipboardHistory(directory: support.appendingPathComponent("clipboard", isDirectory: true))
        let clipboardTab = ClipboardTab(
            frame: NSRect(origin: .zero, size: PickerViewController.contentSize),
            history: history,
            commit: { [weak self] payload in self?.commit(payload) })
        let monitor = ClipboardMonitor(history: history, inserter: inserter)
        clipboardHistory = history
        history.onChange = { [weak clipboardTab] in clipboardTab?.historyChanged() }
        monitor.start()
        clipboardMonitor = monitor

        let picker = PickerViewController(
            tabs: [.emoji: emojiTab, .gif: gifTab, .kaomoji: kaomojiTab, .symbols: symbolsTab,
                   .clipboard: clipboardTab])
        gifTab.onRequestQuery = { [weak picker] text in picker?.setSearchText(text) }

        let panel = PickerPanel()
        panel.setContent(picker.view, focus: picker.searchField)
        panel.onDismiss = { [weak picker] in
            // After the paste has been sent, not before it.
            DispatchQueue.main.async { picker?.resetForNextOpen() }
        }
        picker.view.layoutSubtreeIfNeeded()
        panel.warmUp()
        self.panel = panel
        self.picker = picker

        // Hiding emoji the system can't draw runs CoreText per emoji: do it off the main thread.
        Task.detached(priority: .utility) {
            let renderable = catalog.renderableOnly()
            await MainActor.run {
                emojiTab.setCatalog(renderable)
                Self.log.info("renderable emoji: \(renderable.emojis.count, privacy: .public) of \(catalog.emojis.count, privacy: .public)")
            }
        }
    }

    private func makeTextTab(
        _ resource: String, file: String, directory: URL, limit: Int, columns: Int,
        cellHeight: CGFloat, fontSize: CGFloat, empty: String
    ) -> TextItemTab {
        let catalog: TextItemCatalog
        do {
            catalog = try TextItemCatalog.load(resource)
        } catch {
            Self.log.error("\(resource, privacy: .public) catalog failed to load: \(String(describing: error), privacy: .public)")
            catalog = TextItemCatalog(sections: [])
        }
        return TextItemTab(
            frame: NSRect(origin: .zero, size: PickerViewController.contentSize),
            catalog: catalog,
            recents: RecentsStore<TextItem>(fileURL: directory.appendingPathComponent(file), limit: limit),
            columns: columns, cellHeight: cellHeight, fontSize: fontSize, emptyMessage: empty,
            commit: { [weak self] payload in self?.commit(payload) })
    }

    /// A tab picked something (and already recorded it in its recents): close, then paste.
    private func commit(_ payload: InsertPayload) {
        let anchor = panel.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        panel?.dismiss() // non-activating panel: the target app stays frontmost
        let outcome = inserter.insert(payload)
        if case .copiedOnly = outcome {
            Self.log.notice("insert outcome: copied only")
            toast.show("Copied, press ⌘V", centeredOn: anchor ?? NSEvent.mouseLocation)
        }
    }

    /// Opens the Settings window (built on first use, never while the picker opens).
    private func openSettings() {
        panel?.dismiss()
        let controller: SettingsWindowController
        if let settings { controller = settings } else {
            controller = SettingsWindowController()
            controller.applyShortcut = { [weak self] s in self?.changeShortcut(s) ?? false }
            controller.pauseHotkey = { [weak self] paused in self?.hotkey?.isPaused = paused }
            controller.onRatingChange = { [weak self] in self?.gifTab?.ratingChanged() }
            settings = controller
        }
        controller.show(currentShortcut: hotkey?.current ?? SettingsWindowController.loadShortcut())
    }

    /// Registers and persists a new shortcut. On failure the previous one stays registered.
    private func changeShortcut(_ s: Shortcut) -> Bool {
        guard let hotkey else { return false }
        do {
            try hotkey.register(s)
        } catch {
            NSLog("hotkey re-registration failed: %@", String(describing: error))
            return false
        }
        SettingsWindowController.saveShortcut(s)
        updateShortcutWarning()
        return true
    }

    /// Adds the disabled "Shortcut unavailable" item while no shortcut is registered, removes it after.
    private func updateShortcutWarning() {
        guard let menu = statusItem?.menu else { return }
        let showing = shortcutWarning.menu === menu
        if hotkey?.current == nil, !showing {
            shortcutWarning.isEnabled = false
            menu.insertItem(shortcutWarning, at: 0)
        } else if hotkey?.current != nil, showing {
            menu.removeItem(shortcutWarning)
        }
    }

    /// A menu-bar-only app never shows its main menu, but AppKit still routes key equivalents
    /// through it. Without an Edit menu, ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in Settings' text fields.
    private static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Emoji Picker", action: nil, keyEquivalent: "")) // app menu slot
        main.addItem(editItem)
        return main
    }

    private func showAccessibilityOnboarding() {
        OnboardingWindowController.requestAccess()
        let onboarding = self.onboarding ?? OnboardingWindowController()
        onboarding.show()
        self.onboarding = onboarding
    }

    @objc private func grantAccessibilityFromMenu() { showAccessibilityOnboarding() }

    /// Shows "Grant Accessibility…" at the top of the menu while access is missing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let showing = accessibilityItem.menu === menu
        let trusted = AXIsProcessTrusted()
        if !trusted, !showing {
            menu.insertItem(accessibilityItem, at: 0)
        } else if trusted, showing {
            menu.removeItem(accessibilityItem)
        }
    }

    @objc private func openSettingsFromMenu() { openSettings() }

    @objc private func clearClipboardHistory() { clipboardHistory?.clearUnpinned() }

    private func togglePicker(hotkeyTime: UInt64) {
        guard let panel, let picker else { return }
        if panel.isVisible {
            panel.dismiss()
            return
        }
        let frame = Placement.frame(
            panelSize: PickerPanel.size,
            caret: CaretLocator.caretRect(),
            mouse: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.visibleFrame))
        inserter.rememberTarget()
        picker.willPresent()
        panel.present(at: frame, hotkeyTime: hotkeyTime)
    }
}
