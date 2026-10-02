import Foundation

/// Plan-polygon helpers shared by drafting and IFC export.
public enum PlanPolygon {
    /// Unsigned area in mm².
    public static func area(_ polygon: [Point2D]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            sum += polygon[index].x * next.y - next.x * polygon[index].y
        }
        return abs(sum) * 0.5
    }

    public static func centroid(_ polygon: [Point2D]) -> Point2D? {
        guard polygon.count >= 3 else { return nil }
        var crossSum = 0.0
        var cx = 0.0
        var cy = 0.0
        for index in polygon.indices {
            let p = polygon[index]
            let q = polygon[(index + 1) % polygon.count]
            let cross = p.x * q.y - q.x * p.y
            crossSum += cross
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
        }
        guard abs(crossSum) > 1e-9 else {
            return polygon.reduce(.zero, +) * (1 / Double(polygon.count))
        }
        let factor = 1 / (3 * crossSum)
        return Point2D(x: cx * factor, y: cy * factor)
    }

    public static func contains(_ point: Point2D, in polygon: [Point2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let crosses = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) == 0 ? 1e-12 : (pj.y - pi.y)) + pi.x)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// v12.1 interior and exterior wall-face boundaries of a closed room, derived from its centreline loop.
///
/// Each loop edge is matched one-to-one to the semantic wall it represents, then offset by half that
/// wall's thickness; adjacent offset lines are mitred. The DXF drafting model and the IFC space body
/// share this single construction, so the drawn A-SPACE area and the IfcSpace area always agree.
/// Returns nil (never an invented boundary) when the loop cannot be matched to walls.
public struct RoomFaceBoundary: Sendable {
    public struct Edge: Sendable {
        public var wall: PlanOpsisWall
        /// Centreline start/end of this loop edge.
        public var a: Point2D
        public var b: Point2D
        public var direction: Point2D
        /// Unit normal pointing into the room.
        public var inward: Point2D
    }

    public var centerline: [Point2D]
    /// Clear interior (room-side faces); vertex i is the corner at the start of edge i.
    public var inner: [Point2D]
    /// Exterior faces; vertex i is the corner at the start of edge i.
    public var outer: [Point2D]
    public var edges: [Edge]

    /// Clear floor area in mm².
    public var netArea: Double { PlanPolygon.area(inner) }

    public init?(room: PlanOpsisRoom, centerline: [Point2D]) {
        guard centerline.count >= 3, room.walls.count >= 3 else { return nil }

        var usedWallIDs = Set<UUID>()
        var base: [Edge] = []
        base.reserveCapacity(centerline.count)

        for index in centerline.indices {
            let a = centerline[index]
            let b = centerline[(index + 1) % centerline.count]
            let vector = b - a
            let length = vector.length
            guard length > 1e-6 else { return nil }
            let direction = vector * (1 / length)
            let midpoint = (a + b) * 0.5

            // Prefer a one-to-one edge/wall mapping. RoomPlan can contain small endpoint noise,
            // so matching combines parallelism, perpendicular distance, length and endpoint fit.
            let candidates = room.walls.compactMap { wall -> (PlanOpsisWall, Double)? in
                let parallel = abs(direction.dot(wall.direction))
                guard parallel >= 0.965 else { return nil }
                let normal = Point2D(x: -wall.direction.y, y: wall.direction.x)
                let lineDistance = abs((midpoint - wall.start).dot(normal))
                let lengthPenalty = abs(wall.length - length) * 0.08
                let direct = (wall.start - a).length + (wall.end - b).length
                let reversed = (wall.end - a).length + (wall.start - b).length
                let endpointPenalty = min(direct, reversed) * 0.04
                let reusePenalty = usedWallIDs.contains(wall.id) ? 10_000.0 : 0.0
                return (wall, lineDistance + lengthPenalty + endpointPenalty + reusePenalty)
            }.sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id.uuidString < rhs.0.id.uuidString }
                return lhs.1 < rhs.1
            }

            guard let bestCandidate = candidates.first, bestCandidate.1 < 10_000 else { return nil }
            let wall = bestCandidate.0
            usedWallIDs.insert(wall.id)

            let left = Point2D(x: -direction.y, y: direction.x)
            let probe = max(20.0, min(100.0, wall.thickness * 0.4))
            let plusInside = PlanPolygon.contains(midpoint + left * probe, in: centerline)
            let minusInside = PlanPolygon.contains(midpoint - left * probe, in: centerline)
            let inward: Point2D
            if plusInside != minusInside {
                inward = plusInside ? left : left * -1
            } else if let centroid = PlanPolygon.centroid(centerline) {
                inward = (centroid - midpoint).dot(left) >= 0 ? left : left * -1
            } else {
                inward = left
            }

            base.append(Edge(wall: wall, a: a, b: b, direction: direction, inward: inward))
        }

        func lineIntersection(
            pointA: Point2D, directionA: Point2D,
            pointB: Point2D, directionB: Point2D,
            fallback: Point2D,
            maxDistance: Double
        ) -> Point2D {
            let cross = directionA.x * directionB.y - directionA.y * directionB.x
            guard abs(cross) > 1e-8 else { return fallback }
            let delta = pointB - pointA
            let t = (delta.x * directionB.y - delta.y * directionB.x) / cross
            let point = pointA + directionA * t
            guard point.x.isFinite, point.y.isFinite, (point - fallback).length <= maxDistance else { return fallback }
            return point
        }

        var innerVertices: [Point2D] = []
        var outerVertices: [Point2D] = []
        innerVertices.reserveCapacity(base.count)
        outerVertices.reserveCapacity(base.count)

        for index in base.indices {
            let previous = base[(index - 1 + base.count) % base.count]
            let current = base[index]
            let vertex = current.a
            let prevHalf = previous.wall.thickness * 0.5
            let curHalf = current.wall.thickness * 0.5
            let maxMiter = max(600.0, max(prevHalf, curHalf) * 6)

            let prevInnerPoint = previous.a + previous.inward * prevHalf
            let curInnerPoint = current.a + current.inward * curHalf
            let innerFallback = vertex + (previous.inward * prevHalf + current.inward * curHalf) * 0.5
            innerVertices.append(lineIntersection(
                pointA: prevInnerPoint, directionA: previous.direction,
                pointB: curInnerPoint, directionB: current.direction,
                fallback: innerFallback,
                maxDistance: maxMiter
            ))

            let prevOuterPoint = previous.a - previous.inward * prevHalf
            let curOuterPoint = current.a - current.inward * curHalf
            let outerFallback = vertex - (previous.inward * prevHalf + current.inward * curHalf) * 0.5
            outerVertices.append(lineIntersection(
                pointA: prevOuterPoint, directionA: previous.direction,
                pointB: curOuterPoint, directionB: current.direction,
                fallback: outerFallback,
                maxDistance: maxMiter
            ))
        }

        guard PlanPolygon.area(innerVertices) > 1, PlanPolygon.area(outerVertices) > PlanPolygon.area(innerVertices) else { return nil }
        self.centerline = centerline
        self.inner = innerVertices
        self.outer = outerVertices
        self.edges = base
    }
}
