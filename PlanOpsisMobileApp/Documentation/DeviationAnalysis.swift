import Foundation

/// v12.7 surveyed walls and openings compared with an aligned drawing (the architect's design or an
/// earlier survey): how far each wall's axis sits from the drawing's, how much it is turned, and which
/// walls and openings appear in only one of them.
public struct DeviationAnalysis: Sendable {
    public struct Tolerances: Hashable, Sendable {
        /// Up to this, mm: within tolerance.
        public var ok: Double
        /// Up to this, mm: worth a look; beyond: a deviation.
        public var warning: Double
        /// How far, mm, a drawing wall may lie from a surveyed one and still be its counterpart.
        public var search: Double
        public init(ok: Double = 20, warning: Double = 50, search: Double = 600) {
            self.ok = ok; self.warning = warning; self.search = search
        }
    }

    public enum Status: String, Hashable, Sendable, CaseIterable {
        case ok, warning, deviation
        /// Surveyed but not in the drawing, or in the drawing but not surveyed.
        case unmatched

        public var title: String {
            switch self {
            case .ok: return "Within tolerance"
            case .warning: return "Check"
            case .deviation: return "Deviation"
            case .unmatched: return "Unmatched"
            }
        }
    }

    public struct WallRow: Hashable, Sendable, Identifiable {
        public var wallID: UUID
        public var name: String
        public var room: String
        /// Signed axis offset at the wall's middle, mm, and the compass direction from drawing to survey.
        public var offset: Double?
        public var direction: String?
        /// Largest distance of the surveyed axis ends from the drawing's axis, mm (shows rotation).
        public var endDeviation: Double?
        public var angleDegrees: Double?
        public var thicknessDifference: Double?
        /// Surveyed minus drawn length, when both walls cover the same stretch.
        public var lengthDifference: Double?
        public var status: Status
        /// For the plan overlay: the drawing's axis point and the surveyed middle.
        public var referencePoint: Point2D?
        public var surveyPoint: Point2D
        public var id: UUID { wallID }
    }

    public struct OpeningRow: Hashable, Sendable, Identifiable {
        public var mark: String
        public var kind: PlanOpsisOpening.Kind
        public var positionDifference: Double?
        public var widthDifference: Double?
        public var status: Status
        public var surveyPoint: Point2D
        public var referencePoint: Point2D?
        public var id: String { mark }
    }

    public var tolerances: Tolerances
    public private(set) var walls: [WallRow] = []
    public private(set) var openings: [OpeningRow] = []
    /// Drawing walls and openings no surveyed one matches.
    public private(set) var missingWalls: [TracedWall] = []
    public private(set) var missingOpenings: [(kind: PlanOpsisOpening.Kind, center: Point2D, width: Double)] = []

    public init(project: PlanOpsisProject, reference: UnderlayTraceResult, tolerances: Tolerances = Tolerances()) {
        self.tolerances = tolerances
        let ordering = PlanOrdering(project: project)
        let roomNames = ProjectSchedules.roomNames(project, ordering: ordering)
        let refs = reference.walls.filter { $0.length > 1 }
        var matched = Set<Int>()

        // Each physical wall once: a partition captured by both rooms is one row.
        var seen: [PlanOpsisWall] = []
        for room in ordering.rooms {
            for wall in ordering.orderedWalls(of: room) where wall.length > 1 {
                if seen.contains(where: { Self.sameWall($0, wall) }) { continue }
                seen.append(wall)
                let mid = wall.center
                var best: (index: Int, distance: Double)?
                for (i, ref) in refs.enumerated() {
                    guard abs(Self.cross(wall.direction, ref.direction)) <= sin(10 * Double.pi / 180) else { continue }
                    let distance = abs(Self.cross(ref.direction, mid - ref.start))
                    guard distance <= tolerances.search, Self.overlap(wall, ref) >= 0.3 * min(wall.length, ref.length) else { continue }
                    if best == nil || distance < best!.distance { best = (i, distance) }
                }
                let name = ordering.wallName(wall.id) ?? "Wall"
                let roomName = roomNames[room.id] ?? ""
                guard let best else {
                    walls.append(WallRow(wallID: wall.id, name: name, room: roomName, status: .unmatched, surveyPoint: mid))
                    continue
                }
                matched.insert(best.index)
                let ref = refs[best.index]
                let foot = ref.start + ref.direction * (mid - ref.start).dot(ref.direction)
                let offsetVector = mid - foot
                let ends = [wall.start, wall.end].map { abs(Self.cross(ref.direction, $0 - ref.start)) }
                var angle = (atan2(wall.direction.y, wall.direction.x) - atan2(ref.direction.y, ref.direction.x)) * 180 / .pi
                angle = angle.truncatingRemainder(dividingBy: 180)
                if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
                let shared = Self.overlap(wall, ref)
                let sameStretch = shared >= 0.9 * max(wall.length, ref.length) - 2 * max(wall.thickness, ref.thickness)
                let worst = ends.max() ?? best.distance
                walls.append(WallRow(
                    wallID: wall.id, name: name, room: roomName,
                    offset: offsetVector.length, direction: offsetVector.length >= 1 ? ArchitecturalSectionEngine.compass(offsetVector) : nil,
                    endDeviation: worst, angleDegrees: angle,
                    thicknessDifference: wall.thickness - ref.thickness,
                    lengthDifference: sameStretch ? wall.length - ref.length : nil,
                    status: status(worst), referencePoint: foot, surveyPoint: mid))
            }
        }
        missingWalls = refs.enumerated().filter { !matched.contains($0.offset) }.map(\.element)

        // Openings by schedule mark against the drawing's openings.
        let schedules = ProjectSchedules(project: project)
        var refOpenings: [(kind: PlanOpsisOpening.Kind, center: Point2D, width: Double)] = reference.openings.compactMap { o in
            guard reference.walls.indices.contains(o.wallIndex) else { return nil }
            let w = reference.walls[o.wallIndex]
            return (o.kind, w.start + w.direction * o.offset, o.width)
        }
        var seenMarks = Set<String>()
        for room in ordering.rooms {
            for opening in room.openings {
                guard let mark = schedules.marks[opening.id], seenMarks.insert(mark).inserted,
                      let host = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { continue }
                let center = host.start + host.direction * opening.parameters.offsetAlongWall
                let candidate = refOpenings.indices.min { (refOpenings[$0].center - center).length < (refOpenings[$1].center - center).length }
                guard let index = candidate, (refOpenings[index].center - center).length <= max(600, opening.parameters.width) else {
                    openings.append(OpeningRow(mark: mark, kind: opening.kind, status: .unmatched, surveyPoint: center))
                    continue
                }
                let ref = refOpenings.remove(at: index)
                let position = (ref.center - center).length
                let width = opening.parameters.width - ref.width
                openings.append(OpeningRow(mark: mark, kind: opening.kind, positionDifference: position, widthDifference: width,
                                           status: ref.kind == opening.kind ? status(max(position, abs(width))) : .deviation,
                                           surveyPoint: center, referencePoint: ref.center))
            }
        }
        missingOpenings = refOpenings
        openings.sort { $0.mark < $1.mark }
    }

