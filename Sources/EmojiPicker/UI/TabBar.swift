import AppKit

enum PickerTab: Int, CaseIterable {
    case emoji, gif, kaomoji, symbols, clipboard

    var icon: String {
        switch self {
        case .emoji: "😊"
        case .gif: "GIF"
        case .kaomoji: ";-)"
        case .symbols: "Ω"
        case .clipboard: "📋"
        }
    }

    var title: String {
        switch self {
        case .emoji: "Emoji"
        case .gif: "GIFs"
        case .kaomoji: "Kaomoji"
        case .symbols: "Symbols"
        case .clipboard: "Clipboard history"
        }
    }

    var searchPlaceholder: String { self == .gif ? "Search GIFs" : "Search" }
}

/// Row of tab icons across the top of the picker.
final class TabBar: NSView {
    var onSelect: ((PickerTab) -> Void)?

    var selected: PickerTab = .emoji {
        didSet { for item in items { item.isSelected = item.tab == selected } }
    }

    private var items: [TabBarItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let gap: CGFloat = 2
        let tabs = PickerTab.allCases
        let width = (frame.width - gap * CGFloat(tabs.count - 1)) / CGFloat(tabs.count)
        for (i, tab) in tabs.enumerated() {
            let item = TabBarItem(
                frame: NSRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: frame.height),
                tab: tab)
            item.onClick = { [weak self] in self?.onSelect?(tab) }
            addSubview(item)
            items.append(item)
        }
        selected = .emoji
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private final class TabBarItem: NSView {
    let tab: PickerTab
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(frame: NSRect, tab: PickerTab) {
        self.tab = tab
        super.init(frame: frame)
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The tab row sits under the (hidden) title bar; clicks must select, not drag the panel.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: bounds.minX + 6, y: bounds.minY, width: bounds.width - 12, height: 2).fill()
        }
        let color: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        NSAttributedString(string: tab.icon, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: color,
        ]).drawCentered(in: bounds)
    }
}
