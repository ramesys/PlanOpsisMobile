import Foundation

/// v12.4 opening marks on the plan: doors in a circle, windows in a rectangle, other openings in a
/// diamond, placed inside the room next to the opening and kept horizontal for reading.
public struct PlanTagEngine: Sendable {
    public static let textHeightMM = 150.0

    public init() {}

    public func primitives(project: PlanOpsisProject, schedules: ProjectSchedules, topology: StructureTopologySnapshot) -> [DXFPrimitive] {
        let layer = ArchitecturalDraftingConvention.Layer.tags
        let weight = ArchitecturalDraftingConvention.lineWeightMM(for: layer)
        var output: [DXFPrimitive] = []
        var tagged = Set<String>()
        for room in PlanOrdering(project: project).rooms {
            let boundary = ArchitecturalRoomEnvelope.polygon(for: room, topology: topology)
            for opening in room.openings {
                // Shared openings are tagged once, from the first room that holds them.
                guard let mark = schedules.marks[opening.id], tagged.insert(mark).inserted,
                      let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { continue }
                let center = wall.start + wall.direction * opening.parameters.offsetAlongWall
                let inward = ArchitecturalSymbolLibrary.inwardSign(center: center, angle: wall.angleRadians, boundary: boundary)
                let tag = center + wall.normal * (inward * (wall.thickness / 2 + 420))
                let id = "tag:\(mark):\(opening.id.uuidString)"
                let frame: DXFPrimitive
                switch opening.kind {
                case .door:
                    // A circle as two half arcs: DXF ARC entities cannot sweep a full turn.
                    output.append(DXFPrimitive(id: id + ":frame2", kind: .arc, layer: layer.rawValue, center: tag, radius: 190, startAngleDegrees: 180, endAngleDegrees: 360, lineWeightMM: weight))
                    frame = DXFPrimitive(id: id + ":frame", kind: .arc, layer: layer.rawValue, center: tag, radius: 190, startAngleDegrees: 0, endAngleDegrees: 180, lineWeightMM: weight)
                case .window:
                    frame = DXFPrimitive(id: id + ":frame", kind: .polyline, layer: layer.rawValue,
                                         points: [tag + Point2D(x: -240, y: -140), tag + Point2D(x: 240, y: -140), tag + Point2D(x: 240, y: 140), tag + Point2D(x: -240, y: 140)],
                                         closed: true, lineWeightMM: weight)
                case .opening:
                    frame = DXFPrimitive(id: id + ":frame", kind: .polyline, layer: layer.rawValue,
                                         points: [tag + Point2D(x: 0, y: -230), tag + Point2D(x: 260, y: 0), tag + Point2D(x: 0, y: 230), tag + Point2D(x: -260, y: 0)],
                                         closed: true, lineWeightMM: weight)
                }
                output.append(frame)
                output.append(DXFPrimitive(id: id + ":text", kind: .text, layer: layer.rawValue, points: [tag], text: mark,
                                           textHeight: Self.textHeightMM, rotationDegrees: 0, lineWeightMM: weight, objectIDs: [opening.id], roomIDs: [room.id]))
            }
        }
        return output
    }
}
