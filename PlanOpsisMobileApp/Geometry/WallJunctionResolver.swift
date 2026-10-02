import Foundation

/// Deterministic display-geometry resolver for room-local wall junctions.
///
/// Semantic wall parameters remain untouched. Endpoints that fall inside the configured
/// snap tolerance are averaged into one derived junction node, then terminal wall segments
/// receive a small deterministic cap extension so 2D/3D representation reads as continuous.
public struct WallJunctionResolver {
    public struct Configuration: Hashable, Sendable {
        public var endpointSnapToleranceMM: Double
        public var maximumCapExtensionMM: Double

        public init(endpointSnapToleranceMM: Double = GeometryTolerances.junctionJoinMM, maximumCapExtensionMM: Double = 100) {
            self.endpointSnapToleranceMM = endpointSnapToleranceMM
            self.maximumCapExtensionMM = maximumCapExtensionMM
        }
    }

    public struct ResolvedAxis: Codable, Hashable, Sendable {
        public var wallID: UUID
        public var start: Point2D
        public var end: Point2D
        public var joinedAtStart: Bool
        public var joinedAtEnd: Bool

        public var length: Double { (end - start).length }
        public var direction: Point2D { (end - start).normalized }
        public var normal: Point2D { Point2D(x: -direction.y, y: direction.x) }
        public var angleRadians: Double { atan2(direction.y, direction.x) }

        public init(wallID: UUID, start: Point2D, end: Point2D, joinedAtStart: Bool, joinedAtEnd: Bool) {
            self.wallID = wallID
            self.start = start
            self.end = end
            self.joinedAtStart = joinedAtStart
            self.joinedAtEnd = joinedAtEnd
        }

        public func point(atSemanticOffset offset: Double, semanticLength: Double) -> Point2D {
            guard semanticLength > 1e-9 else { return start }
            let t = max(0, min(1, offset / semanticLength))
            return start + direction * (length * t)
        }
    }

    public struct DisplaySpan: Codable, Hashable, Sendable {
        public var start: Point2D
        public var end: Point2D
        public var center: Point2D
        public var length: Double
        public var angleRadians: Double

        public init(start: Point2D, end: Point2D) {
            self.start = start
            self.end = end
            self.center = Point2D(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
            self.length = (end - start).length
            self.angleRadians = atan2(end.y - start.y, end.x - start.x)
        }
    }

    private struct Cluster {
        var point: Point2D
        var count: Int

        mutating func absorb(_ p: Point2D) {
            let n = Double(count)
            point = Point2D(
                x: (point.x * n + p.x) / (n + 1),
                y: (point.y * n + p.y) / (n + 1)
            )
            count += 1
        }
    }

    private struct EndpointAssignment {
        var startCluster: Int
        var endCluster: Int
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func resolve(room: PlanOpsisRoom) -> [UUID: ResolvedAxis] {
        let walls = room.walls.sorted { $0.id.uuidString < $1.id.uuidString }
        var clusters: [Cluster] = []
        var assignments: [UUID: EndpointAssignment] = [:]

        func nearestIndex(to point: Point2D, clusters: [Cluster], tolerance: Double, excluding: Int?) -> Int? {
            var best: Int?
            var bestDistance = tolerance
            for (index, cluster) in clusters.enumerated() where index != excluding {
                let d = (cluster.point - point).length
                if d <= bestDistance {
                    best = index
                    bestDistance = d
                }
            }
            return best
        }

        for wall in walls {
            var indices: [Int] = []
            // v12.2: a junction never swallows both ends of one wall, and never reaches farther than half
            // the wall's length, so short real jogs (piers, reveals) survive joining.
            let tolerance = GeometryTolerances.joinRadius(configuration.endpointSnapToleranceMM, wallLength: wall.length)
            for point in [wall.start, wall.end] {
                if let index = nearestIndex(to: point, clusters: clusters, tolerance: tolerance, excluding: indices.first) {
                    clusters[index].absorb(point)
                    indices.append(index)
                } else {
                    clusters.append(Cluster(point: point, count: 1))
                    indices.append(clusters.count - 1)
                }
            }
            assignments[wall.id] = EndpointAssignment(startCluster: indices[0], endCluster: indices[1])
        }

        var result: [UUID: ResolvedAxis] = [:]
        for wall in walls {
            guard let assignment = assignments[wall.id] else { continue }
            let startCluster = clusters[assignment.startCluster]
            let endCluster = clusters[assignment.endCluster]
            var start = startCluster.count > 1 ? startCluster.point : wall.start
            var end = endCluster.count > 1 ? endCluster.point : wall.end
            if (end - start).length <= 1e-9 {
                start = wall.start
                end = wall.end
            }
            result[wall.id] = ResolvedAxis(
                wallID: wall.id,
                start: start,
                end: end,
                joinedAtStart: startCluster.count > 1,
                joinedAtEnd: endCluster.count > 1
            )
        }
        return result
    }

    public func displaySpan(
        wall: PlanOpsisWall,
        axis: ResolvedAxis,
        startOffset: Double,
        length: Double
    ) -> DisplaySpan {
        let semanticEnd = startOffset + length
        var p0 = axis.point(atSemanticOffset: startOffset, semanticLength: wall.length)
        var p1 = axis.point(atSemanticOffset: semanticEnd, semanticLength: wall.length)
        let cap = min(configuration.maximumCapExtensionMM, wall.thickness * 0.5)
        if startOffset <= 1e-8, axis.joinedAtStart {
            p0 = p0 - axis.direction * cap
        }
        if semanticEnd >= wall.length - 1e-8, axis.joinedAtEnd {
            p1 = p1 + axis.direction * cap
        }
        return DisplaySpan(start: p0, end: p1)
    }
}
