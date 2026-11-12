import AppKit
import PickerCore

/// Kaomoji and Symbols tabs: "Most recently used" then one section per catalog section, or a
/// single "Results" section while searching. Items are inserted as the exact stored string.
final class TextItemTab: PickerTabContent {
    static let kaomojiColumns = 3
    static let symbolsColumns = 9

    let view: NSView

    private let grid: GridView
    private let catalog: TextItemCatalog
    private let recents: RecentsStore<TextItem>
    private let commit: (InsertPayload) -> Void
    private var query = ""
    private var titles: [String] = []
    /// Items behind each grid section, parallel to the grid's sections.
    private var shown: [[TextItem]] = []
    private var recentsChanged = false

    init(frame: NSRect, catalog: TextItemCatalog, recents: RecentsStore<TextItem>, columns: Int,
         cellHeight: CGFloat, fontSize: CGFloat, emptyMessage: String,
         commit: @escaping (InsertPayload) -> Void) {
        self.catalog = catalog
        self.recents = recents
        self.commit = commit
        view = NSView(frame: frame)
        grid = GridView(frame: frame, columns: columns, cellHeight: cellHeight, fontSize: fontSize)
        grid.autoresizingMask = [.width, .height]
        grid.emptyMessage = emptyMessage
        view.addSubview(grid)
        grid.onActivate = { [weak self] index in self?.activate(index) }
        grid.onMouseDown = { [weak self] in self?.onFocusRequest?(.content) }
        rebuild()
    }

    // MARK: PickerTabContent

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query || recentsChanged else { return }
        query = trimmed
        rebuild()
    }

    let zones: [PickerZone] = [.search, .content]
    var onFocusRequest: ((PickerZone) -> Void)?

    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult {
        handleSearchOrContent(key, in: zone, move: { grid.moveSelection($0) }, activate: grid.activateSelection)
    }

    func focusChanged(to zone: PickerZone) {
        grid.showsFocus = zone == .content
        if zone == .content { grid.ensureSelection() }
    }

    func didShow() {
        if recentsChanged { rebuild() }
        grid.resetSelectionAndScroll()
    }

    // MARK: Content

    private func rebuild() {
        recentsChanged = false
        titles = []
        shown = []
        if query.isEmpty {
            if !recents.items.isEmpty {
                titles.append("Most recently used")
                shown.append(recents.items)
            }
            for section in catalog.sections {
                titles.append(section.title)
                shown.append(section.items)
            }
        } else {
            titles = ["Results"]
            shown = [catalog.search(query)]
        }
        grid.setSections(zip(titles, shown).map { title, items in
            GridSection(title: title, items: items.map {
                GridItem(text: $0.s, tooltip: $0.k.prefix(3).joined(separator: " "))
            })
        })
    }

    private func activate(_ index: GridIndex) {
        guard shown.indices.contains(index.section), shown[index.section].indices.contains(index.item) else { return }
        let item = shown[index.section][index.item]
        recents.record(item)
        recentsChanged = true
        commit(.text(item.s))
    }
}
