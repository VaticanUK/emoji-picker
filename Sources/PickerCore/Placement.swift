import CoreGraphics

/// Panel frame maths. All rects are in Cocoa global coordinates (y up).
public enum Placement {
    static let gap: CGFloat = 4

    /// `screens` are visible frames. A caret is used only when it has a non-zero size and
    /// its centre lies inside a screen; otherwise the panel anchors at the mouse.
    public static func frame(panelSize: CGSize, caret: CGRect?, mouse: CGPoint, screens: [CGRect]) -> CGRect {
        var anchor = CGRect(origin: mouse, size: CGSize(width: 1, height: 1))
        if let caret, !(caret.width == 0 && caret.height == 0), !caret.isNull, !caret.isInfinite,
           screens.contains(where: { $0.contains(CGPoint(x: caret.midX, y: caret.midY)) }) {
            anchor = caret
        }

        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = screens.first(where: { $0.contains(center) }) ?? nearest(to: center, in: screens) else {
            return CGRect(origin: CGPoint(x: anchor.minX, y: anchor.minY - gap - panelSize.height), size: panelSize)
        }

        var origin = CGPoint(x: anchor.minX, y: anchor.minY - gap - panelSize.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + gap }
        origin.x = min(origin.x, screen.maxX - panelSize.width)
        origin.y = min(origin.y, screen.maxY - panelSize.height)
        origin.x = max(origin.x, screen.minX)
        origin.y = max(origin.y, screen.minY)
        return CGRect(origin: origin, size: panelSize)
    }

    private static func nearest(to p: CGPoint, in screens: [CGRect]) -> CGRect? {
        screens.min { distance(p, $0) < distance(p, $1) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
