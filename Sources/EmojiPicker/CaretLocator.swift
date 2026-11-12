import ApplicationServices
import AppKit

/// Finds the text caret of the focused UI element via Accessibility.
enum CaretLocator {
    /// Caret rect in Cocoa global coordinates (y up), or nil when unavailable.
    /// The rect may still be bogus (zero, offscreen); `Placement` validates it.
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // A hung target app must not blow the open-time budget.
        AXUIElementSetMessagingTimeout(system, 0.1)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }

        // Electron apps often report an empty rect; reject before the flip makes it non-zero.
        guard rect.width != 0 || rect.height != 0 else { return nil }

        // AX uses a top-left origin on the primary screen; Cocoa is bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        rect.origin.y = primaryHeight - rect.origin.y - rect.height
        return rect
    }
}
