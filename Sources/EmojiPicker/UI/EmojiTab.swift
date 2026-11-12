import AppKit
import PickerCore

/// The emoji tab: "Most recently used" then one section per category, or a single "Results"
/// section while searching. Recents hold base emoji; the skin tone is applied when drawing and
/// when inserting. Keyboard zones: search, grid, then the category bar.
final class EmojiTab: PickerTabContent {
    static let skinToneKey = "skinTone"
    static let columns = 9

    let view: NSView

    private let grid: GridView
    private let categoryBar: CategoryBar
    private let swatches = ToneSwatches()
    private let recents: RecentsStore<String>
    private let commit: (InsertPayload) -> Void

    private var byCategory: [EmojiCategory: [Emoji]] = [:]
    private var byBase: [String: Emoji] = [:]
    private var catalog: EmojiCatalog
    private var query = ""
    private var tone: SkinTone
    /// Emoji behind each grid section, parallel to the grid's sections.
    private var shown: [[Emoji]] = []
    private var titles: [String] = []
    private var sectionOfCategory: [EmojiCategory: Int] = [:]
    private var recentsSection: Int?
    private var recentsChanged = false
    /// The category-bar button the keyboard is on (shown only while the bar is the focused zone).
    private var barSlot: CategoryBarSlot = .category(.smileys)

