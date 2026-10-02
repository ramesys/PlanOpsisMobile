import Foundation

/// v12.1 closes near-coincident wall junctions in the semantic model.
///
/// Endpoints that `WallJunctionResolver` clusters into one junction are written back as exactly
/// coincident endpoints, so the editable model, topology, DXF and IFC agree on closure. Hosted openings
/// keep their world station (see `PlanEditingConstraintEngine.reanchorHostedOpenings`). A room whose
/// openings would not fit after closing is left unchanged and reported, never partially edited.
public struct JunctionNormalizer {
    public struct Result: Sendable {
        public var project: PlanOpsisProject
        /// Number of wall endpoints that moved.
        public var movedEndpointCount: Int
        /// Rooms left unchanged because closing their junctions would push an opening off its wall.
        public var skippedRoomIDs: [UUID]
    }

    private let resolver: WallJunctionResolver

    public init(joinToleranceMM: Double = GeometryTolerances.junctionJoinMM) {
        resolver = WallJunctionResolver(configuration: .init(endpointSnapToleranceMM: joinToleranceMM))
    }

    public func normalize(_ project: PlanOpsisProject) -> Result {
        var next = project
        var moved = 0
        var skipped: [UUID] = []
        for index in next.rooms.indices {
            let room = next.rooms[index]
            let axes = resolver.resolve(room: room)
            var edited: [UUID: PlanOpsisWall] = [:]
            var roomMoved = 0
            for wall in room.walls {
                guard let axis = axes[wall.id] else { continue }
                let start = axis.joinedAtStart ? axis.start : wall.start
                let end = axis.joinedAtEnd ? axis.end : wall.end
                let startMoved = (start - wall.start).length > 1e-9
                let endMoved = (end - wall.end).length > 1e-9
                guard startMoved || endMoved, (end - start).length > GeometryTolerances.coincidenceMM else { continue }
                var updated = wall
                updated.editStart(start)
                updated.editEnd(end)
                edited[wall.id] = updated
                roomMoved += (startMoved ? 1 : 0) + (endMoved ? 1 : 0)
            }
            guard !edited.isEmpty else { continue }
            let previous = Dictionary(uniqueKeysWithValues: room.walls.map { ($0.id, $0) })
            guard let openings = try? PlanEditingConstraintEngine.reanchorHostedOpenings(
                room.openings, previousWalls: previous, editedWalls: edited
            ) else {
                skipped.append(room.id)
                continue
            }
            next.rooms[index].walls = room.walls.map { edited[$0.id] ?? $0 }
            next.rooms[index].openings = openings
            moved += roomMoved
        }
        return Result(project: next, movedEndpointCount: moved, skippedRoomIDs: skipped)
    }
}
