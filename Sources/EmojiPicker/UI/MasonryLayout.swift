import AppKit
import PickerCore

/// Pure two-column masonry maths, in flipped coordinates (y grows downward). Each item goes in
/// the shorter column; its height follows the aspect ratio of its preview size.
struct MasonryGeometry {
    struct Section {
        var hasHeader: Bool
        var sizes: [CGSize]
    }

    var width: CGFloat
    var inset: CGFloat = 8
    var spacing: CGFloat = 6
    var headerHeight: CGFloat = 24
    var sectionGap: CGFloat = 6

    private(set) var items: [[CGRect]] = []
    private(set) var headers: [CGRect?] = []
    private(set) var contentHeight: CGFloat = 0

    var columnWidth: CGFloat { max(1, floor((width - 2 * inset - spacing) / 2)) }

    init(width: CGFloat, sections: [Section]) {
        self.width = width
        compute(sections)
    }

    private mutating func compute(_ sections: [Section]) {
        let colWidth = columnWidth
        var y: CGFloat = 4
        items = []
        headers = []
        for section in sections {
            guard !section.sizes.isEmpty else {
                items.append([])
                headers.append(nil)
                continue
            }
            if section.hasHeader {
                headers.append(CGRect(x: 0, y: y, width: width, height: headerHeight))
                y += headerHeight
            } else {
                headers.append(nil)
            }
            var columnY: [CGFloat] = [y, y]
            var rects: [CGRect] = []
            for size in section.sizes {
                let column = columnY[0] <= columnY[1] ? 0 : 1
                let height = Self.itemHeight(for: size, columnWidth: colWidth)
                rects.append(CGRect(
                    x: inset + CGFloat(column) * (colWidth + spacing), y: columnY[column],
                    width: colWidth, height: height))
                columnY[column] += height + spacing
            }
            items.append(rects)
            y = columnY.max()! - spacing + sectionGap
        }
        contentHeight = y + 4
    }

    static func itemHeight(for size: CGSize, columnWidth: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return round(columnWidth * 0.75) }
        let natural = columnWidth * size.height / size.width
        return round(min(max(natural, columnWidth * 0.4), columnWidth * 2))
    }

    private func column(of rect: CGRect) -> Int { rect.midX < width / 2 ? 0 : 1 }

    /// The item an arrow key moves to: up/down stay in the column (crossing sections), left/right
    /// switch column to the item that best overlaps vertically. `nil` at an edge.
    func neighbour(of path: IndexPath, _ direction: Direction) -> IndexPath? {
        guard items.indices.contains(path.section), items[path.section].indices.contains(path.item) else { return nil }
        let current = items[path.section][path.item]
        let col = column(of: current)
        var all: [(path: IndexPath, rect: CGRect)] = []
        for (s, rects) in items.enumerated() {
            for (i, rect) in rects.enumerated() { all.append((IndexPath(item: i, section: s), rect)) }
        }
        switch direction {
        case .up:
            return all.filter { column(of: $0.rect) == col && $0.rect.minY < current.minY }
                .max { $0.rect.minY < $1.rect.minY }?.path
        case .down:
            return all.filter { column(of: $0.rect) == col && $0.rect.minY > current.minY }
                .min { $0.rect.minY < $1.rect.minY }?.path
        case .left, .right:
            let target = direction == .left ? 0 : 1
            guard target != col else { return nil }
            let candidates = all.filter { column(of: $0.rect) == target }
            if let containing = candidates.first(where: { $0.rect.minY <= current.midY && current.midY < $0.rect.maxY }) {
                return containing.path
            }
            return candidates.min { abs($0.rect.midY - current.midY) < abs($1.rect.midY - current.midY) }?.path
        }
    }
}

@MainActor
protocol MasonryLayoutDataSource: AnyObject {
    /// One entry per collection-view section: whether it shows a header, and each item's preview size.
    func masonrySections() -> [MasonryGeometry.Section]
}

/// `NSCollectionViewLayout` over `MasonryGeometry`, with optional section headers.
final class MasonryLayout: NSCollectionViewLayout {
    weak var dataSource: MasonryLayoutDataSource?
    private(set) var geometry = MasonryGeometry(width: 0, sections: [])

    override func prepare() {
        super.prepare()
        let width = collectionView?.bounds.width ?? 0
        geometry = MasonryGeometry(width: width, sections: dataSource?.masonrySections() ?? [])
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.width, height: geometry.contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != geometry.width
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        for (s, header) in geometry.headers.enumerated() {
            if let header, header.intersects(rect),
               let a = layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: s)) {
                result.append(a)
            }
        }
        for (s, rects) in geometry.items.enumerated() {
            for (i, frame) in rects.enumerated() where frame.intersects(rect) {
                let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: s))
                a.frame = frame
                result.append(a)
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard geometry.items.indices.contains(indexPath.section),
              geometry.items[indexPath.section].indices.contains(indexPath.item) else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        a.frame = geometry.items[indexPath.section][indexPath.item]
        return a
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader,
              geometry.headers.indices.contains(indexPath.section),
              let frame = geometry.headers[indexPath.section] else { return nil }
        let a = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: elementKind, with: IndexPath(item: 0, section: indexPath.section))
        a.frame = frame
        return a
    }
}
