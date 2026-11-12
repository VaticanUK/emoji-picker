import Carbon.HIToolbox
import Foundation
import Testing
@testable import PickerCore

@Suite struct ShortcutTests {
    @Test func defaultIsOptionPeriod() {
        #expect(Shortcut.default == Shortcut(keyCode: 47, modifiers: UInt32(optionKey)))
    }

    @Test func defaultDisplayString() {
        #expect(Shortcut.default.displayString == "⌥.")
    }

    @Test func defaultIsOptionOnly() {
        #expect(Shortcut.default.isOptionOnly)
    }

    @Test func optionPlusControlIsNotOptionOnly() {
        #expect(!Shortcut(keyCode: 47, modifiers: UInt32(optionKey | controlKey)).isOptionOnly)
    }

    @Test func displayStringOrdersModifiers() {
        let s = Shortcut(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(s.displayString == "⌃⌥⇧⌘Space")
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Shortcut.default)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == Shortcut.default)
    }
}

@Suite struct ShortcutValidationTests {
    @Test func rejectsNoModifierAndShiftOnly() {
        #expect(Shortcut(keyCode: 14, modifiers: 0).validationError != nil)
        #expect(Shortcut(keyCode: 14, modifiers: UInt32(shiftKey)).validationError != nil)
    }

    @Test func acceptsRealModifiers() {
        #expect(Shortcut.default.validationError == nil)
        #expect(Shortcut(keyCode: 14, modifiers: UInt32(controlKey | optionKey)).validationError == nil)
        #expect(Shortcut(keyCode: 14, modifiers: UInt32(cmdKey | shiftKey)).validationError == nil)
    }
}
