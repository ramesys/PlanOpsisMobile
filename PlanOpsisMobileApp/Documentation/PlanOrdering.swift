import Foundation

/// v12.6 orientation-based numbering shared by IFC, schedules, drawings and the app.
///
/// Capture order is arbitrary, so numbers follow the plan instead (plan +Y is north): rooms in reading
/// order, north to south in rows and west to east within a row; walls clockwise around their room,
/// starting from the north-west, outline walls before partitions inside the room; openings by wall, then clockwise along it. Numbers only change when
/// the geometry does.
public struct PlanOrdering: Sendable {
    /// Rooms in reading order.
    public private(set) var rooms: [PlanOpsisRoom] = []
    /// Room ID → 1-based room number.
    public private(set) var roomNumbers: [UUID: Int] = [:]
    /// Room ID → its walls, clockwise from the north-west.
    public private(set) var walls: [UUID: [PlanOpsisWall]] = [:]
    /// Wall ID → 1-based project-wide wall number, following room order then clockwise.
    public private(set) var wallNumbers: [UUID: Int] = [:]
    private var wallRanks: [UUID: Int] = [:]
    private var clockwiseWalls: Set<UUID> = []

    public init(project: PlanOpsisProject) {
        struct Entry { var room: PlanOpsisRoom; var box: (min: Point2D, max: Point2D); var center: Point2D }
        let entries = project.rooms.map { room -> Entry in
            let box = Self.bounds(of: room)
            return Entry(room: room, box: box, center: Point2D(x: (box.min.x + box.max.x) / 2, y: (box.min.y + box.max.y) / 2))
        }
        // North first; a room whose centre falls inside the band of the row's first room shares the row.
        let byNorth = entries.sorted {
            ($0.center.y, -$0.center.x, $0.room.id.uuidString) > ($1.center.y, -$1.center.x, $1.room.id.uuidString)
        }
        var rows: [[Entry]] = []
        for entry in byNorth {
            if let lead = rows.last?.first, entry.center.y >= lead.box.min.y - 1 {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }
        rooms = rows.flatMap { row in
            row.sorted { ($0.center.x, $0.room.id.uuidString) < ($1.center.x, $1.room.id.uuidString) }.map(\.room)
        }

        var wallCounter = 0
        for (index, room) in rooms.enumerated() {
            roomNumbers[room.id] = index + 1
            let center = entries.first { $0.room.id == room.id }!.center
            // The room outline first, then partitions and stems inside it, each clockwise.
            let interior = Self.interiorWalls(of: room)
            func key(_ wall: PlanOpsisWall) -> (Int, Double, String) {
                (interior.contains(wall.id) ? 1 : 0, Self.clockwiseBearing(of: wall.center - center), wall.id.uuidString)
            }
            let ordered = room.walls.sorted { key($0) < key($1) }
            walls[room.id] = ordered
            for (rank, wall) in ordered.enumerated() {
                wallRanks[wall.id] = rank
                if wallNumbers[wall.id] == nil {
                    wallCounter += 1
                    wallNumbers[wall.id] = wallCounter
                }
                let toWall = wall.center - center
                // Plan Y up: travelling start → end clockwise around the centre turns the cross product negative.
                if toWall.x * wall.direction.y - toWall.y * wall.direction.x <= 0 { clockwiseWalls.insert(wall.id) }
            }
        }
    }

    /// Walls of a room, clockwise from the north-west (stored order for an unknown room).
    public func orderedWalls(of room: PlanOpsisRoom) -> [PlanOpsisWall] { walls[room.id] ?? room.walls }

    /// "Wall 01"; nil for an unknown wall.
    public func wallName(_ wallID: UUID) -> String? {
        wallNumbers[wallID].map { "Wall " + String(format: "%02d", $0) }
    }

    /// "Room 3"; nil for an unknown room.
    public func roomLabel(_ roomID: UUID) -> String? { roomNumbers[roomID].map { "Room \($0)" } }

    /// Sort key for an opening: room number, wall position clockwise, then distance along the wall
    /// in the clockwise direction.
    public func openingKey(_ opening: PlanOpsisOpening, in room: PlanOpsisRoom) -> (Int, Int, Double)? {
        let p = opening.parameters
        guard let roomNumber = roomNumbers[room.id], let rank = wallRanks[p.hostWallID],
              let wall = room.walls.first(where: { $0.id == p.hostWallID }) else { return nil }
        let along = clockwiseWalls.contains(wall.id) ? p.offsetAlongWall : wall.length - p.offsetAlongWall
        return (roomNumber, rank, along)
    }

    /// Clockwise angle in degrees from north-west (0 = NW, 45 = N, 135 = E, 225 = S, 315 = W).
    static func clockwiseBearing(of vector: Point2D) -> Double {
        guard vector.x != 0 || vector.y != 0 else { return 0 }
        let degrees = atan2(vector.y, vector.x) * 180 / .pi
        let bearing = (135 - degrees).truncatingRemainder(dividingBy: 360)
        let normalized = bearing < 0 ? bearing + 360 : bearing
        // Snap float noise so walls exactly at north-west stay first.
        return normalized > 359.999 ? 0 : normalized
    }

    /// Walls that are not part of the room's closed outline: a wall belongs to the outline when both of
    /// its ends meet another wall's end (a corner), so stems and T-junction partitions are interior.
    static func interiorWalls(of room: PlanOpsisRoom, tolerance: Double = 250) -> Set<UUID> {
        var interior = Set<UUID>()
        for wall in room.walls {
            func cornered(_ point: Point2D) -> Bool {
                room.walls.contains { other in
                    other.id != wall.id && ((other.start - point).length <= tolerance || (other.end - point).length <= tolerance)
                }
            }
            if !(cornered(wall.start) && cornered(wall.end)) { interior.insert(wall.id) }
        }
        // An open run of walls has no outline to put first.
        return interior.count == room.walls.count ? [] : interior
    }

    static func bounds(of room: PlanOpsisRoom) -> (min: Point2D, max: Point2D) {
        var points = room.walls.flatMap { [$0.start, $0.end] }
        if points.isEmpty { points = room.components.map(\.position) }
        guard let first = points.first else { return (Point2D(x: 0, y: 0), Point2D(x: 0, y: 0)) }
        var lo = first, hi = first
        for p in points {
            lo = Point2D(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = Point2D(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return (lo, hi)
    }
}
