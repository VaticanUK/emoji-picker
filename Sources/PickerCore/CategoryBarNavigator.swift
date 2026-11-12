import Foundation

/// A keyboard stop in the emoji tab's category bar.
public enum CategoryBarSlot: Sendable, Equatable {
    case recents
    case category(EmojiCategory)
    case tone
}

/// Left/right movement along the category bar: 🕘 (only when shown), the categories (only when
/// enabled, i.e. not while searching), then the skin-tone button. The ends don't wrap.
public struct CategoryBarNavigator: Sendable {
    public let slots: [CategoryBarSlot]

    public init(showsRecents: Bool, categoriesEnabled: Bool) {
        var slots: [CategoryBarSlot] = []
        if showsRecents && categoriesEnabled { slots.append(.recents) }
        if categoriesEnabled { slots += EmojiCategory.allCases.map(CategoryBarSlot.category) }
        slots.append(.tone)
        self.slots = slots
    }

    /// `slot` if it's currently a stop, otherwise the nearest one that is.
    public func valid(_ slot: CategoryBarSlot) -> CategoryBarSlot {
        if slots.contains(slot) { return slot }
        return slots.first { if case .category = $0 { true } else { false } } ?? .tone
    }

    public func move(_ slot: CategoryBarSlot, _ direction: Direction) -> CategoryBarSlot {
        let current = valid(slot)
        guard let i = slots.firstIndex(of: current) else { return current }
        switch direction {
        case .left: return slots[max(i - 1, 0)]
        case .right: return slots[min(i + 1, slots.count - 1)]
        case .up, .down: return current
        }
    }
}

extension SkinTone {
    /// Left/right through the skin-tone swatches, in display order. The ends don't wrap.
    public func moved(_ direction: Direction) -> SkinTone {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self) else { return self }
        switch direction {
        case .left: return all[max(i - 1, 0)]
        case .right: return all[min(i + 1, all.count - 1)]
        case .up, .down: return self
        }
    }
}
