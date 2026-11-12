import AppKit
import ImageIO
import PickerCore

/// Clipboard history tab: a vertical list with a "Pinned" section above "Recent". Text rows show a
/// 2-line preview, image rows a thumbnail (decoded off the main thread, only for visible rows). Pin
/// and delete buttons appear on hover. Nothing here takes first responder, so the search field
/// keeps focus. The list follows `history.onChange`, whatever made the change.
@MainActor
final class ClipboardTab: NSObject, PickerTabContent, NSTableViewDataSource, NSTableViewDelegate {
    fileprivate enum Row {
        case header(String)
        case item(ClipItem)
    }

    static let textRowHeight: CGFloat = 46
    static let imageRowHeight: CGFloat = 78
    static let headerRowHeight: CGFloat = 22
    static let thumbnailHeight: CGFloat = 64

    let view: NSView

    private let history: ClipboardHistory
    private let commit: (InsertPayload) -> Void
    private let table = ListTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing copied yet")
    private let clearButton = NSButton(title: "Clear all", target: nil, action: nil)
    private let thumbnails = NSCache<NSUUID, NSImage>()
    private var rows: [Row] = []
    private var query = ""
    private var selectedID: UUID?
    private var dirty = false
    /// The picker's keyboard zone is on the list: the selection is drawn emphasised (accent)
    /// rather than grey.
    private var listFocused = false

    init(frame: NSRect, history: ClipboardHistory, commit: @escaping (InsertPayload) -> Void) {
        self.history = history
        self.commit = commit
        view = NSView(frame: frame)
        super.init()

        let headerHeight: CGFloat = 28
        let title = NSTextField(labelWithString: "Clipboard history")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: frame.height - headerHeight + 5, width: 200, height: 18)
        title.autoresizingMask = [.minYMargin]
        view.addSubview(title)

        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.refusesFirstResponder = true
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.sizeToFit()
        clearButton.frame.origin = NSPoint(
            x: frame.width - clearButton.frame.width - 12, y: frame.height - headerHeight + 4)
        clearButton.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(clearButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - headerHeight)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // A new column is 100 pt wide, and the table only resizes it on later frame changes, so
        // rows showed one or two characters. Fill the visible width now.
        column.width = scroll.contentSize.width
        table.sizeLastColumnToFit()
        scroll.drawsBackground = false
        view.addSubview(scroll)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: scroll.frame.midY - 10, width: frame.width, height: 20)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        view.addSubview(emptyLabel)

        thumbnails.countLimit = 60
        rebuild()
    }

    // MARK: PickerTabContent

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        rebuild()
    }

    let zones: [PickerZone] = [.search, .content]
    var onFocusRequest: ((PickerZone) -> Void)?

    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult {
        handleSearchOrContent(key, in: zone, move: moveSelection, activate: { activate(row: table.selectedRow) })
    }

    func focusChanged(to zone: PickerZone) {
        listFocused = zone == .content
        if listFocused, table.selectedRow < 0 { selectFirstItem() }
        table.enumerateAvailableRowViews { rowView, _ in (rowView as? ClipRowView)?.focused = listFocused }
    }

    /// Returns whether the selection moved (false at the top or bottom, and for ←/→).
    private func moveSelection(_ d: Direction) -> Bool {
        let step: Int
        switch d {
        case .up: step = -1
        case .down: step = 1
        case .left, .right: return false
        }
        var i = table.selectedRow + step
        while rows.indices.contains(i) {
            if case .item = rows[i] {
                select(row: i)
                return true
            }
            i += step
        }
        return false
    }

    func didShow() {
        table.sizeLastColumnToFit()
        if dirty { rebuild() }
        selectedID = nil
        selectFirstItem()
        table.scrollRowToVisible(0)
    }

    /// The history changed (copy, pin, delete or clear). Rebuild now only if the list is on screen.
    func historyChanged() {
        if view.isHidden || view.window?.isVisible != true {
            dirty = true
        } else {
            rebuild()
        }
    }

    // MARK: Rows

    private func rebuild() {
        dirty = false
        let (pinned, recent) = history.sections(query: query)
        rows = []
        if !pinned.isEmpty {
            rows.append(.header("Pinned"))
            rows += pinned.map(Row.item)
        }
        if !recent.isEmpty {
            // Windows labels the section even when nothing is pinned.
            rows.append(.header("Recent"))
            rows += recent.map(Row.item)
        }
        table.reloadData()
        emptyLabel.stringValue = history.items.isEmpty ? "Nothing copied yet" : "No matches"
        emptyLabel.isHidden = !rows.isEmpty
        if let id = selectedID, let i = rows.firstIndex(where: { $0.itemID == id }) {
            select(row: i)
        } else {
            selectFirstItem()
        }
    }

    private func selectFirstItem() {
        if let i = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            select(row: i)
        } else {
            table.deselectAll(nil)
        }
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        selectedID = rows[row].itemID
    }

    private func activate(row: Int) {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return }
        let payload = history.payload(for: item.id)
        guard !payload.isEmpty else { return }
        commit(.pasteboardItems(payload))
    }

    @objc private func rowClicked() {
        onFocusRequest?(.content)
        activate(row: table.clickedRow)
    }

    @objc private func clearAll() { history.clearUnpinned() }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if rows.indices.contains(row) { selectedID = rows[row].itemID }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ClipRowView()
        rowView.focused = listFocused
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: Self.headerRowHeight
        case .item(let item):
            if case .image = item.kind { Self.imageRowHeight } else { Self.textRowHeight }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("clipRow")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipRowCell) ?? ClipRowCell()
            cell.identifier = id
            cell.configure(item: item)
            if case .image = item.kind { loadThumbnail(for: item.id, into: cell) }
            cell.onPin = { [weak self] in self?.history.togglePin(item.id) }
            cell.onDelete = { [weak self] in self?.history.delete(item.id) }
            return cell
        }
    }

    // MARK: Thumbnails

    /// Shows the cached thumbnail, or decodes one off the main thread and sets it if the cell
    /// still shows the same item by then.
    private func loadThumbnail(for id: UUID, into cell: ClipRowCell) {
        let key = id as NSUUID
        if let cached = thumbnails.object(forKey: key) {
            cell.thumbnail = cached
            return
        }
        guard let url = history.thumbnailSourceURL(for: id) else { return }
        cell.thumbnailTask = Task { [weak self, weak cell] in
            let image = await Task.detached(priority: .userInitiated) { Self.decodeThumbnail(url) }.value
            guard let image, !Task.isCancelled else { return }
            self?.thumbnails.setObject(image, forKey: key)
            if let cell, cell.itemID == id { cell.thumbnail = image }
        }
    }

    private nonisolated static func decodeThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ClipboardHistory.thumbnailMaxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

