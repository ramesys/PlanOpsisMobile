import Foundation

/// Uniform-grid index over scene item bounds, for viewport culling, picking and snapping.
/// Items that would span more than 64 cells are kept in a short list that every query checks.
public struct CADSpatialIndex: Sendable {
    private let bounds: CADRect
    private let columns: Int
    private let rows: Int
    private let cellWidth: Double
    private let cellHeight: Double
    private let cells: [[Int32]]
    private let large: [Int32]
    private let itemBounds: [CADRect]

    public init(items: [CADSceneItem], bounds: CADRect) {
        self.bounds = bounds
        itemBounds = items.map(\.bounds)
        let side = max(1, min(256, Int(Double(items.count).squareRoot().rounded(.up))))
        let width = max(bounds.width, 1e-9), height = max(bounds.height, 1e-9)
        // Keep cells roughly square.
        let aspect = width / height
        columns = max(1, min(256, Int((Double(side) * aspect.squareRoot()).rounded())))
        rows = max(1, min(256, Int((Double(side) / aspect.squareRoot()).rounded())))
        cellWidth = width / Double(columns)
        cellHeight = height / Double(rows)
        var cells = Array(repeating: [Int32](), count: bounds.isEmpty ? 0 : columns * rows)
        var large: [Int32] = []
        if !bounds.isEmpty {
            for (i, item) in items.enumerated() {
                let r = Self.cellRange(item.bounds, bounds: bounds, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
                if r.columns.count * r.rows.count > 64 { large.append(Int32(i)); continue }
                for row in r.rows { for column in r.columns { cells[row * columns + column].append(Int32(i)) } }
            }
        }
        self.cells = cells
        self.large = large
    }

    private static func cellRange(_ rect: CADRect, bounds: CADRect, columns: Int, rows: Int, cellWidth: Double, cellHeight: Double) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        func clamp(_ v: Int, _ hi: Int) -> Int { max(0, min(hi, v)) }
        let c0 = clamp(Int(((rect.minX - bounds.minX) / cellWidth).rounded(.down)), columns - 1)
        let c1 = clamp(Int(((rect.maxX - bounds.minX) / cellWidth).rounded(.down)), columns - 1)
        let r0 = clamp(Int(((rect.minY - bounds.minY) / cellHeight).rounded(.down)), rows - 1)
        let r1 = clamp(Int(((rect.maxY - bounds.minY) / cellHeight).rounded(.down)), rows - 1)
        return (c0...max(c0, c1), r0...max(r0, r1))
    }

    /// Indices of items whose bounds overlap `rect`, ascending (drawing order).
    public func query(_ rect: CADRect) -> [Int] {
        guard !bounds.isEmpty, rect.intersects(bounds) else { return [] }
        if rect.contains(bounds) { return Array(itemBounds.indices) }
        let r = Self.cellRange(rect, bounds: bounds, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        var found: [Int32] = large.filter { itemBounds[Int($0)].intersects(rect) }
        for row in r.rows {
            for column in r.columns {
                for i in cells[row * columns + column] where itemBounds[Int(i)].intersects(rect) { found.append(i) }
            }
        }
        found.sort()
        var result: [Int] = []
        result.reserveCapacity(found.count)
        var last: Int32 = -1
        for i in found where i != last { result.append(Int(i)); last = i }
        return result
    }
}
