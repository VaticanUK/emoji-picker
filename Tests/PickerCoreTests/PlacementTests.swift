import CoreGraphics
import Testing
@testable import PickerCore

@Suite struct PlacementTests {
    let size = CGSize(width: 360, height: 420)
    let one = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    let mouse = CGPoint(x: 700, y: 600)

    @Test func belowCaret() {
        let f = Placement.frame(panelSize: size, caret: CGRect(x: 500, y: 500, width: 2, height: 18), mouse: mouse, screens: one)
        #expect(f.origin == CGPoint(x: 500, y: 500 - 420 - 4))
        #expect(f.size == size)
    }

    @Test func flipsAboveWhenNoRoomBelow() {
        let caret = CGRect(x: 500, y: 100, width: 2, height: 18)
        let f = Placement.frame(panelSize: size, caret: caret, mouse: mouse, screens: one)
        #expect(f.minY == caret.maxY + 4)
    }

    @Test func clampsRightEdge() {
        let f = Placement.frame(panelSize: size, caret: CGRect(x: 1400, y: 500, width: 2, height: 18), mouse: mouse, screens: one)
        #expect(f.maxX <= 1440)
    }

    @Test func ignoresZeroCaret() {
        let f = Placement.frame(panelSize: size, caret: .zero, mouse: mouse, screens: one)
        #expect(f.origin == CGPoint(x: mouse.x, y: mouse.y - 420 - 4))
    }

    @Test func ignoresOffscreenCaret() {
        let f = Placement.frame(panelSize: size, caret: CGRect(x: -5000, y: -5000, width: 2, height: 18), mouse: mouse, screens: one)
        #expect(f.origin == CGPoint(x: mouse.x, y: mouse.y - 420 - 4))
    }

    @Test func usesScreenContainingAnchor() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let f = Placement.frame(panelSize: size, caret: nil, mouse: CGPoint(x: 2000, y: 500), screens: [one[0], second])
        #expect(second.contains(f))
    }

    @Test func clampsAtScreenLeftAndTop() {
        let f = Placement.frame(panelSize: size, caret: CGRect(x: 10, y: 895, width: 2, height: 18), mouse: mouse, screens: one)
        #expect(one[0].contains(f))
    }

    @Test func ignoresFlippedEmptyAXCaretWithScreenAbovePrimary() {
        // An empty AX rect after the top-left -> Cocoa flip becomes (0, primaryHeight, 0, 0).
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let f = Placement.frame(panelSize: size, caret: CGRect(x: 0, y: 900, width: 0, height: 0), mouse: mouse, screens: [one[0], above])
        #expect(f.origin == CGPoint(x: mouse.x, y: mouse.y - 420 - 4))
    }
}
