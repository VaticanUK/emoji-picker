import Foundation

/// An area of the picker that the arrow keys work inside. Tab and Shift-Tab move between them.
public enum PickerZone: Sendable, Equatable {
    case search
    /// The tab's grid or list.
    case content
    /// The emoji tab's bottom bar of category buttons and the skin-tone button.
    case categoryBar
}

/// Tab / Shift-Tab order over one tab's zones, wrapping at both ends.
public struct ZoneCycle: Sendable {
    public let zones: [PickerZone]

    public init(zones: [PickerZone]) { self.zones = zones }

    public func next(after zone: PickerZone) -> PickerZone { step(from: zone, by: 1) }

    public func previous(before zone: PickerZone) -> PickerZone { step(from: zone, by: -1) }

    private func step(from zone: PickerZone, by delta: Int) -> PickerZone {
        guard let i = zones.firstIndex(of: zone) else { return zones.first ?? .search }
        return zones[(i + delta + zones.count) % zones.count]
    }
}
