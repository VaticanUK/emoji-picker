import AppKit
import PickerCore

/// Keys the search field offers to the picker before editing its own text.
enum SearchCommand: Equatable {
    case move(Direction)
    case activate
    case space
    /// Tab / Shift-Tab: the next or previous focus zone.
    case nextZone
    case previousZone
    /// ⌃Tab / ⌃⇧Tab: the next or previous top tab.
    case nextTab
    case previousTab
    case cancel
    /// Backspace or another delete key.
    case delete
}

/// The picker's search field. It keeps focus the whole time the picker is open: typing edits the
/// query, and keys are offered to the picker through `onCommand` first. When that returns true the
/// key is used up; otherwise the field handles it as usual (e.g. ←/→ move the text cursor).
final class SearchField: NSSearchField, NSSearchFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onCommand: ((SearchCommand) -> Bool)?
    private var reported = ""

    override class var cellClass: AnyClass? {
        get { SearchFieldCell.self }
        set {}
    }

    init() {
        super.init(frame: .zero)
        (cell as? SearchFieldCell)?.editor.onSpace = { [weak self] in self?.onCommand?(.space) ?? false }
        delegate = self
        target = self
        action = #selector(searchAction) // fires when the clear (x) button empties the field
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
        maximumRecents = 0
        controlSize = .large
        font = .systemFont(ofSize: 13)
        placeholderString = "Search"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Programmatic clear; does not call `onTextChange`.
    func clear() {
        stringValue = ""
        reported = ""
        window?.undoManager?.removeAllActions() // ⌘Z mustn't bring back the last session's query
    }

    /// Programmatic set that behaves like typing: calls `onTextChange` and keeps the cursor at the end.
    func setText(_ text: String) {
        stringValue = text
        currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        report()
    }

    func controlTextDidChange(_ obj: Notification) { report() }

    @objc private func searchAction() { report() }

    /// Typing triggers both the delegate and the action; report each new value once.
    private func report() {
        guard stringValue != reported else { return }
        reported = stringValue
        onTextChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let command: SearchCommand
        switch selector {
        case #selector(NSResponder.moveUp(_:)): command = .move(.up)
        case #selector(NSResponder.moveDown(_:)): command = .move(.down)
        case #selector(NSResponder.moveLeft(_:)): command = .move(.left)
        case #selector(NSResponder.moveRight(_:)): command = .move(.right)
        case #selector(NSResponder.insertNewline(_:)): command = .activate
        case #selector(NSResponder.insertTab(_:)): command = .nextZone
        case #selector(NSResponder.insertBacktab(_:)): command = .previousZone
        // The standard key bindings map ⌃Tab and ⌃⇧Tab to these.
        case #selector(NSWindow.selectNextKeyView(_:)): command = .nextTab
        case #selector(NSWindow.selectPreviousKeyView(_:)): command = .previousTab
        case #selector(NSResponder.cancelOperation(_:)): command = .cancel
        default:
            guard NSStringFromSelector(selector).hasPrefix("delete") else { return false }
            command = .delete
        }
        return onCommand?(command) ?? false
    }
}

/// Gives the search field its own field editor, so a typed Space can be offered to the picker
/// (it presses the focused category-bar button) before it's inserted. Space arrives as text, not
/// as a command, so `doCommandBy` never sees it.
private final class SearchFieldCell: NSSearchFieldCell {
    let editor = SearchFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// A plain-text, single-line field editor with the stock one's defaults (no smart substitutions,
/// spelling or link detection). The app has no Edit menu, so it handles the editing shortcuts
/// (⌘A ⌘C ⌘X ⌘V ⌘Z ⇧⌘Z) itself.
final class SearchFieldEditor: NSTextView {
    /// Returns true when the picker used the Space.
    var onSpace: (() -> Bool)?

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        isFieldEditor = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if (string as? String) == " ", !hasMarkedText(), onSpace?() == true { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "a"): selectAll(nil)
        case ([.command], "c"): copy(nil)
        case ([.command], "x"): cut(nil)
        case ([.command], "v"): paste(nil)
        case ([.command], "z"): undoManager?.undo()
        case ([.command, .shift], "z"): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func paste(_ sender: Any?) { pastePlainText(from: .general) }

    /// Inserts the pasteboard's text only (never styles or images), on one line, as typing does
    /// (so it can be undone and updates the query).
    func pastePlainText(from pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        super.insertText(line, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
