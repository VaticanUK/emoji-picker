import AppKit
import PickerCore

struct GridItem {
    let text: String
    /// Shown in the hover tip (for emoji, the name).
    let tooltip: String
}

struct GridSection {
    let title: String
    let items: [GridItem]
}

/// Sectioned grid of text cells (emoji, kaomoji, symbols) on `NSCollectionView`, so only the visible
/// cells exist. Owns the highlight: arrow keys move it via `GridNavigator`, hovering moves it, and a
/// click or `activateSelection` reports it through `onActivate`. Never takes keyboard focus; the
/// picker sets `showsFocus` when its keyboard zone is on the grid, and the highlight is dimmed otherwise.
final class GridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    static let horizontalInset: CGFloat = 8
    static let headerHeight: CGFloat = 24
    private static let tipDelay: TimeInterval = 0.4

    var onActivate: ((GridIndex) -> Void)?
    /// Any mouse-down in the grid (used to close transient overlays such as the tone swatches).
    var onMouseDown: (() -> Void)?
    var emptyMessage = "No results" { didSet { emptyLabel.stringValue = emptyMessage } }

    private(set) var selection: GridIndex?

    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue, let selection else { return }
            cellView(at: selection)?.isDimmed = !showsFocus
        }
    }

    private let font: NSFont
    private let scrollView: NSScrollView
    private let collectionView = GridCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let tip = HoverTip()
    private var sections: [GridSection] = []
    private var navigator: GridNavigator
    private let columns: Int
    private var pressed: GridIndex?
    private var pendingTip: DispatchWorkItem?
    /// Mouse position when the grid was last reset (panel shown). Hover is ignored until the mouse
    /// has really moved from here, so a panel that opens under a stationary pointer doesn't steal
    /// the keyboard highlight.
    private var mouseAtReset: NSPoint?
    private var hoverArmed = true

    init(frame: NSRect, columns: Int, cellHeight: CGFloat, fontSize: CGFloat) {
        self.columns = columns
        self.font = .systemFont(ofSize: fontSize)
        self.navigator = GridNavigator(sectionCounts: [], columns: columns)
        self.scrollView = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        let cellWidth = floor((frame.width - 2 * Self.horizontalInset) / CGFloat(columns))
        layout.itemSize = NSSize(width: cellWidth, height: cellHeight)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0

        collectionView.frame = NSRect(origin: .zero, size: frame.size)
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(GridCell.self, forItemWithIdentifier: GridCell.identifier)
        collectionView.register(
            GridHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GridHeader.identifier)
        collectionView.onHover = { [weak self] point in self?.hover(at: point) }
        collectionView.onPress = { [weak self] point in self?.press(at: point) }
        collectionView.onRelease = { [weak self] point in self?.release(at: point) }

        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Overlay scrollers always: a legacy scroller would eat width and drop a column.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)

        emptyLabel.stringValue = emptyMessage
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        tip.isHidden = true
        addSubview(tip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Content

    /// Replaces the content, highlights the first item and scrolls to the top.
    func setSections(_ newSections: [GridSection]) {
        sections = newSections
        navigator = GridNavigator(sectionCounts: newSections.map(\.items.count), columns: columns)
        emptyLabel.isHidden = newSections.contains { !$0.items.isEmpty }
        hideTip()
        selection = firstIndex
        collectionView.reloadData()
        scrollToTop()
    }

    /// Updates the cell text for content of the same shape (e.g. a skin-tone change) without a
    /// reload: only the visible cells are redrawn, keeping scroll position and highlight.
    func refreshItems(_ newSections: [GridSection]) {
        guard newSections.map(\.items.count) == sections.map(\.items.count) else {
            setSections(newSections)
            return
        }
        sections = newSections
        for path in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: path) as? GridCell)?.cellView.text = item(at: path).text
        }
    }

    /// Prepares the collection view's layout now (e.g. while the panel is hidden) so showing it is cheap.
    func prepareLayout() { scrollView.layoutSubtreeIfNeeded() }

    // MARK: Selection

    func resetSelectionAndScroll() {
        hideTip()
        mouseAtReset = NSEvent.mouseLocation
        hoverArmed = false
        setSelection(firstIndex, scroll: false)
        scrollToTop()
    }

    /// Returns whether the highlight moved (false at the grid's edges, e.g. ↑ on the top row).
    @discardableResult
    func moveSelection(_ direction: Direction) -> Bool {
        hideTip()
        guard let current = selection else {
            setSelection(firstIndex, scroll: true)
            return selection != nil
        }
        let next = navigator.move(current, direction)
        setSelection(next, scroll: true)
        return next != current
    }

    /// Highlights the first item if nothing is highlighted, e.g. when focus moves onto the grid.
    func ensureSelection() {
        if selection == nil { setSelection(firstIndex, scroll: true) }
    }

    func activateSelection() {
        guard let selection else { return }
        onActivate?(selection)
    }

    /// Scrolls so the section's header is at the top and highlights its first item.
    func scrollToSection(_ section: Int) {
        guard sections.indices.contains(section), !sections[section].items.isEmpty else { return }
        hideTip()
        setSelection(GridIndex(section: section, item: 0), scroll: false)
        prepareLayout()
        let path = IndexPath(item: 0, section: section)
        guard let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: NSCollectionView.elementKindSectionHeader, at: path) else { return }
        scroll(toY: header.frame.minY)
    }

    private var firstIndex: GridIndex? {
        sections.indices.first { !sections[$0].items.isEmpty }.map { GridIndex(section: $0, item: 0) }
    }

    private func setSelection(_ new: GridIndex?, scroll: Bool) {
        let old = selection
        selection = new
        if let old, old != new { cellView(at: old)?.isHighlighted = false }
        guard let new else { return }
        if let cell = cellView(at: new) {
            cell.isDimmed = !showsFocus
            cell.isHighlighted = true
        }
        if scroll { scrollIntoView(new) }
    }

    private func cellView(at index: GridIndex) -> GridCellView? {
        (collectionView.item(at: IndexPath(item: index.item, section: index.section)) as? GridCell)?.cellView
    }

    // MARK: Scrolling

    private func scrollToTop() { scroll(toY: 0) }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollIntoView(_ index: GridIndex) {
        prepareLayout()
        guard let attributes = collectionView.layoutAttributesForItem(
            at: IndexPath(item: index.item, section: index.section)) else { return }
        var rect = attributes.frame
        if index.item < columns {
            // First row of a section: bring its header into view too.
            rect.origin.y -= Self.headerHeight
            rect.size.height += Self.headerHeight
        }
        collectionView.scrollToVisible(rect)
    }

    @objc private func didScroll() { hideTip() }

    // MARK: Mouse

    private func index(at point: NSPoint) -> GridIndex? {
        collectionView.indexPathForItem(at: point).map { GridIndex(section: $0.section, item: $0.item) }
    }

    private func hover(at point: NSPoint?) {
        guard let point, let index = index(at: point) else {
            hideTip()
            return
        }
        if !hoverArmed {
            guard NSEvent.mouseLocation != mouseAtReset else { return }
            hoverArmed = true
        }
        // Still over the same cell with its tip shown or pending: don't restart the delay.
        if index == selection, !tip.isHidden || pendingTip != nil { return }
        setSelection(index, scroll: false)
        scheduleTip(for: index)
    }

    private func press(at point: NSPoint) {
        hideTip()
        onMouseDown?()
        pressed = index(at: point)
    }

    private func release(at point: NSPoint) {
        defer { pressed = nil }
        guard let index = index(at: point), index == pressed else { return }
        setSelection(index, scroll: false)
        onActivate?(index)
    }

    // MARK: Hover tip

    private func scheduleTip(for index: GridIndex) {
        hideTip()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showTip(for: index) }
        }
        pendingTip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tipDelay, execute: work)
    }

    private func showTip(for index: GridIndex) {
        pendingTip = nil
        guard selection == index,
              let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index.item, section: index.section))
        else { return }
        let text = sections[index.section].items[index.item].tooltip
        guard !text.isEmpty else { return }
        tip.show(text, near: convert(attributes.frame, from: collectionView), in: bounds)
    }

    private func hideTip() {
        pendingTip?.cancel()
        pendingTip = nil
        tip.isHidden = true
    }

    // MARK: NSCollectionViewDataSource / DelegateFlowLayout

    private func item(at path: IndexPath) -> GridItem { sections[path.section].items[path.item] }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GridCell.identifier, for: indexPath)
        if let cell = cell as? GridCell {
            cell.cellView.font = font
            cell.cellView.text = item(at: indexPath).text
            cell.cellView.isHighlighted = selection == GridIndex(section: indexPath.section, item: indexPath.item)
            cell.cellView.isDimmed = !showsFocus
        }
        return cell
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: GridHeader.identifier, for: indexPath)
        (view as? GridHeader)?.title = sections[indexPath.section].title
        return view
    }

    func collectionView(
        _ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> NSSize {
        sections[section].items.isEmpty ? .zero : NSSize(width: collectionView.bounds.width, height: Self.headerHeight)
    }

    func collectionView(
        _ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        sections[section].items.isEmpty
            ? NSEdgeInsetsZero
            : NSEdgeInsets(top: 0, left: Self.horizontalInset, bottom: 6, right: Self.horizontalInset)
    }
}

