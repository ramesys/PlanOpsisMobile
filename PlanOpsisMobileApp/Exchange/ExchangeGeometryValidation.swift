import Foundation

/// Validate editable semantics before either exporter generates geometry or formats numbers.
public enum ExchangeGeometryValidation {
    public static func errors(in project: PlanOpsisProject) -> [String] {
        var errors: [String] = []
        var ids = Set<UUID>()
        func id(_ value: UUID) {
            if !ids.insert(value).inserted { errors.append("Duplicate semantic UUID: \(value).") }
        }
        func finite(_ values: [Double], _ name: String) {
            if values.contains(where: { !$0.isFinite }) { errors.append("\(name) contains non-finite geometry.") }
            // Beyond this bound millimetre drafting loses useful numerical precision.
            else if values.contains(where: { abs($0) > 1e12 }) { errors.append("\(name) exceeds supported millimetre coordinate range.") }
        }
        id(project.id)
        for room in project.rooms {
            id(room.id)
            for wall in room.walls {
                id(wall.id)
                finite([wall.start.x,wall.start.y,wall.length,wall.angleRadians,wall.thickness,wall.height], "Wall \(wall.id)")
                if wall.length <= 0 || wall.thickness <= 0 || wall.height <= 0 { errors.append("Wall \(wall.id) has non-positive dimensions.") }
            }
            for opening in room.openings {
                id(opening.id)
                let p = opening.parameters
                finite([p.offsetAlongWall,p.width,p.height,p.sillHeight], "Opening \(opening.id)")
                if p.width <= 0 || p.height <= 0 || p.sillHeight < 0 { errors.append("Opening \(opening.id) has invalid dimensions.") }
                guard let wall = room.walls.first(where: { $0.id == p.hostWallID }) else {
                    errors.append("Opening \(opening.id) references a missing host wall."); continue
                }
                // Do not let DXF clip while IFC exports a different, full-sized opening.
                if p.offsetAlongWall - p.width/2 < -1e-6 || p.offsetAlongWall + p.width/2 > wall.length + 1e-6 || p.sillHeight + p.height > wall.height + 1e-6 {
                    errors.append("Opening \(opening.id) extends outside its host wall.")
                }
            }
            for component in room.components {
                id(component.id)
                finite([component.position.x,component.position.y,component.width,component.depth,component.height,component.baseElevationMM,component.rotationRadians], "Component \(component.id)")
                if component.width <= 0 || component.depth <= 0 || component.height <= 0 { errors.append("Component \(component.id) has non-positive dimensions.") }
            }
        }
        return errors
    }
}
