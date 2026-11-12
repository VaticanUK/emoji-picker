import AppKit
import PickerCore

extension EmojiCategory {
    var icon: String {
        switch self {
        case .smileys: "😊"
        case .people: "👋"
        case .animals: "🐻"
        case .food: "🍔"
        case .travel: "🚗"
        case .activities: "⚽"
        case .objects: "💡"
        case .symbols: "❤️"
        case .flags: "🏳️"
        }
    }

    var title: String {
        switch self {
        case .smileys: "Smileys & emotion"
        case .people: "People & body"
        case .animals: "Animals & nature"
        case .food: "Food & drink"
        case .travel: "Travel & places"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }
}

extension SkinTone {
    /// The raised hand in this tone, used for the tone button and swatches.
    var hand: String {
        switch self {
        case .none: "✋"
        case .light: "✋🏻"
        case .mediumLight: "✋🏼"
        case .medium: "✋🏽"
        case .mediumDark: "✋🏾"
        case .dark: "✋🏿"
        }
    }

    var title: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-light"
        case .medium: "Medium"
        case .mediumDark: "Medium-dark"
        case .dark: "Dark"
        }
    }
}

enum CategoryTarget {
    case recents
    case category(EmojiCategory)
}

/// Bottom bar of the emoji tab: 🕘, one button per category, and the skin-tone button. The buttons
/// never take first responder; while the picker's keyboard zone is on the bar, `focusedSlot` draws
/// a focus highlight behind one of them.
final class CategoryBar: NSView {
    static let height: CGFloat = 36

    var onSelect: ((CategoryTarget) -> Void)?
    var onToneButton: (() -> Void)?
    /// The keyboard-focused button, or nil when the bar isn't the focused zone.
    var focusedSlot: CategoryBarSlot? { didSet { if focusedSlot != oldValue { needsDisplay = true } } }
    private var categoriesEnabled = true

    private let recentsButton: NSButton
    private let categoryButtons: [NSButton]
    private let toneButton: NSButton
    private let stack = NSStackView()

    override init(frame: NSRect) {
        recentsButton = Self.makeButton("🕘", tip: "Most recently used")
        categoryButtons = EmojiCategory.allCases.map { Self.makeButton($0.icon, tip: $0.title) }
        toneButton = Self.makeButton(SkinTone.none.hand, tip: "Skin tone")
        super.init(frame: frame)

        recentsButton.target = self
        recentsButton.action = #selector(recentsClicked)
        for (i, button) in categoryButtons.enumerated() {
            button.tag = i
            button.target = self
            button.action = #selector(categoryClicked(_:))
        }
        toneButton.target = self
        toneButton.action = #selector(toneClicked)

        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        for view in [recentsButton] + categoryButtons + [toneButton] { stack.addArrangedSubview(view) }
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The keyboard stops as the bar is now (🕘 only when shown, categories only when enabled).
    var navigator: CategoryBarNavigator {
        CategoryBarNavigator(showsRecents: !recentsButton.isHidden, categoriesEnabled: categoriesEnabled)
    }

    func setRecentsVisible(_ visible: Bool) {
        guard recentsButton.isHidden == visible else { return }
        recentsButton.isHidden = !visible
        needsDisplay = true // the buttons shift, and the focus highlight with them
    }

    func setCategoriesEnabled(_ enabled: Bool) {
        categoriesEnabled = enabled
        for button in [recentsButton] + categoryButtons {
            button.isEnabled = enabled
            button.alphaValue = enabled ? 1 : 0.35 // colour emoji don't dim on their own
        }
    }

    func setTone(_ tone: SkinTone) { toneButton.title = tone.hand }

    /// The tone button's frame in this view's coordinates, for placing the swatches above it.
    var toneButtonFrame: NSRect {
        stack.layoutSubtreeIfNeeded()
        return convert(toneButton.frame, from: stack)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if let focusedSlot {
            Self.drawFocus(around: convert(button(for: focusedSlot).frame, from: stack).insetBy(dx: 1, dy: 3))
        }
    }

    override func layout() {
        super.layout()
        if focusedSlot != nil { needsDisplay = true }
    }

    private func button(for slot: CategoryBarSlot) -> NSButton {
        switch slot {
        case .recents: recentsButton
        case .category(let category): categoryButtons[EmojiCategory.allCases.firstIndex(of: category) ?? 0]
        case .tone: toneButton
        }
    }

    /// Keyboard focus highlight: an accent-tinted rounded box with an accent outline, visible in
    /// light and dark mode. Drawn behind the (borderless, transparent) button.
    private static func drawFocus(around rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    @objc private func recentsClicked() { onSelect?(.recents) }
    @objc private func categoryClicked(_ sender: NSButton) { onSelect?(.category(EmojiCategory.allCases[sender.tag])) }
    @objc private func toneClicked() { onToneButton?() }

    fileprivate static func makeButton(_ title: String, tip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 16)
        button.refusesFirstResponder = true // typing must stay in the search field
        button.focusRingType = .none
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }
}

/// The skin-tone choices: a small box of six hands shown above the tone button. Drawn inside the
/// panel rather than as an NSPopover, whose own window could take key status and close the panel.
final class ToneSwatches: NSView {
    static let size = NSSize(width: 6 * 34 + 8, height: 40)

    var onPick: ((SkinTone) -> Void)?
    var selected: SkinTone = .none { didSet { needsDisplay = true } }
    /// The keyboard-focused swatch, or nil when the swatches were opened with the mouse.
    var focused: SkinTone? { didSet { if focused != oldValue { needsDisplay = true } } }
    private var buttons: [NSButton] = []

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        for (i, tone) in SkinTone.allCases.enumerated() {
            let button = CategoryBar.makeButton(tone.hand, tip: tone.title)
            button.font = .systemFont(ofSize: 20)
            button.frame = NSRect(x: 4 + CGFloat(i) * 34, y: 3, width: 34, height: 34)
            button.tag = tone.rawValue
            button.target = self
            button.action = #selector(picked(_:))
            addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func picked(_ sender: NSButton) {
        onPick?(SkinTone(rawValue: sender.tag) ?? .none)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        if let button = buttons.first(where: { $0.tag == selected.rawValue }) {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: button.frame.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        if let focused, let button = buttons.first(where: { $0.tag == focused.rawValue }) {
            let path = NSBezierPath(roundedRect: button.frame.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}