fileprivate extension ClipboardTab.Row {
    var itemID: UUID? {
        if case .item(let item) = self { return item.id }
        return nil
    }
}

/// Never takes focus, so clicks and scrolling leave the search field editing.
private final class ListTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Row background. The table never becomes first responder, so AppKit would always draw the
/// selection grey; this draws it in the accent colour while the list is the focused zone.
private final class ClipRowView: NSTableRowView {
    var focused = false {
        didSet {
            guard focused != oldValue else { return }
            needsDisplay = true
            updateInteriorStyle()
        }
    }

    override var isEmphasized: Bool {
        get { focused }
        set {}
    }

    override var isSelected: Bool {
        didSet { updateInteriorStyle() }
    }

    /// Light text and icons on the accent fill; normal ones on the grey (unfocused) fill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        focused && isSelected ? .emphasized : .normal
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ClipRowCell)?.backgroundStyle = interiorBackgroundStyle
    }

    private func updateInteriorStyle() {
        for case let cell as ClipRowCell in subviews { cell.backgroundStyle = interiorBackgroundStyle }
    }
}

/// One history row: preview or thumbnail, plus pin and delete buttons shown on hover.
private final class ClipRowCell: NSView {
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?
    /// The item shown; a thumbnail that finishes decoding is only set if it still matches.
    private(set) var itemID: UUID?
    var thumbnailTask: Task<Void, Never>?
    var thumbnail: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let imageView = NSImageView()
    private let pinButton = NSButton()
    private let deleteButton = NSButton()
    private var pinned = false
    private var hovering = false { didSet { updateButtons() } }
    /// Set by the row view: `.emphasized` on the focused (accent) selection.
    @objc var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            label.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            for button in [pinButton, deleteButton] {
                button.contentTintColor = emphasized ? .alternateSelectedControlTextColor : nil
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = false
        label.cell?.truncatesLastVisibleLine = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignLeft
        for (button, symbol, tip, action) in [
            (pinButton, "pin", "Pin", #selector(pinClicked)),
            (deleteButton, "xmark", "Delete", #selector(deleteClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.refusesFirstResponder = true
            button.target = self
            button.action = action
        }
        for v in [label, imageView, pinButton, deleteButton] { addSubview(v) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: ClipItem) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        itemID = item.id
        imageView.image = nil
        pinned = item.pinned
        hovering = false
        switch item.kind {
        case .text(let s):
            label.stringValue = String(s.prefix(300))
            label.isHidden = false
            imageView.isHidden = true
        case .image:
            imageView.isHidden = false
            label.isHidden = true
        }
        pinButton.image = NSImage(
            systemSymbolName: item.pinned ? "pin.fill" : "pin",
            accessibilityDescription: item.pinned ? "Unpin" : "Pin")
        pinButton.toolTip = item.pinned ? "Unpin" : "Pin"
        needsLayout = true
    }

    private func updateButtons() {
        pinButton.isHidden = !(hovering || pinned)
        deleteButton.isHidden = !hovering
    }

    override func layout() {
        super.layout()
        let button: CGFloat = 22, margin: CGFloat = 8
        deleteButton.frame = NSRect(x: bounds.width - margin - button, y: bounds.midY - button / 2,
                                    width: button, height: button)
        pinButton.frame = deleteButton.frame.offsetBy(dx: -button - 2, dy: 0)
        let contentWidth = pinButton.frame.minX - 6 - 12
        label.frame = NSRect(x: 12, y: 3, width: contentWidth, height: bounds.height - 6)
        imageView.frame = NSRect(x: 12, y: (bounds.height - ClipboardTab.thumbnailHeight) / 2,
                                 width: contentWidth, height: ClipboardTab.thumbnailHeight)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func pinClicked() { onPin?() }
    @objc private func deleteClicked() { onDelete?() }
}