// MARK: - Pieces

/// Collection view that never takes focus (typing stays in the search field) and reports the mouse.
final class GridCollectionView: NSCollectionView {
    var onHover: ((NSPoint?) -> Void)?
    var onPress: ((NSPoint) -> Void)?
    var onRelease: ((NSPoint) -> Void)?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        // .activeAlways: the panel is key while our app stays inactive (non-activating panel).
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
    override func mouseMoved(with event: NSEvent) { onHover?(point(event)) }
    override func mouseEntered(with event: NSEvent) { onHover?(point(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onPress?(point(event)) }
    override func mouseUp(with event: NSEvent) { onRelease?(point(event)) }
}

final class GridCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    let cellView = GridCellView()
    override func loadView() { view = cellView }
}

final class GridCellView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }
    /// Keyboard focus is elsewhere (the search field): draw the highlight fainter, as a hint of
    /// where Return goes.
    var isDimmed = false { didSet { if isDimmed != oldValue { needsDisplay = true } } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(isDimmed ? 0.1 : 0.22).setFill()
            box.fill()
            if isDimmed {
                NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
                box.stroke()
            }
        }
        let area = bounds.insetBy(dx: 2, dy: 0)
        var drawFont = font
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        if width > area.width, width > 0 {
            // Long kaomoji: shrink the font (down to 70%) before truncating the middle.
            let scale = max(area.width / width, 0.7)
            drawFont = NSFont.systemFont(ofSize: font.pointSize * scale)
        }
        NSAttributedString(string: text, attributes: [.font: drawFont, .foregroundColor: NSColor.labelColor])
            .drawCentered(in: area, truncation: .byTruncatingMiddle)
    }
}

