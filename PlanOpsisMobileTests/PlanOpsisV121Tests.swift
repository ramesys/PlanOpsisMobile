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

    // MARK: TASK-005 single tolerance table and exact junctions

    /// 4000 × 3000 room whose corners are each off by up to 80 mm, with a door on the first wall.
    static func gappedRoom() -> (PlanOpsisProject, doorID: UUID) {
        let corners = [Point2D(x: 0, y: 0), Point2D(x: 4_000, y: 0), Point2D(x: 4_000, y: 3_000), Point2D(x: 0, y: 3_000)]
        let startError = [Point2D(x: 40, y: -30), Point2D(x: -55, y: 20), Point2D(x: 10, y: 60), Point2D(x: -25, y: -70)]
        let endError = [Point2D(x: -60, y: 15), Point2D(x: 35, y: -45), Point2D(x: -20, y: -50), Point2D(x: 70, y: 25)]
        let walls = corners.indices.map { i -> PlanOpsisWall in
            let a = corners[i] + startError[i], b = corners[(i + 1) % 4] + endError[i], v = b - a
            return PlanOpsisWall(start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: 2_700, thickness: 150)
        }
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(
            hostWallID: walls[0].id, offsetAlongWall: 1_500, width: 900, height: 2_100, sillHeight: 0)))
        return (PlanOpsisProject(rooms: [PlanOpsisRoom(walls: walls, openings: [door])]), door.id)
    }

    func testNormalizerMakesJunctionsExactlyCoincident() throws {
        let (project, doorID) = Self.gappedRoom()
        let strict = StructureTopologyEngine(configuration: .init(endpointSnapToleranceMM: GeometryTolerances.coincidenceMM))
        XCTAssertFalse(try XCTUnwrap(strict.generate(from: project).roomBoundaries.first).isClosed)

        let result = JunctionNormalizer().normalize(project)
        XCTAssertEqual(result.movedEndpointCount, 8)
        XCTAssertTrue(result.skippedRoomIDs.isEmpty)
        let walls = result.project.rooms[0].walls
        for (index, wall) in walls.enumerated() {
            XCTAssertEqual((wall.end - walls[(index + 1) % 4].start).length, 0, accuracy: 1e-6)
        }
        XCTAssertTrue(try XCTUnwrap(strict.generate(from: result.project).roomBoundaries.first).isClosed)

        // The door keeps its world station along its (slightly moved) host wall.
        let before = try XCTUnwrap(Self.worldCenter(of: doorID, in: project))
        let after = try XCTUnwrap(Self.worldCenter(of: doorID, in: result.project))
        XCTAssertEqual((after - before).dot(walls[0].direction), 0, accuracy: 1e-6)
        XCTAssertEqual(ExchangeGeometryValidation.errors(in: result.project), [])
    }

    func testNormalizerIsIdempotentAndLeavesUnfittableRoomsUnchanged() throws {
        let normalized = JunctionNormalizer().normalize(Self.gappedRoom().0).project
        XCTAssertEqual(JunctionNormalizer().normalize(normalized).movedEndpointCount, 0)

        var tight = Self.gappedRoom().0
        // A door filling its whole wall cannot survive the corner moving inwards.
        tight.rooms[0].openings[0].parameters.width = tight.rooms[0].walls[0].length
        tight.rooms[0].openings[0].parameters.offsetAlongWall = tight.rooms[0].walls[0].length / 2
        let result = JunctionNormalizer().normalize(tight)
        XCTAssertEqual(result.skippedRoomIDs, [tight.rooms[0].id])
        XCTAssertEqual(result.project, tight)
    }

    func testRoomPlanImportClosesNearlyMeetingWalls() throws {
        var mock = MockRoomCaptureProvider().snapshot()
        let wallIndex = try XCTUnwrap(mock.surfaces.firstIndex { $0.category == .wall })
        mock.surfaces[wallIndex].dimensions.x -= 0.12 // 60 mm short at both corners
        let strict = StructureTopologyEngine(configuration: .init(endpointSnapToleranceMM: GeometryTolerances.coincidenceMM))

        let raw = RoomPlanAdapter(configuration: .init(normalizeJunctions: false)).adapt(mock)
        XCTAssertFalse(try XCTUnwrap(strict.generate(from: raw.project).roomBoundaries.first).isClosed)
        let imported = RoomPlanAdapter().adapt(mock)
        XCTAssertTrue(try XCTUnwrap(strict.generate(from: imported.project).roomBoundaries.first).isClosed)
    }

    // MARK: TASK-006 survey-aware delete

    static func measuredWallProject() -> (PlanOpsisProject, wallID: UUID, observationIDs: [UUID]) {
        var project = GoldenExchangeTests.project()
        let room = project.rooms[0]
        let wall = room.walls.first { $0.start == Point2D(x: -5_000, y: -3_000) }!
        let door = room.openings.first { $0.parameters.hostWallID == wall.id }!
        let length = SurveyObservation(target: .wallLength(roomID: room.id, wallID: wall.id), observedMM: 12_000, toleranceMM: 5)
        // A check measured from another wall to this wall's door edge also depends on the deleted wall.
        let other = room.walls.first { $0.id != wall.id }!
        let edge = SurveyObservation(target: .distance(
            from: SurveyPoint(roomID: room.id, wallID: other.id, location: .start),
            to: SurveyPoint(roomID: room.id, wallID: wall.id, location: .openingEdge(openingID: door.id, side: -1))), observedMM: 3_000)
        project.survey.observations = [length, edge]
        project.survey.dimensions = [SurveyDimensionDefinition(target: .wallLength(roomID: room.id, wallID: wall.id), offsetMM: 600)]
        let hash = String(repeating: "a", count: 64)
        project.survey.evidence = [SurveyEvidenceReference(id: UUID(), projectID: project.id, relativePath: "assets/\(project.id.uuidString)/\(hash).asset",
                                                           sha256: hash, sourceName: "wall.jpg", kind: .photo, entityID: wall.id)]
        return (project, wall.id, [length.id, edge.id])
    }

    func testDeletingMeasuredWallRemovesItsSurveyReferences() throws {
        let (project, wallID, observationIDs) = Self.measuredWallProject()
        let result = try XCTUnwrap(SemanticObjectEditingEngine().deleteReportingSurveyConflicts(entityIDs: [wallID], from: project))
        XCTAssertNoThrow(try SurveyValidation.validate(result.project))
        XCTAssertEqual(Set(result.removedObservationIDs), Set(observationIDs))
        XCTAssertEqual(result.removedDimensionIDs, project.survey.dimensions.map(\.id))
        XCTAssertTrue(result.project.survey.observations.isEmpty)
        XCTAssertTrue(result.project.survey.dimensions.isEmpty)
        XCTAssertEqual(result.project.survey.evidence.count, 1)
        XCTAssertNil(result.project.survey.evidence[0].entityID)
        XCTAssertEqual(result.unlinkedEvidenceIDs, [project.survey.evidence[0].id])

        var history = PlanOpsisEditHistory()
        history.record(EditorHistorySnapshot(project: project), label: "Delete")
        XCTAssertEqual(history.undo(current: EditorHistorySnapshot(project: result.project))?.project, project)
    }

    func testLockedMeasurementBlocksDeleteWithExplanation() throws {
        var (project, wallID, observationIDs) = Self.measuredWallProject()
        project.survey.observations[0].locked = true
        XCTAssertThrowsError(try SemanticObjectEditingEngine().deleteReportingSurveyConflicts(entityIDs: [wallID], from: project)) { error in
            XCTAssertEqual(error as? SemanticDeleteError, .lockedMeasurements([observationIDs[0]]))
            XCTAssertTrue(error.localizedDescription.contains("Unlock"))
        }
        XCTAssertNil(SemanticObjectEditingEngine().delete(entityID: wallID, from: project))
    }

    // MARK: TASK-007 retained capture evidence

    func testRetainedCaptureReplaysToTheSameModelAfterSaveAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v121-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = SurveyAttachmentStore(root: root)
        let capture = StructureCaptureSnapshot(room: Self.shifted(MockRoomCaptureProvider().snapshot(), byMetres: -1.4))
        XCTAssertEqual(try CaptureEvidence.encode(capture), try CaptureEvidence.encode(capture))

        var project = Self.adapter().adapt(capture).project
        project.survey.evidence.append(try CaptureEvidence.retain(capture, projectID: project.id, in: attachments))
        let store = ProjectStore(url: root.appendingPathComponent("project-v2.json"))
        try store.save(project)
        let reopened = try store.load()
        XCTAssertEqual(reopened, project)

        XCTAssertEqual(try CaptureEvidence.latestCapture(of: reopened, in: attachments), capture)
        let replayed = try XCTUnwrap(CaptureEvidence.replay(reopened, in: attachments, adapter: Self.adapter()))
        XCTAssertEqual(replayed.project.rooms, project.rooms)
    }

    func testDeliveryPackageCarriesRetainedCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v121-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = SurveyAttachmentStore(root: root.appendingPathComponent("source"))
        let capture = StructureCaptureSnapshot(room: MockRoomCaptureProvider().snapshot())
        var project = Self.adapter().adapt(capture).project
        let reference = try CaptureEvidence.retain(capture, projectID: project.id, in: attachments)
        project.survey.evidence.append(reference)
        let destination = root.appendingPathComponent("delivery")
        let manifest = try SurveyDeliveryWriter().write(project: project, attachmentStore: attachments, destination: destination)
        XCTAssertTrue(manifest.files.contains { $0.path == reference.relativePath && $0.sha256 == reference.sha256 })
        let delivered = try SurveyDeliveryReader().read(root: destination)
        XCTAssertEqual(try CaptureEvidence.latestCapture(of: delivered, in: SurveyAttachmentStore(root: destination)), capture)
    }

    // MARK: TASK-008 single-pass derivation

    func testDerivationMatchesIndependentlyComputedOutputs() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        for representation in GeometryRepresentationMode.allCases {
            for focus in [nil] + project.rooms.map(\.id) as [UUID?] {
                for openingWidths in [false, true] {
                    let settings = ProjectDerivation.Settings(representation: representation, focusedRoomID: focus, includeOpeningDimensions: openingWidths)
                    let derived = ProjectDerivation(project: project, settings: settings)
                    let engine = DXFExchangeEngine(includeOpeningDimensions: openingWidths)
                    XCTAssertEqual(derived.semanticGeometry, ParametricGeometryEngine().generate(from: project))
                    XCTAssertEqual(derived.drawing, engine.preview(for: project, representation: representation))
                    let expected = engine.annotations(for: project, focusedRoomID: focus, representation: representation)
                    XCTAssertEqual(derived.annotations, expected, "\(representation) focus \(String(describing: focus))")
                    XCTAssertEqual(derived.readiness, ArchitecturalSurveyReadinessEngine().evaluate(project: project))
                }
            }
        }
    }

    func testDerivationReusesGeometryOnlyForTheSameProject() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let first = ProjectDerivation(project: project)
        let refocused = ProjectDerivation(project: project, settings: .init(focusedRoomID: project.rooms[0].id), reusing: first)
        XCTAssertEqual(refocused.semanticGeometry, first.semanticGeometry)

        var edited = project
        edited.rooms[0].walls[0].editThickness(300)
        let rebuilt = ProjectDerivation(project: edited, reusing: first)
        XCTAssertEqual(rebuilt.semanticGeometry, ParametricGeometryEngine().generate(from: edited))
        XCTAssertNotEqual(rebuilt.semanticGeometry, first.semanticGeometry)
    }

    /// Physical passage jambs collected host wall IDs through a Set, so identical projects produced
    /// differently ordered drawings (DXF files were unaffected: XDATA is sorted on write).
    func testReconciledDrawingIsDeterministicForRandomIdentities() {
        for _ in 0..<20 {
            let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
            XCTAssertEqual(DXFExchangeEngine().preview(for: project, representation: .reconciledPhysical),
                           DXFExchangeEngine().preview(for: project, representation: .reconciledPhysical))
        }
    }
}
