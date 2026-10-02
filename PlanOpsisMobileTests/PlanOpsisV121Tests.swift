import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// v12.1 stabilisation regressions.
final class PlanOpsisV121Tests: XCTestCase {
    // MARK: Fixtures

    static func straightWallWithDoor() -> (PlanOpsisProject, wallID: UUID, doorID: UUID) {
        let wall = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 200)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(
            hostWallID: wall.id, offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0)))
        return (PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door])]), wall.id, door.id)
    }

    static func worldCenter(of openingID: UUID, in project: PlanOpsisProject) -> Point2D? {
        for room in project.rooms {
            guard let opening = room.openings.first(where: { $0.id == openingID }),
                  let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { continue }
            return wall.start + wall.direction * opening.parameters.offsetAlongWall
        }
        return nil
    }

    // MARK: TASK-002 hosted openings keep their position when a wall start moves

    func testStartEndpointMoveKeepsDoorWorldPosition() throws {
        let (project, wallID, doorID) = Self.straightWallWithDoor()
        let result = try PlanEditingConstraintEngine().moveEndpoint(
            wallID: wallID, endpoint: .start, proposed: Point2D(x: -300, y: 0),
            in: project, roomID: nil, settings: PlanEditingSettings(), applyConstraints: false)
        let center = try XCTUnwrap(Self.worldCenter(of: doorID, in: result.project))
        XCTAssertEqual(center.x, 1_000, accuracy: 1e-6)
        XCTAssertEqual(center.y, 0, accuracy: 1e-6)
        XCTAssertEqual(result.project.rooms[0].openings[0].parameters.offsetAlongWall, 1_300, accuracy: 1e-6)
    }

    func testStartEndpointMovePastDoorIsRejected() {
        let (project, wallID, doorID) = Self.straightWallWithDoor()
        XCTAssertThrowsError(try PlanEditingConstraintEngine().moveEndpoint(
            wallID: wallID, endpoint: .start, proposed: Point2D(x: 1_200, y: 0),
            in: project, roomID: nil, settings: PlanEditingSettings(), applyConstraints: false)) { error in
            XCTAssertEqual(error as? WallEndpointEditError, .openingWouldNotFit(openingID: doorID, hostWallID: wallID))
        }
    }

    func testEndEndpointMoveKeepsOffsetFromStart() throws {
        let (project, wallID, _) = Self.straightWallWithDoor()
        let result = try PlanEditingConstraintEngine().moveEndpoint(
            wallID: wallID, endpoint: .end, proposed: Point2D(x: 5_000, y: 0),
            in: project, roomID: nil, settings: PlanEditingSettings(), applyConstraints: false)
        XCTAssertEqual(result.project.rooms[0].openings, project.rooms[0].openings)
    }

    func testPropagatedJunctionMoveKeepsDoorsOnBothWalls() throws {
        let project = GoldenExchangeTests.project()
        let room = project.rooms[0]
        // Wall 10 starts at the corner shared with wall 13's end; wall 10 hosts a door.
        let wall10 = try XCTUnwrap(room.walls.first { $0.start == Point2D(x: -5_000, y: -3_000) })
        let doorID = try XCTUnwrap(room.openings.first { $0.parameters.hostWallID == wall10.id }?.id)
        let before = try XCTUnwrap(Self.worldCenter(of: doorID, in: project))
        let result = try PlanEditingConstraintEngine().moveEndpoint(
            wallID: wall10.id, endpoint: .start, proposed: Point2D(x: -5_250, y: -3_000),
            in: project, roomID: room.id, settings: PlanEditingSettings(), applyConstraints: false)
        XCTAssertEqual(result.move.propagatedEndpointIDs.count, 1)
        let after = try XCTUnwrap(Self.worldCenter(of: doorID, in: result.project))
        XCTAssertEqual((after - before).length, 0, accuracy: 1e-6)
    }

    func testMeasuredCorrectionAnchoredAtEndKeepsDoorWorldPosition() throws {
        var project = GoldenExchangeTests.project()
        let room = project.rooms[0]
        let wall10 = try XCTUnwrap(room.walls.first { $0.start == Point2D(x: -5_000, y: -3_000) })
        let doorID = try XCTUnwrap(room.openings.first { $0.parameters.hostWallID == wall10.id }?.id)
        let before = try XCTUnwrap(Self.worldCenter(of: doorID, in: project))
        let observation = SurveyObservation(target: .wallLength(roomID: room.id, wallID: wall10.id), observedMM: 12_300)
        project.survey.observations = [observation]
        let engine = SurveyCorrectionEngine()
        let proposal = engine.preview(observationID: observation.id, anchor: .end, project: project)
        XCTAssertTrue(proposal.canApply, proposal.issues.joined(separator: ";"))
        let corrected = try engine.apply(proposal, to: project)
        let after = try XCTUnwrap(Self.worldCenter(of: doorID, in: corrected))
        XCTAssertEqual((after - before).length, 0, accuracy: 1e-6)
    }

    // MARK: TASK-003 RoomPlan vertical datum

    final class SequentialUUIDs: @unchecked Sendable {
        private var next = 0
        func make() -> UUID {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
        }
    }

    static func adapter() -> RoomPlanAdapter {
        let ids = SequentialUUIDs()
        return RoomPlanAdapter(configuration: .init(uuidProvider: ids.make))
    }

    static func shifted(_ snapshot: RoomCaptureSnapshot, byMetres dy: Double) -> RoomCaptureSnapshot {
        var shifted = snapshot
        for index in shifted.surfaces.indices { shifted.surfaces[index].transform.values[13] += dy }
        return shifted
    }

    func testCaptureSpaceFloorOffsetDoesNotChangeSemanticElevations() throws {
        let mock = MockRoomCaptureProvider().snapshot()
        let reference = Self.adapter().adapt(mock)
        // ARKit world Y=0 is the device start height, so a real floor sits around -1.4 m.
        let captured = Self.adapter().adapt(Self.shifted(mock, byMetres: -1.4))
        let a = try XCTUnwrap(reference.project.rooms.first), b = try XCTUnwrap(captured.project.rooms.first)
        XCTAssertEqual(b.captureFloorElevationMM ?? .nan, -1_400, accuracy: 1e-6)
        XCTAssertEqual(a.walls, b.walls)
        XCTAssertEqual(a.openings.count, b.openings.count)
        for (x, y) in zip(a.openings, b.openings) {
            XCTAssertEqual(x.parameters.sillHeight, y.parameters.sillHeight, accuracy: 1e-6)
            XCTAssertEqual(x.parameters.height, y.parameters.height, accuracy: 1e-9)
        }
        XCTAssertEqual(reference.diagnostics, captured.diagnostics)
        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: captured.project, captureDiagnostics: captured.diagnostics)
        XCTAssertFalse(readiness.issues.contains { $0.code == .openingOutsideHost }, readiness.issues.map(\.message).joined(separator: ";"))
    }

    func testOpeningSlightlyBelowFloorRestsOnFloorWithoutDiagnostic() throws {
        var mock = Self.shifted(MockRoomCaptureProvider().snapshot(), byMetres: -1.4)
        let doorIndex = try XCTUnwrap(mock.surfaces.firstIndex { $0.category == .door })
        mock.surfaces[doorIndex].transform.values[13] -= 0.010
        let result = Self.adapter().adapt(mock)
        let door = try XCTUnwrap(result.project.rooms[0].openings.first { $0.kind == .door })
        XCTAssertEqual(door.parameters.sillHeight, 0)
        XCTAssertFalse(result.diagnostics.contains { if case .openingVerticalExtentOutsideHost = $0 { return true }; return false })

        mock.surfaces[doorIndex].transform.values[13] -= 0.070
        let deeper = Self.adapter().adapt(mock)
        XCTAssertEqual(try XCTUnwrap(deeper.project.rooms[0].openings.first { $0.kind == .door }).parameters.sillHeight, 0)
        XCTAssertTrue(deeper.diagnostics.contains { if case .openingVerticalExtentOutsideHost = $0 { return true }; return false })
    }

    // MARK: TASK-004 RoomPlan opening overhang policy

    func testPartiallyOverhangingDoorIsClampedAndExportable() throws {
        var mock = MockRoomCaptureProvider().snapshot()
        let doorIndex = try XCTUnwrap(mock.surfaces.firstIndex { $0.category == .door })
        // Host wall runs x = 0…4 m; a 0.9 m door centred 0.1 m from its start overhangs by 0.35 m.
        mock.surfaces[doorIndex].transform = .wallTransform(centerX: 0.1, centerY: 1.05, centerZ: 0, planAngleRadians: 0)
        let result = Self.adapter().adapt(mock)
        let door = try XCTUnwrap(result.project.rooms[0].openings.first { $0.kind == .door })
        XCTAssertEqual(door.parameters.offsetAlongWall - door.parameters.width / 2, 0, accuracy: 1e-6)
        XCTAssertEqual(door.parameters.offsetAlongWall + door.parameters.width / 2, 550, accuracy: 1e-6)
        XCTAssertTrue(result.diagnostics.contains { if case .openingExtendsBeyondHost = $0 { return true }; return false })

        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: result.project, captureDiagnostics: result.diagnostics)
        XCTAssertEqual(readiness.errorCount, 0, readiness.issues.map(\.message).joined(separator: ";"))
        XCTAssertTrue(DXFExchangeEngine().exportValidated(project: result.project).canWrite)
        XCTAssertTrue(IFC4ExchangeEngine().exportValidated(project: result.project).canWrite)
    }

    func testDoorMostlyOffItsWallIsNotImported() throws {
        var mock = MockRoomCaptureProvider().snapshot()
        let doorIndex = try XCTUnwrap(mock.surfaces.firstIndex { $0.category == .door })
        // Only 0.3 m of the 0.9 m door lies on the wall.
        mock.surfaces[doorIndex].transform = .wallTransform(centerX: -0.15, centerY: 1.05, centerZ: 0, planAngleRadians: 0)
        let result = Self.adapter().adapt(mock)
        XCTAssertFalse(result.project.rooms[0].openings.contains { $0.kind == .door })
        XCTAssertTrue(result.diagnostics.contains { if case .openingMostlyOutsideHost = $0 { return true }; return false })
    }
}
