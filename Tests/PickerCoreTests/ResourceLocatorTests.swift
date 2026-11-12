import Testing
@testable import PickerCore

@Test func findsBundledFile() {
    #expect(ResourceLocator.url("kaomoji", ext: "json") != nil)
}
