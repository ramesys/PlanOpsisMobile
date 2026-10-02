import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// v12.2 accuracy regressions, driven by a real RoomPlan capture where possible.
final class PlanOpsisV122Tests: XCTestCase {
    static func adapt(_ snapshot: StructureCaptureSnapshot) -> RoomPlanAdapter.Result {
        let ids = PlanOpsisV121Tests.SequentialUUIDs()
        return RoomPlanAdapter(configuration: .init(uuidProvider: ids.make)).adapt(snapshot)
    }

    // MARK: 1. RoomPlan wall surfaces are interior faces

    func testRealCaptureWallNormalsPointIntoTheRoom() throws {
        // RoomPlan wall surfaces carry the room on their local +Z side; around the room's outer loop
        // that is always the interior. This is what makes face registration well-defined.
        let capture = try RealCaptureFixtures.apartment1()
        let converter = RoomPlanCoordinateConverter()
        for surface in capture.rooms[0].surfaces where surface.category == .wall {
            let direction = converter.planDirection(from: surface.transform)
            let normal = converter.planNormal(from: surface.transform)
            XCTAssertEqual(normal.dot(Point2D(x: direction.y, y: -direction.x)), 1, accuracy: 1e-5, "local +Z is the right-hand plan normal")
        }
    }

    func testRealCaptureFacesStayPutAndAxesMoveBehindThem() throws {
        let capture = try RealCaptureFixtures.apartment1()
        let room = try XCTUnwrap(Self.adapt(capture).project.rooms.first)
        let converter = RoomPlanCoordinateConverter()
        var checked = 0
        for surface in capture.rooms[0].surfaces where surface.category == .wall {
            guard let wall = room.walls.first(where: { $0.sourceRoomPlanID == surface.sourceRoomPlanID }) else { continue }
            let faceCenter = converter.planPointMM(from: surface.transform)
            let roomSide = converter.planNormal(from: surface.transform)
            XCTAssertEqual(abs(wall.direction.dot(converter.planDirection(from: surface.transform))), 1, accuracy: 1e-4)
            // The observed face stays half a thickness from the axis, on the room side. Two-wall corners are
            // exact mitres; where three walls meet, the shared corner is a least-squares compromise (≤ 3 mm here).
            XCTAssertEqual((faceCenter - wall.start).dot(roomSide), wall.thickness / 2, accuracy: 3)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 19)
    }

    func testRealCaptureCornersStayJoinedOnTheAxes() throws {
        let capture = try RealCaptureFixtures.apartment1()
        let room = try XCTUnwrap(Self.adapt(capture).project.rooms.first)
        let converter = RoomPlanCoordinateConverter()
        func faceEnds(_ s: CapturedSurfaceSnapshot) -> [Point2D] {
            let c = converter.planPointMM(from: s.transform), d = converter.planDirection(from: s.transform)
            let half = converter.millimetres(fromMetres: s.dimensions.x) / 2
            return [c - d * half, c + d * half]
        }
        let surfaces = capture.rooms[0].surfaces.filter { $0.category == .wall }
        var joined = 0
        for (i, a) in surfaces.enumerated() {
            for b in surfaces[(i + 1)...] {
                guard let wa = room.walls.first(where: { $0.sourceRoomPlanID == a.sourceRoomPlanID }),
                      let wb = room.walls.first(where: { $0.sourceRoomPlanID == b.sourceRoomPlanID }) else { continue }
                for (ka, pa) in faceEnds(a).enumerated() {
                    for (kb, pb) in faceEnds(b).enumerated() where (pa - pb).length < 10 {
                        let ea = ka == 0 ? wa.start : wa.end, eb = kb == 0 ? wb.start : wb.end
                        XCTAssertEqual((ea - eb).length, 0, accuracy: 1e-6, "corner \(a.sourceRoomPlanID) / \(b.sourceRoomPlanID)")
                        joined += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(joined, 15)
    }

    func testRegisteredSquareRoomHasTheScannedInteriorSize() throws {
        // A 4000 × 3000 interior scanned as faces must come out as a 4000 × 3000 clear interior,
        // not 3880 × 2880 as when faces were treated as centrelines.
        let interior = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 0)
        var surfaces: [CapturedSurfaceSnapshot] = []
        for wall in interior.rooms[0].walls.reversed() {
            // RoomPlan walks rooms clockwise so the right-hand normal (+Z) faces the room.
            let reversedAngle = wall.angleRadians + .pi
            let center = wall.center
            surfaces.append(CapturedSurfaceSnapshot(
                sourceRoomPlanID: UUID(), parentIdentifier: nil, category: .wall,
                transform: .wallTransform(centerX: center.x / 1_000, centerY: 1.3, centerZ: -center.y / 1_000, planAngleRadians: reversedAngle),
                dimensions: Dimensions3D(x: wall.length / 1_000, y: 2.6, z: 0), confidence: .high))
        }
        let project = Self.adapt(StructureCaptureSnapshot(room: RoomCaptureSnapshot(sourceRoomPlanID: UUID(), surfaces: surfaces))).project
        let room = project.rooms[0]
        let topology = StructureTopologyEngine(configuration: .init(endpointSnapToleranceMM: GeometryTolerances.coincidenceMM)).generate(from: project)
        let centerline = try XCTUnwrap(topology.roomBoundaries.first { $0.isClosed }).polygon
        XCTAssertEqual(PlanPolygon.area(centerline), 4_120 * 3_120, accuracy: 1e-3)
        let faces = try XCTUnwrap(RoomFaceBoundary(room: room, centerline: centerline))
        XCTAssertEqual(faces.netArea, 4_000 * 3_000, accuracy: 1e-3)
    }
}
