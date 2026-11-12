import Testing
@testable import PickerCore

@Suite struct GridNavigatorTests {
    let nav = GridNavigator(sectionCounts: [9, 20], columns: 9)

    @Test func gridWrapsAcrossSections() {
        #expect(nav.move(GridIndex(section: 0, item: 8), .right) == GridIndex(section: 1, item: 0))
        #expect(nav.move(GridIndex(section: 0, item: 3), .down) == GridIndex(section: 1, item: 3))
        #expect(nav.move(GridIndex(section: 1, item: 18), .down) == GridIndex(section: 1, item: 18))
        #expect(nav.move(GridIndex(section: 0, item: 0), .left) == GridIndex(section: 0, item: 0))
        #expect(nav.move(GridIndex(section: 1, item: 2), .up) == GridIndex(section: 0, item: 2))
    }

    @Test func leftWrapsToPreviousSectionEnd() {
        #expect(nav.move(GridIndex(section: 1, item: 0), .left) == GridIndex(section: 0, item: 8))
    }

    @Test func upIntoShortLastRowClamps() {
        let n = GridNavigator(sectionCounts: [11, 20], columns: 9)
        #expect(n.move(GridIndex(section: 1, item: 8), .up) == GridIndex(section: 0, item: 10))
    }

    @Test func skipsEmptySections() {
        let n = GridNavigator(sectionCounts: [3, 0, 3], columns: 9)
        #expect(n.move(GridIndex(section: 0, item: 2), .right) == GridIndex(section: 2, item: 0))
    }
}
