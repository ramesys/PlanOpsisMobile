import Foundation

public struct MockRoomCaptureProvider {
    public static let roomSourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    public static let wallSourceIDs = (1...4).map { UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", $0))! }
    public static let doorSourceID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

    public init() {}

    public func snapshot() -> RoomCaptureSnapshot {
        let wallHeight = 2.8
        var surfaces: [CapturedSurfaceSnapshot] = [
            wall(id: Self.wallSourceIDs[0], centerX: 2.0, centerZ: 0.0, length: 4.0, angle: 0, height: wallHeight),
            wall(id: Self.wallSourceIDs[1], centerX: 4.0, centerZ: -1.5, length: 3.0, angle: .pi / 2, height: wallHeight),
            wall(id: Self.wallSourceIDs[2], centerX: 2.0, centerZ: -3.0, length: 4.0, angle: .pi, height: wallHeight),
            wall(id: Self.wallSourceIDs[3], centerX: 0.0, centerZ: -1.5, length: 3.0, angle: -.pi / 2, height: wallHeight)
        ]

        surfaces.append(opening(
            id: Self.doorSourceID,
            category: .door,
            host: Self.wallSourceIDs[0],
            centerX: 1.0,
            centerY: 1.05,
            centerZ: 0.0,
            width: 0.9,
            height: 2.1,
            angle: 0,
            confidence: .high
        ))
        surfaces.append(opening(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            category: .window,
            host: Self.wallSourceIDs[2],
            centerX: 1.2,
            centerY: 1.55,
            centerZ: -3.0,
            width: 1.2,
            height: 1.2,
            angle: .pi,
            confidence: .high
        ))
        surfaces.append(opening(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            category: .window,
            host: Self.wallSourceIDs[2],
            centerX: 2.8,
            centerY: 1.55,
            centerZ: -3.0,
            width: 1.0,
            height: 1.2,
            angle: .pi,
            confidence: .medium
        ))
        surfaces.append(opening(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            category: .opening,
            host: Self.wallSourceIDs[1],
            centerX: 4.0,
            centerY: 1.2,
            centerZ: -2.2,
            width: 1.0,
            height: 2.4,
            angle: .pi / 2,
            confidence: .medium
        ))

        // v12.8 recognised objects: a bed under the windows, a wardrobe on the east wall, a television
        // hung on the west wall. A box's +z is its front.
        let objects = [
            object(1, "bed", centerX: 2.0, bottom: 0, centerZ: -2.0, width: 1.6, height: 0.5, depth: 2.0, front: 0),
            object(2, "storage", centerX: 3.7, bottom: 0, centerZ: -0.9, width: 1.0, height: 2.0, depth: 0.6, front: -.pi / 2),
            object(3, "television", centerX: 0.06, bottom: 1.0, centerZ: -1.5, width: 1.25, height: 0.72, depth: 0.08, front: .pi / 2),
        ]

        // The mock walls describe centrelines; real RoomPlan walls are interior faces.
        return RoomCaptureSnapshot(sourceRoomPlanID: Self.roomSourceID, surfaces: surfaces, wallReference: .centerline, objects: objects)
    }

    /// A recognised object's box. `front` is the plan angle of the box's local x axis (its width),
    /// the same convention as walls: 0 faces the front south (towards -plan y).
    fileprivate func object(_ n: Int, _ category: String, centerX: Double, bottom: Double, centerZ: Double,
                            width: Double, height: Double, depth: Double, front: Double, confidence: CaptureConfidence = .high) -> CapturedObjectSnapshot {
        CapturedObjectSnapshot(
            sourceRoomPlanID: UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", n))!,
            category: category,
            transform: .wallTransform(centerX: centerX, centerY: bottom + height * 0.5, centerZ: centerZ, planAngleRadians: front),
            dimensions: Dimensions3D(x: width, y: height, z: depth),
            confidence: confidence
        )
    }

    fileprivate func wall(id: UUID, centerX: Double, centerZ: Double, length: Double, angle: Double, height: Double) -> CapturedSurfaceSnapshot {
        CapturedSurfaceSnapshot(
            sourceRoomPlanID: id,
            parentIdentifier: nil,
            category: .wall,
            transform: .wallTransform(centerX: centerX, centerY: height * 0.5, centerZ: centerZ, planAngleRadians: angle),
            dimensions: Dimensions3D(x: length, y: height, z: 0),
            confidence: .high,
            shapeHints: CapturedSurfaceShapeHints(hasCurve: false, polygonCornerCount: 0, completedEdgeCount: 4)
        )
    }

    fileprivate func opening(
        id: UUID,
        category: CapturedSurfaceCategory,
        host: UUID,
        centerX: Double,
        centerY: Double,
        centerZ: Double,
        width: Double,
        height: Double,
        angle: Double,
        confidence: CaptureConfidence
    ) -> CapturedSurfaceSnapshot {
        CapturedSurfaceSnapshot(
            sourceRoomPlanID: id,
            parentIdentifier: host,
            category: category,
            transform: .wallTransform(centerX: centerX, centerY: centerY, centerZ: centerZ, planAngleRadians: angle),
            dimensions: Dimensions3D(x: width, y: height, z: 0),
            confidence: confidence,
            shapeHints: CapturedSurfaceShapeHints(hasCurve: false, polygonCornerCount: 0, completedEdgeCount: 4)
        )
    }
}

/// Deterministic two-room fixture in one shared world space.
/// Room 2 is adjacent to Room 1 on the +X side. Each room keeps its own semantic wall set,
/// matching RoomPlan's room-centric capture model; cross-room wall reconciliation is intentionally
/// handled only by derived topology/reconciliation/display layers; semantic room-local walls remain independent.
public struct MockStructureCaptureProvider {
    public static let structureSourceID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    public static let room2SourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    public static let room2WallSourceIDs = (1...4).map { UUID(uuidString: String(format: "21000000-0000-0000-0000-%012d", $0))! }
    public static let room2DoorSourceID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!

