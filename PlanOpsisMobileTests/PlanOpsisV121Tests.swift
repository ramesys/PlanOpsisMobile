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
}