private final class GridHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridHeader")
    var title = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let string = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: GridView.horizontalInset + 2, y: (bounds.height - size.height) / 2))
    }
}

/// Small in-panel name label. AppKit tool tips aren't reliable while our app is inactive, which it
/// always is (non-activating panel), so the grid draws its own.
private final class HoverTip: NSView {
    private var string = NSAttributedString()
    private static let padding = NSSize(width: 8, height: 4)

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, near cell: NSRect, in container: NSRect) {
        string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = string.size()
        let size = NSSize(
            width: min(ceil(textSize.width) + 2 * Self.padding.width, container.width - 8),
            height: ceil(textSize.height) + 2 * Self.padding.height)
        var origin = NSPoint(x: cell.midX - size.width / 2, y: cell.maxY + 2)
        if origin.y + size.height > container.maxY { origin.y = cell.minY - size.height - 2 }
        origin.x = min(max(origin.x, container.minX + 4), container.maxX - 4 - size.width)
        frame = NSRect(origin: origin, size: size)
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        string.drawCentered(in: bounds.insetBy(dx: Self.padding.width, dy: 0))
    }
}

extension NSAttributedString {
    /// Draws on one line, centred in `rect`, truncating (tail by default) if it doesn't fit.
    func drawCentered(in rect: NSRect, truncation: NSLineBreakMode = .byTruncatingTail) {
        let size = self.size()
        let height = ceil(size.height)
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = truncation
        let styled = NSMutableAttributedString(attributedString: self)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
        styled.draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
