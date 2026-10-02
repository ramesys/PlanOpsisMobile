import Foundation

/// Finds a proven outer loop after pruning free-ended interior partitions.
/// Does not change topology acceptance or turn an incomplete survey into a closed room.
public enum ArchitecturalRoomEnvelope {
    public static func polygon(for room: PlanOpsisRoom, topology: StructureTopologySnapshot) -> [Point2D] {
        if let boundary = topology.roomBoundaries.first(where: { $0.roomID == room.id && $0.isClosed }) { return boundary.polygon }
        var walls = room.walls
        var changed = true
        while changed && walls.count >= 3 {
            let remaining = walls.filter { wall in
                [wall.start,wall.end].allSatisfy { endpoint in
                    walls.contains { other in other.id != wall.id && min((other.start-endpoint).length,(other.end-endpoint).length) <= 1e-6 }
                }
            }
            changed = remaining.count != walls.count
            walls = remaining
        }
        guard walls.count >= 3, walls.count < room.walls.count else { return [] }
        let reduced = PlanOpsisRoom(id: room.id, walls: walls)
        let result = StructureTopologyEngine().generate(from: PlanOpsisProject(rooms:[reduced]))
        return result.roomBoundaries.first(where: { $0.isClosed })?.polygon ?? []
    }
}
