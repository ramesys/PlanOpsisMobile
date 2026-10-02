import Foundation

/// v12.3 measuring on drawings: distances, chains and areas, formatted in the drawing's units.
public enum CADMeasurement {
    public static func distance(_ a: Point2D, _ b: Point2D) -> Double { (b - a).length }

    /// Angle of `a → b` from the +X axis, degrees in [0, 360).
    public static func angleDegrees(_ a: Point2D, _ b: Point2D) -> Double {
        var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        if angle < 0 { angle += 360 }
        return angle
    }

    public static func chainLength(_ points: [Point2D], closed: Bool = false) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = zip(points, points.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
        if closed, let first = points.first, let last = points.last { total += (first - last).length }
        return total
    }

    /// Unsigned shoelace area of a simple polygon.
    public static func area(_ points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Even-odd point-in-polygon over several loops.
    public static func contains(_ p: Point2D, loops: [[Point2D]]) -> Bool {
        var inside = false
        for loop in loops where loop.count >= 3 {
            var j = loop.count - 1
            for i in 0..<loop.count {
                let a = loop[i], b = loop[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
        }
        return inside
    }

    /// "3450 mm", "3.450 m", "12.50 in"; unitless drawings show plain numbers.
    public static func formatLength(_ value: Double, units: CADUnits) -> String {
        switch units {
        case .millimetres:
            return abs(value) < 10 ? String(format: "%.1f mm", value) : String(format: "%.0f mm", value)
        case .metres:
            return String(format: "%.3f m", value)
        case .centimetres:
            return String(format: "%.1f cm", value)
        case .inches, .feet:
            return String(format: "%.2f", value) + " " + units.symbol
        case .unitless, .other:
            return abs(value) >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
        }
    }

    /// Areas in square metres when the unit is known, else in square drawing units.
    public static func formatArea(_ value: Double, units: CADUnits) -> String {
        if let mm = units.millimetresPerUnit {
            return String(format: "%.2f m²", value * mm * mm / 1_000_000)
        }
        return String(format: "%.2f units²", value)
    }

    public static func formatAngle(_ degrees: Double) -> String {
        String(format: "%.1f°", degrees)
    }
}