    init(frame: NSRect, catalog: EmojiCatalog, recents: RecentsStore<String>,
         commit: @escaping (InsertPayload) -> Void) {
        self.catalog = catalog
        self.recents = recents
        self.commit = commit
        let stored = UserDefaults.standard.object(forKey: Self.skinToneKey) as? Int
        tone = stored.flatMap(SkinTone.init(rawValue:)) ?? .none

        view = NSView(frame: frame)
        categoryBar = CategoryBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: CategoryBar.height))
        categoryBar.autoresizingMask = [.width]
        grid = GridView(
            frame: NSRect(x: 0, y: CategoryBar.height, width: frame.width, height: frame.height - CategoryBar.height),
            columns: Self.columns, cellHeight: 38, fontSize: 24)
        grid.autoresizingMask = [.width, .height]
        grid.emptyMessage = "No emoji found"
        view.addSubview(grid)
        view.addSubview(categoryBar)

        swatches.isHidden = true
        view.addSubview(swatches)

        grid.onActivate = { [weak self] index in self?.activate(index) }
        grid.onMouseDown = { [weak self] in
            self?.hideSwatches()
            self?.onFocusRequest?(.content)
        }
        categoryBar.onSelect = { [weak self] target in
            self?.jump(to: target)
            self?.onFocusRequest?(.content)
        }
        categoryBar.onToneButton = { [weak self] in self?.toggleSwatches() }
        categoryBar.setTone(tone)
        swatches.selected = tone
        swatches.onPick = { [weak self] tone in self?.setTone(tone) }

        index(catalog)
        rebuild()
    }

    /// Swaps in a new catalog (the renderable-only one once it's computed in the background).
    func setCatalog(_ newCatalog: EmojiCatalog) {
        catalog = newCatalog
        index(newCatalog)
        rebuild()
    }

    // MARK: PickerTabContent

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query || recentsChanged else { return }
        query = trimmed
        rebuild()
    }

    let zones: [PickerZone] = [.search, .content, .categoryBar]
    var onFocusRequest: ((PickerZone) -> Void)?

    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult {
        // Open swatches (from the keyboard or the mouse) take the keys, whatever the zone.
        if !swatches.isHidden { return handleSwatchKey(key, in: zone) }
        guard zone == .categoryBar else {
            return handleSearchOrContent(
                key, in: zone, move: { grid.moveSelection($0) }, activate: grid.activateSelection)
        }
        switch key {
        case .move(.up): return .focus(.content)
        case .move(let direction):
            barSlot = categoryBar.navigator.move(barSlot, direction)
            categoryBar.focusedSlot = barSlot
            return .handled
        case .activate, .space: return press(categoryBar.navigator.valid(barSlot))
        case .cancel: return .ignored
        }
    }

    func focusChanged(to zone: PickerZone) {
        grid.showsFocus = zone == .content
        if zone == .content { grid.ensureSelection() }
        if zone == .categoryBar {
            // Start on the button for the section that's highlighted in the grid.
            barSlot = categoryBar.navigator.valid(slotForGridSelection ?? barSlot)
            categoryBar.focusedSlot = barSlot
        } else {
            categoryBar.focusedSlot = nil
            if swatches.focused != nil { hideSwatches() } // opened from the keyboard
        }
    }

    func didShow() {
        hideSwatches()
        if recentsChanged { rebuild() }
        grid.resetSelectionAndScroll()
    }

    // MARK: Category bar keys

    /// Return or Space on a bar button: a category jumps there and focuses the grid; the tone
    /// button opens the swatches.
    private func press(_ slot: CategoryBarSlot) -> ZoneResult {
        switch slot {
        case .recents:
            jump(to: .recents)
            return .focus(.content)
        case .category(let category):
            jump(to: .category(category))
            return .focus(.content)
        case .tone:
            showSwatches()
            swatches.focused = tone
            return .handled
        }
    }

    /// ←/→ focus a swatch (the first press focuses the current tone), Return picks the focused
    /// one (nothing if none is focused) and Esc closes. Space picks only from the category bar;
    /// elsewhere it's typed.
    private func handleSwatchKey(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult {
        switch key {
        case .move(let direction) where direction == .left || direction == .right:
            swatches.focused = swatches.focused.map { $0.moved(direction) } ?? tone
        case .move:
            break
        case .space where zone != .categoryBar:
            return .ignored
        case .activate, .space:
            if let focused = swatches.focused { setTone(focused) }
        case .cancel:
            hideSwatches()
        }
        return .handled
    }

    private var slotForGridSelection: CategoryBarSlot? {
        guard query.isEmpty, let section = grid.selection?.section else { return nil }
        if section == recentsSection { return .recents }
        return sectionOfCategory.first { $0.value == section }.map { .category($0.key) }
    }

    // MARK: Content

    private func index(_ catalog: EmojiCatalog) {
        byCategory = Dictionary(grouping: catalog.emojis, by: \.c)
        byBase = Dictionary(catalog.emojis.map { ($0.e, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func rebuild() {
        recentsChanged = false
        shown = []
        titles = []
        sectionOfCategory = [:]
        recentsSection = nil
        if query.isEmpty {
            let recent = recents.items.compactMap { byBase[$0] }
            if !recent.isEmpty {
                recentsSection = 0
                titles.append("Most recently used")
                shown.append(recent)
            }
            for category in EmojiCategory.allCases {
                sectionOfCategory[category] = shown.count
                titles.append(category.title)
                shown.append(byCategory[category] ?? [])
            }
        } else {
            titles = ["Results"]
            shown = [catalog.search(query)]
        }
        categoryBar.setRecentsVisible(recentsSection != nil)
        categoryBar.setCategoriesEnabled(query.isEmpty)
        grid.setSections(gridSections())
    }

    private func gridSections() -> [GridSection] {
        zip(titles, shown).map { title, emojis in
            GridSection(title: title, items: emojis.map {
                GridItem(text: EmojiCatalog.apply(tone, to: $0), tooltip: $0.n)
            })
        }
    }

    // MARK: Actions

    private func activate(_ index: GridIndex) {
        guard shown.indices.contains(index.section), shown[index.section].indices.contains(index.item) else { return }
        let emoji = shown[index.section][index.item]
        recents.record(emoji.e)
        recentsChanged = true
        commit(.text(EmojiCatalog.apply(tone, to: emoji)))
    }

    private func jump(to target: CategoryTarget) {
        hideSwatches()
        switch target {
        case .recents:
            if let recentsSection { grid.scrollToSection(recentsSection) }
        case .category(let category):
            if let section = sectionOfCategory[category] { grid.scrollToSection(section) }
        }
    }

    private func toggleSwatches() {
        if swatches.isHidden { showSwatches() } else { hideSwatches() }
    }

    private func showSwatches() {
        let button = view.convert(categoryBar.toneButtonFrame, from: categoryBar)
        let size = ToneSwatches.size
        let x = min(max(button.midX - size.width / 2, 4), view.bounds.width - 4 - size.width)
        swatches.frame = NSRect(x: x, y: button.maxY + 2, width: size.width, height: size.height)
        swatches.isHidden = false
    }

    private func hideSwatches() {
        swatches.isHidden = true
        swatches.focused = nil
    }

    private func setTone(_ newTone: SkinTone) {
        hideSwatches()
        guard newTone != tone else { return }
        tone = newTone
        UserDefaults.standard.set(newTone.rawValue, forKey: Self.skinToneKey)
        categoryBar.setTone(newTone)
        swatches.selected = newTone
        grid.refreshItems(gridSections())
    }
}
