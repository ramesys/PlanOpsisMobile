import Foundation
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// Made-up RoomPlan captures shaped like real ones, used as regression and reconstruction cases. They
/// describe no real place: the room, its identifiers and its floor height are invented.
enum SampleCaptureFixtures {
    /// The irregular room's interior faces, anticlockwise in plan millimetres:
    /// - a 4.2 m front wall with the entrance door;
    /// - a step out to 5.6 m with a window;
    /// - a 45° chamfer under a sloped ceiling (a non-rectangular wall);
    /// - a niche at the back;
    /// - a recess on the left with a passage.
    static let irregularRoomCorners: [Point2D] = [
        Point2D(x: 0, y: 0), Point2D(x: 4_200, y: 0), Point2D(x: 4_200, y: 1_500), Point2D(x: 5_600, y: 1_500),
        Point2D(x: 5_600, y: 3_600), Point2D(x: 5_000, y: 4_200), Point2D(x: 3_000, y: 4_200), Point2D(x: 3_000, y: 4_700),
        Point2D(x: 1_800, y: 4_700), Point2D(x: 1_800, y: 4_200), Point2D(x: 600, y: 4_200), Point2D(x: 600, y: 2_600),
        Point2D(x: 0, y: 2_600),
    ]
    /// Capture space starts at the device: its floor is well below zero, as in a real scan.
    static let floorElevation = -1.617
    static let wallHeight = 2.6
    static let windowSill = 0.439
    /// Index of the chamfer, the non-rectangular wall.
    static let complexWallIndex = 4

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "5A3F0000-0000-4000-8000-%012d", n))! }

    /// One irregular room with 13 walls: interior faces (RoomPlan's convention), one non-rectangular
    /// wall, a door, a window and a passage. The floor is at about -1.617 m in capture space.
    static func irregularRoom() -> StructureCaptureSnapshot {
        let corners = irregularRoomCorners
        var surfaces: [CapturedSurfaceSnapshot] = []
        var faces: [(id: UUID, start: Point2D, end: Point2D, angle: Double)] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let v = b - a
            // RoomPlan walks the room clockwise, so a wall's local +Z (its right-hand normal) faces the room.
            faces.append((id(10 + i), a, b, atan2(v.y, v.x) + .pi))
        }
        for (i, face) in faces.enumerated().reversed() {
            let center = (face.start + face.end) * 0.5
            surfaces.append(CapturedSurfaceSnapshot(
                sourceRoomPlanID: face.id, parentIdentifier: nil, category: .wall,
                transform: .wallTransform(centerX: center.x / 1_000, centerY: floorElevation + wallHeight / 2,
                                          centerZ: -center.y / 1_000, planAngleRadians: face.angle),
                dimensions: Dimensions3D(x: (face.end - face.start).length / 1_000, y: wallHeight, z: 0),
                confidence: .high,
                shapeHints: i == complexWallIndex
                    ? CapturedSurfaceShapeHints(hasCurve: false, polygonCornerCount: 5, completedEdgeCount: 5)
                    : CapturedSurfaceShapeHints(hasCurve: false, polygonCornerCount: 0, completedEdgeCount: 4)))
        }
        /// An opening on wall `host`, centred `along` millimetres from the wall's first corner.
        func opening(_ n: Int, _ category: CapturedSurfaceCategory, host: Int, along: Double, width: Double, height: Double, sill: Double) {
            let face = faces[host]
            let p = face.start + (face.end - face.start).normalized * along
            surfaces.append(CapturedSurfaceSnapshot(
                sourceRoomPlanID: id(n), parentIdentifier: face.id, category: category,
                transform: .wallTransform(centerX: p.x / 1_000, centerY: floorElevation + sill + height / 2,
                                          centerZ: -p.y / 1_000, planAngleRadians: face.angle),
                dimensions: Dimensions3D(x: width, y: height, z: 0), confidence: .high))
        }
        opening(1, .door, host: 0, along: 1_000, width: 0.9, height: 2.1, sill: 0)
        opening(2, .window, host: 3, along: 1_050, width: 1.2, height: 1.2, sill: windowSill)
        opening(3, .opening, host: 10, along: 800, width: 1.0, height: 2.2, sill: 0)
        return StructureCaptureSnapshot(room: RoomCaptureSnapshot(sourceRoomPlanID: id(1_000), surfaces: surfaces))
    }
}