    func status(_ value: Double) -> Status {
        value <= tolerances.ok ? .ok : (value <= tolerances.warning ? .warning : .deviation)
    }

    /// Counts per status, walls and openings together, drawing-only items as unmatched.
    public var summary: [Status: Int] {
        var counts: [Status: Int] = [:]
        for row in walls { counts[row.status, default: 0] += 1 }
        for row in openings { counts[row.status, default: 0] += 1 }
        counts[.unmatched, default: 0] += missingWalls.count + missingOpenings.count
        return counts
    }

    public var largestOffset: Double { walls.compactMap(\.endDeviation).max() ?? 0 }

    /// The comparison as tables for the app, the sheets and CSV.
    public var tables: [ProjectSchedules.Table] {
        func mm(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }
        func signed(_ v: Double?) -> String { v.map { String(format: "%+.0f", $0) } ?? "" }
        var result: [ProjectSchedules.Table] = []
        result.append(.init(
            title: "Wall deviations (ok ≤ \(Int(tolerances.ok)) mm, check ≤ \(Int(tolerances.warning)) mm)",
            columns: ["Wall", "Room", "Offset mm", "Towards", "Max at ends mm", "Turn °", "Thickness ± mm", "Length ± mm", "Status"],
            rows: walls.map { [$0.name, $0.room, mm($0.offset), $0.direction ?? "", mm($0.endDeviation),
                               $0.angleDegrees.map { String(format: "%+.1f", $0) } ?? "", signed($0.thicknessDifference),
                               signed($0.lengthDifference), $0.status.title] },
            numericColumns: [2, 4, 5, 6, 7]))
        if !openings.isEmpty {
            result.append(.init(
                title: "Opening deviations",
                columns: ["Mark", "Position mm", "Width ± mm", "Status"],
                rows: openings.map { [$0.mark, mm($0.positionDifference), signed($0.widthDifference), $0.status.title] },
                numericColumns: [1, 2]))
        }
        if !missingWalls.isEmpty || !missingOpenings.isEmpty {
            result.append(.init(
                title: "In the drawing, not surveyed",
                columns: ["Element", "Length or width mm", "Thickness mm", "X mm", "Y mm"],
                rows: missingWalls.map { w in
                    let c = (w.start + w.end) * 0.5
                    return ["Wall", mm(w.length), mm(w.thickness), mm(c.x), mm(c.y)]
                } + missingOpenings.map { o in
                    [o.kind == .door ? "Door" : (o.kind == .window ? "Window" : "Opening"), mm(o.width), "", mm(o.center.x), mm(o.center.y)]
                },
                numericColumns: [1, 2, 3, 4]))
        }
        return result
    }

    // MARK: Geometry

    static func cross(_ a: Point2D, _ b: Point2D) -> Double { a.x * b.y - a.y * b.x }

    static func overlap(_ wall: PlanOpsisWall, _ ref: TracedWall) -> Double {
        let u = ref.direction
        let a0 = (wall.start - ref.start).dot(u), a1 = (wall.end - ref.start).dot(u)
        return min(ref.length, max(a0, a1)) - max(0, min(a0, a1))
    }

    static func sameWall(_ a: PlanOpsisWall, _ b: PlanOpsisWall) -> Bool {
        let tolerance = 10.0
        return ((a.start - b.start).length < tolerance && (a.end - b.end).length < tolerance)
            || ((a.start - b.end).length < tolerance && (a.end - b.start).length < tolerance)
    }
}
