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

    // MARK: 4. Irregular walls are imported, so real scans export

    func testRealCaptureImportsEveryWallAndExports() throws {
        let capture = try RealCaptureFixtures.apartment1()
        let result = Self.adapt(capture)
        let room = try XCTUnwrap(result.project.rooms.first)
        XCTAssertEqual(room.walls.count, capture.rooms[0].surfaces.filter { $0.category == .wall }.count, "the non-rectangular wall is imported")
        XCTAssertTrue(result.diagnostics.contains { if case .unsupportedComplexWall = $0 { return true }; return false })
        XCTAssertEqual(room.openings.count, 3)
        XCTAssertEqual(room.captureFloorElevationMM ?? .nan, -1_617, accuracy: 1)
        let door = try XCTUnwrap(room.openings.first { $0.kind == .door })
        let window = try XCTUnwrap(room.openings.first { $0.kind == .window })
        XCTAssertEqual(door.parameters.sillHeight, 0, accuracy: 1)
        XCTAssertEqual(window.parameters.sillHeight, 439, accuracy: 1)

        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: result.project, captureDiagnostics: result.diagnostics)
        XCTAssertEqual(readiness.errorCount, 0, readiness.issues.map(\.message).joined(separator: "; "))
        XCTAssertTrue(readiness.canExportDXF)
        XCTAssertTrue(DXFExchangeEngine().exportValidated(project: result.project, representation: .semanticObservations).canWrite)
        XCTAssertTrue(IFC4ExchangeEngine().exportValidated(project: result.project).canWrite)
    }

    // MARK: 2. Face-based survey measurements

    func testFaceLengthsAtSquareCornersAndRoomSide() throws {
        let project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 200)
        let room = project.rooms[0]
        let bottom = try XCTUnwrap(room.walls.first { $0.start == .zero })
        let engine = SurveyMeasurementEngine()
        let inside = try XCTUnwrap(engine.roomSide(ofWall: bottom.id, in: room))
        XCTAssertEqual(inside, 1, "the room lies on the +normal side of a counter-clockwise loop")
        let (a, b) = try engine.faceSegment(wallID: bottom.id, side: inside, in: room)
        XCTAssertEqual((b - a).length, 3_800, accuracy: 1e-9)
        XCTAssertEqual(a.x, 100, accuracy: 1e-9); XCTAssertEqual(a.y, 100, accuracy: 1e-9)
        let (c, d) = try engine.faceSegment(wallID: bottom.id, side: -inside, in: room)
        XCTAssertEqual((d - c).length, 4_200, accuracy: 1e-9)
        // Every wall's inside face agrees with the clear interior used for drawings and IFC.
        for wall in room.walls {
            let side = try XCTUnwrap(engine.roomSide(ofWall: wall.id, in: room))
            let (p, q) = try engine.faceSegment(wallID: wall.id, side: side, in: room)
            XCTAssertEqual((q - p).length, wall.length - 200, accuracy: 1e-9)
        }
    }

    func testFaceStopsAtThroughWallAtTJunction() throws {
        var project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 200)
        // A 100 mm partition from the bottom wall's axis up to the top wall's axis at x = 2000.
        let partition = PlanOpsisWall(start: Point2D(x: 2_000, y: 0), length: 3_000, angleRadians: .pi / 2, height: 2_700, thickness: 100)
        project.rooms[0].walls.append(partition)
        let (a, b) = try SurveyMeasurementEngine().faceSegment(wallID: partition.id, side: 1, in: project.rooms[0])
        XCTAssertEqual(a.y, 100, accuracy: 1e-9)
        XCTAssertEqual(b.y, 2_900, accuracy: 1e-9)
        XCTAssertEqual((b - a).length, 2_800, accuracy: 1e-9)
    }

    func testFaceLengthMeasurementCorrectsTheAxis() throws {
        var project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 200)
        let room = project.rooms[0]
        let bottom = try XCTUnwrap(room.walls.first { $0.start == .zero })
        let target = SurveyMeasurementTarget.wallFaceLength(roomID: room.id, wallID: bottom.id, side: 1)
        XCTAssertNoThrow(try SurveyValidation.validate(target, in: project))
        XCTAssertThrowsError(try SurveyValidation.validate(.wallFaceLength(roomID: room.id, wallID: bottom.id, side: 0), in: project))
        let observation = SurveyObservation(target: target, observedMM: 3_900, toleranceMM: 2)
        project.survey.observations = [observation]
        XCTAssertEqual(SurveyMeasurementEngine().evaluate(observation, in: project).residualMM ?? .nan, -100, accuracy: 1e-9)

        let engine = SurveyCorrectionEngine()
        let proposal = engine.preview(observationID: observation.id, anchor: .start, project: project)
        XCTAssertTrue(proposal.canApply, proposal.issues.joined(separator: ";"))
        let corrected = try engine.apply(proposal, to: project)
        XCTAssertEqual(SurveyMeasurementEngine().evaluate(observation, in: corrected).residualMM ?? .nan, 0, accuracy: 1e-6)
        // The corner moved ~100 mm, so the connected wall now leans slightly and the axis needs a little more.
        XCTAssertEqual(try XCTUnwrap(corrected.rooms[0].walls.first { $0.id == bottom.id }).length, 4_100, accuracy: 10)

        // The new target persists and reloads.
        let data = try JSONEncoder().encode(corrected)
        XCTAssertEqual(try ProjectMigrator().decode(data), corrected)
    }

    // MARK: 3. Project library

    func testLibraryKeepsEveryProjectAndListsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v122-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ProjectLibrary(directory: root.appendingPathComponent("Projects"))
        XCTAssertEqual(library.entries(), [])

        var first = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 200)
        first.name = "Flat 2, kitchen"
        var second = GoldenExchangeTests.project()
        second.survey.roomNames[second.rooms[0].id] = "Living room"
        try library.save(first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: library.url(for: first.id).path)
        try library.save(second)

        let entries = library.entries()
        XCTAssertEqual(entries.map(\.id), [second.id, first.id])
        XCTAssertEqual(entries.map(\.name), ["Living room", "Flat 2, kitchen"])
        XCTAssertEqual(try library.load(first.id), first)
        XCTAssertEqual(try library.load(second.id), second)

        // Saving again updates in place; other projects are untouched.
        first.name = "Flat 2"
        try library.save(first)
        XCTAssertEqual(library.entries().count, 2)
        XCTAssertEqual(try library.load(first.id).name, "Flat 2")

        // Unreadable files are skipped, not deleted.
        let junk = library.directory.appendingPathComponent("\(UUID().uuidString).planopsis.json")
        try Data("not json".utf8).write(to: junk)
        XCTAssertEqual(library.entries().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: junk.path))

        try library.delete(second.id)
        XCTAssertEqual(library.entries().map(\.id), [first.id])
        XCTAssertEqual(PlanOpsisProject(rooms: []).displayName, "Untitled project")
    }

    func testLegacySingleSlotProjectIsImportedOnceAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v122-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = ProjectStore(url: root.appendingPathComponent("project-v2.json"))
        let library = ProjectLibrary(directory: root.appendingPathComponent("Projects"))
        XCTAssertNil(try library.importLegacy(from: legacy), "no legacy file, nothing to import")

        let project = GoldenExchangeTests.project()
        try legacy.save(project)
        XCTAssertEqual(try library.importLegacy(from: legacy), project.id)
        XCTAssertNil(try library.importLegacy(from: legacy), "imported once")
        XCTAssertEqual(try library.load(project.id), project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.url.path), "the legacy file is kept")
    }
}
