import Testing
@testable import PickerCore

@Suite struct CategoryBarNavigatorTests {
    let withRecents = CategoryBarNavigator(showsRecents: true, categoriesEnabled: true)
    let noRecents = CategoryBarNavigator(showsRecents: false, categoriesEnabled: true)

    @Test func slotsRunRecentsCategoriesThenTone() {
        #expect(withRecents.slots.count == 11)
        #expect(withRecents.slots.first == .recents)
        #expect(withRecents.slots[1] == .category(.smileys))
        #expect(withRecents.slots.last == .tone)
        #expect(noRecents.slots.count == 10)
        #expect(noRecents.slots.first == .category(.smileys))
    }

    @Test func leftAndRightStep() {
        #expect(withRecents.move(.recents, .right) == .category(.smileys))
        #expect(withRecents.move(.category(.smileys), .left) == .recents)
        #expect(noRecents.move(.category(.objects), .right) == .category(.symbols))
        #expect(noRecents.move(.category(.flags), .right) == .tone)
        #expect(noRecents.move(.tone, .left) == .category(.flags))
    }

    @Test func endsDoNotWrap() {
        #expect(withRecents.move(.recents, .left) == .recents)
        #expect(withRecents.move(.tone, .right) == .tone)
        #expect(noRecents.move(.category(.smileys), .left) == .category(.smileys))
    }

    @Test func upAndDownDoNotMove() {
        #expect(withRecents.move(.category(.food), .up) == .category(.food))
        #expect(withRecents.move(.category(.food), .down) == .category(.food))
    }

    @Test func hiddenRecentsIsNotASlot() {
        // A stale 🕘 slot (recents hidden since) lands on the first category.
        #expect(noRecents.valid(.recents) == .category(.smileys))
        #expect(noRecents.move(.recents, .right) == .category(.people))
    }

    @Test func disabledCategoriesLeaveOnlyTone() {
        let searching = CategoryBarNavigator(showsRecents: false, categoriesEnabled: false)
        #expect(searching.slots == [.tone])
        #expect(searching.valid(.category(.food)) == .tone)
        #expect(searching.move(.tone, .left) == .tone)
    }

    @Test func swatchesStepWithoutWrapping() {
        #expect(SkinTone.none.moved(.right) == .light)
        #expect(SkinTone.light.moved(.left) == SkinTone.none)
        #expect(SkinTone.none.moved(.left) == SkinTone.none)
        #expect(SkinTone.dark.moved(.right) == .dark)
        #expect(SkinTone.medium.moved(.up) == .medium)
    }
}
