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

    public func bottomElevationMM(surface: CapturedSurfaceSnapshot) -> Double {
        millimetres(fromMetres: surface.transform.translationY - surface.dimensions.y * 0.5)
    }
}
