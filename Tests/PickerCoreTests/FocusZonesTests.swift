import Testing
@testable import PickerCore

@Suite struct FocusZonesTests {
    let emoji = ZoneCycle(zones: [.search, .content, .categoryBar])
    let plain = ZoneCycle(zones: [.search, .content])

    @Test func nextCyclesForwardAndWraps() {
        #expect(emoji.next(after: .search) == .content)
        #expect(emoji.next(after: .content) == .categoryBar)
        #expect(emoji.next(after: .categoryBar) == .search)
        #expect(plain.next(after: .content) == .search)
    }

    @Test func previousCyclesBackAndWraps() {
        #expect(emoji.previous(before: .search) == .categoryBar)
        #expect(emoji.previous(before: .categoryBar) == .content)
        #expect(plain.previous(before: .search) == .content)
        #expect(plain.previous(before: .content) == .search)
    }

    @Test func unknownZoneFallsBackToFirst() {
        #expect(plain.next(after: .categoryBar) == .search)
        #expect(plain.previous(before: .categoryBar) == .search)
    }

    @Test func emptyCycleStaysInSearch() {
        let none = ZoneCycle(zones: [])
        #expect(none.next(after: .content) == .search)
        #expect(none.previous(before: .content) == .search)
    }
}