    public init() {}

    public func snapshot() -> StructureCaptureSnapshot {
        let provider = MockRoomCaptureProvider()
        let room1 = provider.snapshot()
        let wallHeight = 2.8

        var room2Surfaces: [CapturedSurfaceSnapshot] = [
            provider.wall(id: Self.room2WallSourceIDs[0], centerX: 6.0, centerZ: 0.0, length: 4.0, angle: 0, height: wallHeight),
            provider.wall(id: Self.room2WallSourceIDs[1], centerX: 8.0, centerZ: -1.5, length: 3.0, angle: .pi / 2, height: wallHeight),
            provider.wall(id: Self.room2WallSourceIDs[2], centerX: 6.0, centerZ: -3.0, length: 4.0, angle: .pi, height: wallHeight),
            provider.wall(id: Self.room2WallSourceIDs[3], centerX: 4.0, centerZ: -1.5, length: 3.0, angle: -.pi / 2, height: wallHeight)
        ]

        room2Surfaces.append(provider.opening(
            id: Self.room2DoorSourceID,
            category: .door,
            host: Self.room2WallSourceIDs[3],
            centerX: 4.0,
            centerY: 1.05,
            centerZ: -2.2,
            width: 1.0,
            height: 2.1,
            angle: -.pi / 2,
            confidence: .high
        ))
        room2Surfaces.append(provider.opening(
            id: UUID(uuidString: "41000000-0000-0000-0000-000000000001")!,
            category: .window,
            host: Self.room2WallSourceIDs[1],
            centerX: 8.0,
            centerY: 1.55,
            centerZ: -1.5,
            width: 1.2,
            height: 1.2,
            angle: .pi / 2,
            confidence: .high
        ))

        // v12.8 a kitchen run along the north wall.
        let room2Objects = [
            provider.object(11, "refrigerator", centerX: 7.6, bottom: 0, centerZ: -2.65, width: 0.6, height: 1.85, depth: 0.65, front: 0),
            provider.object(12, "stove", centerX: 6.9, bottom: 0, centerZ: -2.7, width: 0.6, height: 0.9, depth: 0.6, front: 0),
            provider.object(13, "sink", centerX: 6.2, bottom: 0, centerZ: -2.7, width: 0.8, height: 0.9, depth: 0.6, front: 0, confidence: .medium),
        ]
        let room2 = RoomCaptureSnapshot(
            sourceRoomPlanID: Self.room2SourceID,
            surfaces: room2Surfaces,
            wallReference: .centerline,
            objects: room2Objects
        )

        return StructureCaptureSnapshot(
            sourceStructureRoomPlanID: Self.structureSourceID,
            rooms: [room1, room2]
        )
    }
}
