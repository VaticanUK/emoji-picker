import AppKit
import PickerCore

/// A key the picker hands to the active tab for its focused zone.
enum ZoneKey: Equatable {
    case move(Direction)
    case activate
    /// Space: presses a category-bar button; in other zones it's typed into the search.
    case space
    case cancel
}

/// What the tab did with a `ZoneKey`.
enum ZoneResult: Equatable {
    case handled
    /// Not used here: the picker applies its default (the search field edits text, Esc closes).
    case ignored
    /// Move focus to this zone.
    case focus(PickerZone)
}

/// One tab's content. The picker owns the search field and the focused zone, and forwards the
/// query and keys here. The search field stays first responder throughout; zones are modelled here.
@MainActor
protocol PickerTabContent: AnyObject {
    var view: NSView { get }
    /// The tab's zones in Tab order. The first is always `.search`.
    var zones: [PickerZone] { get }
    /// Set by the picker. A tab calls it when the mouse moves focus (a click in the content, or
    /// on a category button, focuses the content).
    var onFocusRequest: ((PickerZone) -> Void)? { get set }
    func setQuery(_ q: String)
    func handle(_ key: ZoneKey, in zone: PickerZone) -> ZoneResult
    /// Focus moved to `zone`: update how the highlight and focus ring look.
    func focusChanged(to zone: PickerZone)
    /// The tab became visible (picker opened, or switched to): reset highlight and scroll.
    func didShow()
}

/// The shared search/content behaviour. In search, ↓ enters the content and Return activates the
/// highlight. In the content, the arrows move the highlight, and ↑ that can't move (top row)
/// returns to search. `move` reports whether the highlight moved.
@MainActor
func handleSearchOrContent(
    _ key: ZoneKey, in zone: PickerZone, move: (Direction) -> Bool, activate: () -> Void
) -> ZoneResult {
    switch (zone, key) {
    case (_, .activate):
        activate()
        return .handled
    case (.search, .move(.down)):
        return .focus(.content)
    case (.content, .move(let direction)):
        if !move(direction), direction == .up { return .focus(.search) }
        return .handled
    default:
        return .ignored
    }
}
