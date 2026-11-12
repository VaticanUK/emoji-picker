import Foundation

public struct GridIndex: Equatable, Sendable {
    public var section: Int
    public var item: Int
    public init(section: Int, item: Int) { self.section = section; self.item = item }
}

public enum Direction: Sendable { case up, down, left, right }

/// Arrow-key maths over a grid made of sections, each laid out in rows of `columns`.
/// Left/right run continuously across sections; up/down keep the column and carry on into the
/// neighbouring section. At the grid edges the index does not move.
public struct GridNavigator: Sendable {
    public let sectionCounts: [Int]
    public let columns: Int

    public init(sectionCounts: [Int], columns: Int) {
        self.sectionCounts = sectionCounts
        self.columns = max(1, columns)
    }

    public func move(_ from: GridIndex, _ dir: Direction) -> GridIndex {
        guard sectionCounts.indices.contains(from.section),
              from.item >= 0, from.item < sectionCounts[from.section] else { return from }
        let count = sectionCounts[from.section]
        let col = from.item % columns
        switch dir {
        case .right:
            if from.item + 1 < count { return GridIndex(section: from.section, item: from.item + 1) }
            if let s = nextSection(after: from.section) { return GridIndex(section: s, item: 0) }
        case .left:
            if from.item > 0 { return GridIndex(section: from.section, item: from.item - 1) }
            if let s = previousSection(before: from.section) {
                return GridIndex(section: s, item: sectionCounts[s] - 1)
            }
        case .down:
            if from.item + columns < count {
                return GridIndex(section: from.section, item: from.item + columns)
            }
            let lastRowStart = ((count - 1) / columns) * columns
            if from.item < lastRowStart {
                // A short last row sits below but has no cell in this column: land on its end.
                return GridIndex(section: from.section, item: count - 1)
            }
            if let s = nextSection(after: from.section) {
                return GridIndex(section: s, item: min(col, sectionCounts[s] - 1))
            }
        case .up:
            if from.item - columns >= 0 { return GridIndex(section: from.section, item: from.item - columns) }
            if let s = previousSection(before: from.section) {
                let n = sectionCounts[s]
                return GridIndex(section: s, item: min(((n - 1) / columns) * columns + col, n - 1))
            }
        }
        return from
    }

    private func nextSection(after s: Int) -> Int? {
        sectionCounts.indices.first { $0 > s && sectionCounts[$0] > 0 }
    }

    private func previousSection(before s: Int) -> Int? {
        sectionCounts.indices.last { $0 < s && sectionCounts[$0] > 0 }
    }
}
