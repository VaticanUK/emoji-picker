import AppKit
import PickerCore

/// The picker's content: tab bar, search field and the active tab. Built once at launch; opening
/// the picker only resets cheap state (see `willPresent` and `resetForNextOpen`).
///
/// Keyboard focus moves between the active tab's zones (search, content, and on the emoji tab the
/// category bar) in software: the search field stays first responder and offers every key here.
final class PickerViewController: NSViewController {
    static let lastTabKey = "lastTab"

    let searchField = SearchField()
    private let tabBar: TabBar
    private var tabs: [PickerTab: PickerTabContent] = [:]
    private(set) var current: PickerTab
    private var zone: PickerZone = .search

    /// Area below the search field that hosts the tab content.
    static let contentSize = NSSize(width: PickerPanel.size.width, height: 340)

    init(tabs given: [PickerTab: PickerTabContent]) {
        let size = PickerPanel.size
        tabBar = TabBar(frame: NSRect(x: 8, y: size.height - 8 - 30, width: size.width - 16, height: 30))
        let stored = UserDefaults.standard.object(forKey: Self.lastTabKey) as? Int
        current = stored.flatMap(PickerTab.init(rawValue:)) ?? .emoji
        super.init(nibName: nil, bundle: nil)
        for tab in PickerTab.allCases {
            tabs[tab] = given[tab] ?? PlaceholderTab(frame: NSRect(origin: .zero, size: Self.contentSize))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let size = PickerPanel.size
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        tabBar.onSelect = { [weak self] tab in self?.select(tab) }
        root.addSubview(tabBar)

        let searchHeight = max(28, searchField.intrinsicContentSize.height)
        searchField.frame = NSRect(
            x: 8, y: tabBar.frame.minY - 8 - searchHeight, width: size.width - 16, height: searchHeight)
        searchField.onTextChange = { [weak self] text in self?.queryChanged(text) }
        searchField.onCommand = { [weak self] command in self?.handle(command) ?? false }
        root.addSubview(searchField)

        let contentHeight = searchField.frame.minY - 6
        for (tab, content) in tabs {
            content.onFocusRequest = { [weak self, weak content] zone in
                guard let self, content === self.activeTab else { return }
                self.setZone(zone)
            }
            content.view.frame = NSRect(x: 0, y: 0, width: size.width, height: contentHeight)
            content.view.autoresizingMask = [.width, .height]
            content.view.isHidden = tab != current
            root.addSubview(content.view)
        }
        view = root
        show(current)
    }

    private var activeTab: PickerTabContent { tabs[current]! }

    /// Replaces the query as if typed (e.g. a GIF quick-search chip).
    func setSearchText(_ text: String) { searchField.setText(text) }

    /// Call just before the panel is shown. Keep this cheap: it counts against the open-time budget.
    func willPresent() {
        if !searchField.stringValue.isEmpty { resetForNextOpen() }
        activeTab.didShow()
        setZone(.search)
    }

    /// Call after the panel is dismissed: clears the query and lays everything out while hidden.
    func resetForNextOpen() {
        searchField.clear()
        for content in tabs.values { content.setQuery("") }
        view.layoutSubtreeIfNeeded()
    }

    private func select(_ tab: PickerTab) {
        guard tab != current else { return }
        tabs[current]?.view.isHidden = true
        current = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
        show(tab)
        activeTab.setQuery(searchField.stringValue)
        activeTab.didShow()
        setZone(.search)
    }

    private func show(_ tab: PickerTab) {
        tabs[tab]?.view.isHidden = false
        tabBar.selected = tab
        searchField.placeholderString = tab.searchPlaceholder
    }

    // MARK: Keyboard zones

    private func setZone(_ new: PickerZone) {
        zone = activeTab.zones.contains(new) ? new : .search
        activeTab.focusChanged(to: zone)
    }

    /// Typing goes to the search field whatever the zone, so focus follows it there.
    private func queryChanged(_ text: String) {
        if zone != .search { setZone(.search) }
        activeTab.setQuery(text)
    }

    /// Returns true when the key is used up; false lets the search field handle it as text.
    private func handle(_ command: SearchCommand) -> Bool {
        let count = PickerTab.allCases.count
        switch command {
        case .nextZone:
            setZone(ZoneCycle(zones: activeTab.zones).next(after: zone))
        case .previousZone:
            setZone(ZoneCycle(zones: activeTab.zones).previous(before: zone))
        case .nextTab:
            select(PickerTab(rawValue: (current.rawValue + 1) % count)!)
        case .previousTab:
            select(PickerTab(rawValue: (current.rawValue + count - 1) % count)!)
        case .delete:
            // Backspace outside search returns there and deletes, even with an empty query.
            if zone != .search { setZone(.search) }
            return false
        case .move(let direction): return send(.move(direction))
        case .activate: _ = send(.activate) // Return never edits the field
        case .space: return send(.space)
        case .cancel:
            if !send(.cancel) { view.window?.cancelOperation(nil) }
        }
        return true
    }

    private func send(_ key: ZoneKey) -> Bool {
        switch activeTab.handle(key, in: zone) {
        case .handled:
            return true
        case .focus(let new):
            setZone(new)
            return true
        case .ignored:
            // Arrows outside search do nothing rather than moving the text cursor. Anything else
            // goes to the field (a Space is typed, which moves focus to search).
            if case .move = key { return zone != .search }
            return false
        }
    }
}

/// Stand-in for tabs that later tasks build.
private final class PlaceholderTab: PickerTabContent {
    let view: NSView

    init(frame: NSRect) {
        view = NSView(frame: frame)
        let label = NSTextField(labelWithString: "Coming soon")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: frame.midY - 10, width: frame.width, height: 20)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        view.addSubview(label)
    }

    let zones: [PickerZone] = [.search]
    var onFocusRequest: ((PickerZone) -> Void)?
    func setQuery(_ q: String) {}
    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult { .ignored }
    func focusChanged(to zone: PickerZone) {}
    func didShow() {}
}
