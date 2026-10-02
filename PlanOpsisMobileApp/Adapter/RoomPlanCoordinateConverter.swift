import Foundation

/// The single coordinate/unit boundary between RoomPlan capture evidence and PlanOpsis architecture.
/// RoomPlan input: metres, Y-up, plan axes X/Z.
/// PlanOpsis output: millimetres, 2D plan axes X/Y where PlanOpsis +Y = RoomPlan -Z.
public struct RoomPlanCoordinateConverter {
    public static let millimetresPerMetre = 1000.0

    public init() {}

    public func millimetres(fromMetres value: Double) -> Double {
        value * Self.millimetresPerMetre
    }

    public func planPointMM(from transform: TransformSnapshot) -> Point2D {
        Point2D(
            x: millimetres(fromMetres: transform.translationX),
            y: millimetres(fromMetres: -transform.translationZ)
        )
    }

    public func planDirection(from transform: TransformSnapshot) -> Point2D {
        Point2D(
            x: transform.localXAxisX,
            y: -transform.localXAxisZ
        ).normalized
    }

    /// Bottom of a surface in the capture coordinate space. RoomPlan/ARKit world Y=0 is the device's
    /// starting height, not the floor, so this is not an architectural elevation on its own.
    public func bottomElevationMM(surface: CapturedSurfaceSnapshot) -> Double {
        millimetres(fromMetres: surface.transform.translationY - surface.dimensions.y * 0.5)
    }

    /// v12.1 room floor datum: the median bottom of the room's wall surfaces in capture space.
    /// The median ignores the occasional short or floating wall fragment. Nil without wall evidence.
    public func floorElevationMM(walls: [CapturedSurfaceSnapshot]) -> Double? {
        let bottoms = walls
            .filter { $0.category == .wall && $0.dimensions.y > 1e-6 && $0.transform.translationY.isFinite }
            .map(bottomElevationMM(surface:))
            .sorted()
        guard !bottoms.isEmpty else { return nil }
        let middle = bottoms.count / 2
        return bottoms.count.isMultiple(of: 2) ? (bottoms[middle - 1] + bottoms[middle]) * 0.5 : bottoms[middle]
    }
}
