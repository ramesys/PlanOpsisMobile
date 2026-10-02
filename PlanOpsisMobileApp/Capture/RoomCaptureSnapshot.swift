import Foundation

/// Platform-neutral evidence for one RoomPlan room.
/// Values stay in RoomPlan metres until the adapter boundary.
public struct RoomCaptureSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var sourceRoomPlanID: UUID
    public var surfaces: [CapturedSurfaceSnapshot]

    public var id: UUID { sourceRoomPlanID }

    public init(sourceRoomPlanID: UUID, surfaces: [CapturedSurfaceSnapshot]) {
        self.sourceRoomPlanID = sourceRoomPlanID
        self.surfaces = surfaces
    }
}

/// Platform-neutral evidence for several RoomPlan rooms that occupy one compatible world space.
/// `sourceStructureRoomPlanID` is provenance only; PlanOpsis mints its own project and room UUIDs.
public struct StructureCaptureSnapshot: Codable, Hashable, Sendable {
    public var sourceStructureRoomPlanID: UUID?
    public var rooms: [RoomCaptureSnapshot]

    public init(sourceStructureRoomPlanID: UUID? = nil, rooms: [RoomCaptureSnapshot]) {
        self.sourceStructureRoomPlanID = sourceStructureRoomPlanID
        self.rooms = rooms
    }

    public init(room: RoomCaptureSnapshot) {
        self.init(sourceStructureRoomPlanID: nil, rooms: [room])
    }
}

public enum CapturedSurfaceCategory: String, Codable, Hashable, Sendable {
    case wall
    case door
    case window
    case opening
}

/// Shape evidence is provenance/diagnostic input only. The MVP remains straight-wall only.
public struct CapturedSurfaceShapeHints: Codable, Hashable, Sendable {
    public var hasCurve: Bool
    public var polygonCornerCount: Int
    public var completedEdgeCount: Int

    public init(hasCurve: Bool = false, polygonCornerCount: Int = 0, completedEdgeCount: Int = 0) {
        self.hasCurve = hasCurve
        self.polygonCornerCount = polygonCornerCount
        self.completedEdgeCount = completedEdgeCount
    }

    public var hasComplexPolygon: Bool { polygonCornerCount > 0 }
}

public struct CapturedSurfaceSnapshot: Codable, Hashable, Sendable {
    public var sourceRoomPlanID: UUID
    public var parentIdentifier: UUID?
    public var category: CapturedSurfaceCategory
    /// Column-major 4x4 transform, matching simd_float4x4 storage.
    public var transform: TransformSnapshot
    /// RoomPlan dimensions in metres.
    public var dimensions: Dimensions3D
    public var confidence: CaptureConfidence
    public var shapeHints: CapturedSurfaceShapeHints

    public init(
        sourceRoomPlanID: UUID,
        parentIdentifier: UUID?,
        category: CapturedSurfaceCategory,
        transform: TransformSnapshot,
        dimensions: Dimensions3D,
        confidence: CaptureConfidence,
        shapeHints: CapturedSurfaceShapeHints = .init()
    ) {
        self.sourceRoomPlanID = sourceRoomPlanID
        self.parentIdentifier = parentIdentifier
        self.category = category
        self.transform = transform
        self.dimensions = dimensions
        self.confidence = confidence
        self.shapeHints = shapeHints
    }
}

public struct Dimensions3D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct TransformSnapshot: Codable, Hashable, Sendable {
    /// Exactly 16 values in column-major order.
    public var values: [Double]

    public init(values: [Double]) {
        precondition(values.count == 16, "TransformSnapshot requires 16 column-major values")
        self.values = values
    }

    public static func identity(translationX x: Double = 0, y: Double = 0, z: Double = 0) -> TransformSnapshot {
        TransformSnapshot(values: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1
        ])
    }

    public static func wallTransform(centerX: Double, centerY: Double, centerZ: Double, planAngleRadians: Double) -> TransformSnapshot {
        // PlanOpsis +Y maps to RoomPlan -Z. Local wall +X therefore maps to (cos(a), 0, -sin(a)).
        let c = cos(planAngleRadians)
        let s = sin(planAngleRadians)
        return TransformSnapshot(values: [
            c, 0, -s, 0,
            0, 1, 0, 0,
            s, 0, c, 0,
            centerX, centerY, centerZ, 1
        ])
    }

    public var translationX: Double { values[12] }
    public var translationY: Double { values[13] }
    public var translationZ: Double { values[14] }
    public var localXAxisX: Double { values[0] }
    public var localXAxisZ: Double { values[2] }
}
