import XCTest
#if canImport(PlanOpsisCore)
import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class PlanOpsisMobileTests: XCTestCase {
    func testCoordinateConverterCentralizesMetresToMillimetresAndXZPlanMapping() {
        let converter = RoomPlanCoordinateConverter()
        let transform = TransformSnapshot.wallTransform(
            centerX: 1.25,
            centerY: 1.4,
            centerZ: -2.5,
            planAngleRadians: .pi / 2
        )
        let point = converter.planPointMM(from: transform)
        let direction = converter.planDirection(from: transform)
        XCTAssertEqual(point.x, 1_250, accuracy: 1e-8)
        XCTAssertEqual(point.y, 2_500, accuracy: 1e-8)
        XCTAssertEqual(direction.x, 0, accuracy: 1e-8)
        XCTAssertEqual(direction.y, 1, accuracy: 1e-8)
    }

    func testAdapterImportsRequestedSemanticStructureAndUnits() throws {
        let snapshot = MockRoomCaptureProvider().snapshot()
        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)

        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(room.walls.count, 4)
        XCTAssertEqual(room.openings.filter { $0.kind == .door }.count, 1)
        XCTAssertEqual(room.openings.filter { $0.kind == .window }.count, 2)
        XCTAssertEqual(room.openings.filter { $0.kind == .opening }.count, 1)
        XCTAssertEqual(room.walls[0].length, 4_000, accuracy: 1e-8)
        XCTAssertEqual(room.walls[0].height, 2_800, accuracy: 1e-8)
        XCTAssertEqual(room.walls[0].thickness, 120, accuracy: 1e-8)
    }

    func testParentIdentifierResolvesToPlanOpsisHostWallID() throws {
        let snapshot = MockRoomCaptureProvider().snapshot()
        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)
        let doorSnapshot = try XCTUnwrap(snapshot.surfaces.first { $0.category == .door })
        let sourceHostID = try XCTUnwrap(doorSnapshot.parentIdentifier)
        let semanticHost = try XCTUnwrap(room.walls.first { $0.sourceRoomPlanID == sourceHostID })
        let semanticDoor = try XCTUnwrap(room.openings.first { $0.kind == .door })
        XCTAssertEqual(semanticDoor.parameters.hostWallID, semanticHost.id)
    }

    func testPlanOpsisUUIDsDifferFromRoomPlanProvenance() throws {
        let result = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot())
        let room = try XCTUnwrap(result.project.rooms.first)
        XCTAssertNotEqual(room.id, room.sourceRoomPlanID)
        for wall in room.walls {
            XCTAssertNotEqual(wall.id, wall.sourceRoomPlanID)
        }
        for opening in room.openings {
            XCTAssertNotEqual(opening.id, opening.parameters.sourceRoomPlanID)
        }
    }

    func testWallCanonicalEditingRules() {
        var wall = PlanOpsisWall(
            start: Point2D(x: 0, y: 0),
            length: 1_000,
            angleRadians: 0,
            height: 2_800,
            thickness: 100
        )

        wall.editLength(2_000)
        XCTAssertEqual(wall.end.x, 2_000, accuracy: 1e-8)
        XCTAssertEqual(wall.end.y, 0, accuracy: 1e-8)

        wall.editAngleRadians(.pi / 2)
        XCTAssertEqual(wall.end.x, 0, accuracy: 1e-7)
        XCTAssertEqual(wall.end.y, 2_000, accuracy: 1e-7)

        wall.editEnd(Point2D(x: 3_000, y: 4_000))
        XCTAssertEqual(wall.length, 5_000, accuracy: 1e-8)
        XCTAssertEqual(wall.angleRadians, atan2(4_000.0, 3_000.0), accuracy: 1e-8)

        let oldFootprint = wall.footprint
        wall.editThickness(240)
        XCTAssertNotEqual(oldFootprint, wall.footprint)
    }

    func testGeometryIsDeterministicAndCarriesSemanticIDs() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let engine = ParametricGeometryEngine()
        let first = engine.generate(from: project)
        let second = engine.generate(from: project)
        XCTAssertEqual(first, second)

        let room = try XCTUnwrap(project.rooms.first)
        let wallIDs = Set(room.walls.map(\.id))
        XCTAssertFalse(first.planWallSegments.isEmpty)
        XCTAssertTrue(first.planWallSegments.allSatisfy { wallIDs.contains($0.hostWallID) })
        XCTAssertTrue(first.wallSolids.allSatisfy { wallIDs.contains($0.hostWallID) })
        XCTAssertEqual(Set(first.hostedOpenings.map(\.id)), Set(room.openings.map(\.id)))
    }

    func testHostedOpeningFollowsEditedWall() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let roomIndex = 0
        let opening = try XCTUnwrap(project.rooms[roomIndex].openings.first)
        let hostID = opening.parameters.hostWallID
        let wallIndex = try XCTUnwrap(project.rooms[roomIndex].walls.firstIndex { $0.id == hostID })
        let engine = ParametricGeometryEngine()
        let before = try XCTUnwrap(engine.generate(from: project).hostedOpenings.first { $0.id == opening.id })

        project.rooms[roomIndex].walls[wallIndex].editAngleRadians(project.rooms[roomIndex].walls[wallIndex].angleRadians + .pi / 4)
        let after = try XCTUnwrap(engine.generate(from: project).hostedOpenings.first { $0.id == opening.id })
        XCTAssertNotEqual(before.center, after.center)
        XCTAssertEqual(after.hostWallID, hostID)
    }

    func testPersistencePreservesUUIDsParametersRelationshipsAndGeometry() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let geometryBefore = ParametricGeometryEngine().generate(from: project)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(url: url)

        try store.save(project)
        let reopened = try store.load()
        let geometryAfter = ParametricGeometryEngine().generate(from: reopened)

        XCTAssertEqual(project, reopened)
        XCTAssertEqual(geometryBefore, geometryAfter)
    }

    func testEquivalentNormalizedSnapshotsUseSameAdapterPathWithoutClaimingRealCapture() throws {
        let mock = MockRoomCaptureProvider().snapshot()
        let provenanceRemappedEquivalent = remapProvenance(mock)

        let mockProject = RoomPlanAdapter().adapt(mock).project
        let equivalentProject = RoomPlanAdapter().adapt(provenanceRemappedEquivalent).project
        let mockRoom = try XCTUnwrap(mockProject.rooms.first)
        let equivalentRoom = try XCTUnwrap(equivalentProject.rooms.first)

        XCTAssertEqual(mockRoom.walls.count, equivalentRoom.walls.count)
        XCTAssertEqual(mockRoom.openings.count, equivalentRoom.openings.count)
        XCTAssertEqual(mockRoom.walls.map(\.length).sorted(), equivalentRoom.walls.map(\.length).sorted())
        XCTAssertEqual(mockRoom.walls.map(\.height).sorted(), equivalentRoom.walls.map(\.height).sorted())
        XCTAssertEqual(mockRoom.openings.map(\.kind).map(\.rawValue).sorted(), equivalentRoom.openings.map(\.kind).map(\.rawValue).sorted())
        XCTAssertEqual(hostedWallLengths(room: mockRoom), hostedWallLengths(room: equivalentRoom))
    }

    func testCurvedWallIsDiagnosedAndNotSilentlyLinearized() throws {
        var snapshot = MockRoomCaptureProvider().snapshot()
        snapshot.surfaces = [snapshot.surfaces[0]]
        snapshot.surfaces[0].shapeHints.hasCurve = true

        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)

        XCTAssertTrue(room.walls.isEmpty)
        XCTAssertTrue(result.diagnostics.contains {
            if case .unsupportedCurvedWall(surfaceSourceID: snapshot.surfaces[0].sourceRoomPlanID) = $0 { return true }
            return false
        })
    }

    func testComplexPolygonWallIsDiagnosedAndNotSilentlyLinearized() throws {
        var snapshot = MockRoomCaptureProvider().snapshot()
        snapshot.surfaces = [snapshot.surfaces[0]]
        snapshot.surfaces[0].shapeHints.polygonCornerCount = 6

        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)

        XCTAssertTrue(room.walls.isEmpty)
        XCTAssertTrue(result.diagnostics.contains {
            if case .unsupportedComplexWall(surfaceSourceID: snapshot.surfaces[0].sourceRoomPlanID, polygonCornerCount: 6) = $0 { return true }
            return false
        })
    }

    /// v12.1: an observation lying entirely off its host wall is diagnosed and not imported
    /// (it previously produced an unexportable opening). Partial overhangs: PlanOpsisV121Tests.
    func testOpeningOutsideHostIsDiagnosedAndNotImported() throws {
        var snapshot = MockRoomCaptureProvider().snapshot()
        let doorIndex = try XCTUnwrap(snapshot.surfaces.firstIndex { $0.category == .door })
        snapshot.surfaces[doorIndex].transform = .wallTransform(
            centerX: 5.0,
            centerY: 1.05,
            centerZ: 0,
            planAngleRadians: 0
        )

        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)
        XCTAssertEqual(room.openings.filter { $0.kind == .door }.count, 0)
        XCTAssertTrue(result.diagnostics.contains {
            if case .openingMostlyOutsideHost(surfaceSourceID: snapshot.surfaces[doorIndex].sourceRoomPlanID, hostWallID: _) = $0 { return true }
            return false
        })
    }

    func testMissingParentDoesNotCreateUnhostedOpening() throws {
        var snapshot = MockRoomCaptureProvider().snapshot()
        let doorIndex = try XCTUnwrap(snapshot.surfaces.firstIndex { $0.category == .door })
        snapshot.surfaces[doorIndex].parentIdentifier = UUID()

        let result = RoomPlanAdapter().adapt(snapshot)
        let room = try XCTUnwrap(result.project.rooms.first)
        XCTAssertEqual(room.openings.filter { $0.kind == .door }.count, 0)
        XCTAssertTrue(result.diagnostics.contains {
            if case .missingHost(surfaceSourceID: snapshot.surfaces[doorIndex].sourceRoomPlanID, parentSourceID: _) = $0 { return true }
            return false
        })
    }

    func testOverlappingOpeningsProduceVerticalComplementWithoutSolidInsideVoidUnion() {
        let wallID = UUID()
        let wall = PlanOpsisWall(
            id: wallID,
            start: .zero,
            length: 4_000,
            angleRadians: 0,
            height: 3_000,
            thickness: 120
        )
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(
            hostWallID: wallID,
            offsetAlongWall: 1_500,
            width: 2_000,
            height: 2_100,
            sillHeight: 0
        )))
        let window = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(
            hostWallID: wallID,
            offsetAlongWall: 2_000,
            width: 2_000,
            height: 1_000,
            sillHeight: 1_000
        )))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door, window])])
        let geometry = ParametricGeometryEngine().generate(from: project)

        XCTAssertFalse(geometry.wallSolids.contains { solidContains($0, x: 1_500, y: 500) })
        XCTAssertFalse(geometry.wallSolids.contains { solidContains($0, x: 1_500, y: 1_500) })
        XCTAssertTrue(geometry.wallSolids.contains { solidContains($0, x: 1_500, y: 2_500) })
    }

    func testFloorBoundsComeFromCompleteWallFootprintEvenWhenOpeningConsumesEntireWall() throws {
        let wallID = UUID()
        let wall = PlanOpsisWall(
            id: wallID,
            start: .zero,
            length: 4_000,
            angleRadians: 0,
            height: 2_800,
            thickness: 120
        )
        let opening = PlanOpsisOpening.opening(HostedOpeningParameters(
            hostWallID: wallID,
            offsetAlongWall: 2_000,
            width: 4_000,
            height: 2_800,
            sillHeight: 0
        ))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [opening])])
        let geometry = ParametricGeometryEngine().generate(from: project)
        let floor = try XCTUnwrap(geometry.floor)

        XCTAssertTrue(geometry.planWallSegments.isEmpty)
        XCTAssertEqual(floor.width, 4_000, accuracy: 1e-8)
        XCTAssertEqual(floor.depth, 120, accuracy: 1e-8)
    }

    func testSchemaVersionMismatchIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = PlanOpsisProject(schemaVersion: 999, rooms: [])
        try JSONEncoder().encode(project).write(to: url)

        XCTAssertThrowsError(try ProjectStore(url: url).load())
    }


    func testMultiRoomAdapterCreatesIndependentSemanticRoomsInOneProject() throws {
        let snapshot = MockStructureCaptureProvider().snapshot()
        let result = RoomPlanAdapter().adapt(snapshot)

        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.project.rooms.count, 2)
        XCTAssertEqual(result.project.sourceStructureRoomPlanID, MockStructureCaptureProvider.structureSourceID)

        let room1 = result.project.rooms[0]
        let room2 = result.project.rooms[1]
        XCTAssertNotEqual(room1.id, room2.id)
        XCTAssertEqual(room1.sourceRoomPlanID, MockRoomCaptureProvider.roomSourceID)
        XCTAssertEqual(room2.sourceRoomPlanID, MockStructureCaptureProvider.room2SourceID)
        XCTAssertEqual(room1.walls.count, 4)
        XCTAssertEqual(room2.walls.count, 4)

        let allSemanticIDs =
            [result.project.id] +
            result.project.rooms.map(\.id) +
            result.project.rooms.flatMap { $0.walls.map(\.id) } +
            result.project.rooms.flatMap { $0.openings.map(\.id) }
        XCTAssertEqual(Set(allSemanticIDs).count, allSemanticIDs.count)

        let allSourceIDs =
            [MockStructureCaptureProvider.structureSourceID] +
            snapshot.rooms.map(\.sourceRoomPlanID) +
            snapshot.rooms.flatMap { $0.surfaces.map(\.sourceRoomPlanID) }
        XCTAssertTrue(Set(allSemanticIDs).isDisjoint(with: Set(allSourceIDs)))
    }

    func testMultiRoomHostedRelationshipsNeverCrossRoomBoundary() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project

        for room in project.rooms {
            let wallIDs = Set(room.walls.map(\.id))
            XCTAssertFalse(room.openings.isEmpty)
            XCTAssertTrue(room.openings.allSatisfy { wallIDs.contains($0.parameters.hostWallID) })

            let otherWallIDs = Set(
                project.rooms
                    .filter { $0.id != room.id }
                    .flatMap { $0.walls.map(\.id) }
            )
            XCTAssertTrue(room.openings.allSatisfy { !otherWallIDs.contains($0.parameters.hostWallID) })
        }
    }

    func testMultiRoomGeometryCarriesRoomOwnershipAndCanBeFiltered() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let geometry = ParametricGeometryEngine().generate(from: project)

        XCTAssertEqual(geometry.roomFloors.count, 2)
        XCTAssertEqual(Set(geometry.roomFloors.map(\.roomID)), Set(project.rooms.map(\.id)))
        let roomIDs = Set(project.rooms.map(\.id))
        XCTAssertTrue(geometry.planWallSegments.allSatisfy { roomIDs.contains($0.roomID) })
        XCTAssertTrue(geometry.wallSolids.allSatisfy { roomIDs.contains($0.roomID) })
        XCTAssertTrue(geometry.hostedOpenings.allSatisfy { roomIDs.contains($0.roomID) })

        let firstRoomID = try XCTUnwrap(project.rooms.first?.id)
        let filtered = geometry.filtered(to: firstRoomID)

        XCTAssertEqual(filtered.roomFloors.count, 1)
        XCTAssertEqual(filtered.roomFloors.first?.roomID, firstRoomID)
        XCTAssertTrue(filtered.planWallSegments.allSatisfy { $0.roomID == firstRoomID })
        XCTAssertTrue(filtered.wallSolids.allSatisfy { $0.roomID == firstRoomID })
        XCTAssertTrue(filtered.hostedOpenings.allSatisfy { $0.roomID == firstRoomID })
        XCTAssertLessThan(filtered.planWallSegments.count, geometry.planWallSegments.count)
    }

    func testEditingOneRoomDoesNotMutateOtherRoomGeometry() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let engine = ParametricGeometryEngine()
        let room2ID = try XCTUnwrap(project.rooms.last?.id)
        let room2Before = engine.generate(from: project).filtered(to: room2ID)

        project.rooms[0].walls[0].editLength(project.rooms[0].walls[0].length + 750)
        let room2After = engine.generate(from: project).filtered(to: room2ID)

        XCTAssertEqual(room2Before, room2After)
    }

    func testMultiRoomPersistencePreservesRoomsStructureProvenanceAndGeometry() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let geometryBefore = ParametricGeometryEngine().generate(from: project)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-multi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProjectStore(url: url)
        try store.save(project)
        let reopened = try store.load()
        let geometryAfter = ParametricGeometryEngine().generate(from: reopened)

        XCTAssertEqual(reopened.rooms.count, 2)
        XCTAssertEqual(reopened.sourceStructureRoomPlanID, MockStructureCaptureProvider.structureSourceID)
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(geometryAfter, geometryBefore)
    }

    func testTopologyClosesBothMockRoomBoundariesAndProducesPolygons() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)

        XCTAssertEqual(topology.roomBoundaries.count, 2)
        XCTAssertTrue(topology.roomBoundaries.allSatisfy(\.isClosed))
        XCTAssertTrue(topology.roomBoundaries.allSatisfy { $0.unmatchedEndpointCount == 0 })
        XCTAssertTrue(topology.roomBoundaries.allSatisfy { $0.polygon.count == 4 })
        XCTAssertFalse(topology.issues.contains { $0.code == .openRoomBoundary })
    }

    func testTopologyDetectsOneStrongSharedPartitionBetweenAdjacentMockRooms() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let shared = try XCTUnwrap(topology.sharedBoundaries.first)

        XCTAssertEqual(topology.sharedBoundaries.count, 1)
        XCTAssertEqual(shared.strength, .strong)
        XCTAssertEqual(shared.overlapLength, 3_000, accuracy: 1e-8)
        XCTAssertEqual(shared.overlapRatio, 1, accuracy: 1e-8)
        XCTAssertEqual(shared.centerlineSeparation, 0, accuracy: 1e-8)
        XCTAssertEqual(shared.angleDifferenceRadians, 0, accuracy: 1e-8)
    }

    func testTopologyBuildsRoomAdjacencyWithoutCollapsingSemanticWallIdentity() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let adjacency = try XCTUnwrap(topology.adjacencies.first)
        let shared = try XCTUnwrap(topology.sharedBoundaries.first)

        XCTAssertEqual(topology.adjacencies.count, 1)
        XCTAssertEqual(Set([adjacency.roomAID, adjacency.roomBID]), Set(project.rooms.map(\.id)))
        XCTAssertEqual(adjacency.sharedBoundaryIDs, [shared.id])
        XCTAssertNotEqual(shared.wallAID, shared.wallBID)
        XCTAssertTrue(project.rooms.flatMap(\.walls).contains { $0.id == shared.wallAID })
        XCTAssertTrue(project.rooms.flatMap(\.walls).contains { $0.id == shared.wallBID })
    }

    func testTopologyMatchesCrossRoomPassageEvidenceOnSharedPartition() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let passage = try XCTUnwrap(topology.passageConnections.first)
        let adjacency = try XCTUnwrap(topology.adjacencies.first)

        XCTAssertEqual(topology.passageConnections.count, 1)
        XCTAssertEqual(passage.centerDistance, 0, accuracy: 1e-8)
        XCTAssertEqual(passage.kind, .mixed)
        XCTAssertTrue(adjacency.passageConnectionIDs.contains(passage.id))

        let allOpenings = project.rooms.flatMap(\.openings)
        XCTAssertTrue(allOpenings.contains { $0.id == passage.openingAID })
        XCTAssertTrue(allOpenings.contains { $0.id == passage.openingBID })
        XCTAssertNotEqual(passage.openingAID, passage.openingBID)
    }

    func testEditingSharedWallDowngradesTopologyWithoutMutatingOtherRoom() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topologyBefore = StructureTopologyEngine().generate(from: project)
        let sharedBefore = try XCTUnwrap(topologyBefore.sharedBoundaries.first)
        XCTAssertEqual(sharedBefore.strength, .strong)

        let wallID = sharedBefore.wallAID
        let roomIndex = try XCTUnwrap(project.rooms.firstIndex { $0.walls.contains(where: { $0.id == wallID }) })
        let wallIndex = try XCTUnwrap(project.rooms[roomIndex].walls.firstIndex { $0.id == wallID })
        project.rooms[roomIndex].walls[wallIndex].start.x += 120

        let topologyAfter = StructureTopologyEngine().generate(from: project)
        let sharedAfter = try XCTUnwrap(topologyAfter.sharedBoundaries.first)
        XCTAssertEqual(sharedAfter.strength, .candidate)
        XCTAssertEqual(sharedAfter.centerlineSeparation, 120, accuracy: 1e-8)
    }

    func testAmbiguousSharedPartitionEvidenceIsDiagnosedWithoutAutoMerging() {
        let wallA = PlanOpsisWall(start: .zero, length: 3_000, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let wallB = PlanOpsisWall(start: Point2D(x: 0, y: 3_000), length: 3_000, angleRadians: -.pi / 2, height: 2_800, thickness: 120)
        let wallC = PlanOpsisWall(start: Point2D(x: 0, y: 3_000), length: 3_000, angleRadians: -.pi / 2, height: 2_800, thickness: 120)
        let project = PlanOpsisProject(rooms: [
            PlanOpsisRoom(walls: [wallA]),
            PlanOpsisRoom(walls: [wallB]),
            PlanOpsisRoom(walls: [wallC])
        ])

        let topology = StructureTopologyEngine().generate(from: project)
        XCTAssertGreaterThanOrEqual(topology.sharedBoundaries.count, 3)
        XCTAssertTrue(topology.issues.contains {
            $0.code == .ambiguousSharedBoundary && $0.relatedCount > 1
        })
    }

    func testOpenRoomBoundaryIsDiagnosedAndFloorFallsBackSafely() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        project.rooms[0].walls.removeLast()

        let geometry = ParametricGeometryEngine().generate(from: project)
        let boundary = try XCTUnwrap(geometry.topology.roomBoundaries.first)
        let floor = try XCTUnwrap(geometry.roomFloors.first)

        XCTAssertFalse(boundary.isClosed)
        XCTAssertTrue(geometry.topology.issues.contains { $0.code == .openRoomBoundary })
        XCTAssertTrue(floor.polygon.isEmpty)
        XCTAssertGreaterThan(floor.bounds.width, 0)
        XCTAssertGreaterThan(floor.bounds.depth, 0)
    }

    func testClosedRoomFloorUsesTopologyPolygonInsteadOfOnlyBoundingBoxEvidence() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let geometry = ParametricGeometryEngine().generate(from: project)
        let room1ID = try XCTUnwrap(project.rooms.first?.id)
        let floor = try XCTUnwrap(geometry.roomFloors.first { $0.roomID == room1ID })

        XCTAssertEqual(floor.polygon.count, 4)
        XCTAssertEqual(floor.bounds.width, 4_000, accuracy: 1e-8)
        XCTAssertEqual(floor.bounds.depth, 3_000, accuracy: 1e-8)
    }

    func testReconciliationCreatesCanonicalPhysicalPartitionWithoutReplacingSemanticWalls() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let reconciliation = StructureReconciliationEngine().generate(from: project, topology: topology)

        XCTAssertEqual(project.rooms.flatMap(\.walls).count, 8)
        XCTAssertEqual(reconciliation.partitions.count, 7)

        let shared = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 })
        XCTAssertEqual(shared.resolution, .consensus)
        XCTAssertNotNil(shared.geometry)
        XCTAssertEqual(shared.sourceWalls.count, 2)
        XCTAssertNotEqual(shared.sourceWalls[0].wallID, shared.sourceWalls[1].wallID)

        let semanticWallIDs = Set(project.rooms.flatMap { $0.walls.map(\.id) })
        XCTAssertEqual(semanticWallIDs.count, 8)
        XCTAssertTrue(shared.sourceWalls.allSatisfy { semanticWallIDs.contains($0.wallID) })
    }

    func testReconciliationPassageUsesHigherConfidenceEvidenceForMaterialDisagreement() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let passage = try XCTUnwrap(reconciliation.passages.first)
        let geometry = try XCTUnwrap(passage.geometry)

        XCTAssertEqual(reconciliation.passages.count, 1)
        XCTAssertEqual(passage.resolution, .preferredHigherConfidence)
        XCTAssertEqual(passage.kind, .mixed)
        XCTAssertEqual(geometry.width, 1_000, accuracy: 1e-8)
        XCTAssertEqual(geometry.height, 2_100, accuracy: 1e-8)
        XCTAssertEqual(geometry.sillHeight, 0, accuracy: 1e-8)
        XCTAssertEqual(passage.sourceOpenings.count, 2)
    }

    func testEqualConfidencePartitionThicknessDisagreementRemainsExplicitConflict() throws {
        let wallA = PlanOpsisWall(
            start: Point2D(x: 0, y: 0),
            length: 3_000,
            angleRadians: .pi / 2,
            height: 2_800,
            thickness: 100,
            confidence: .high
        )
        let wallB = PlanOpsisWall(
            start: Point2D(x: 0, y: 3_000),
            length: 3_000,
            angleRadians: -.pi / 2,
            height: 2_800,
            thickness: 220,
            confidence: .high
        )
        let project = PlanOpsisProject(rooms: [
            PlanOpsisRoom(walls: [wallA]),
            PlanOpsisRoom(walls: [wallB])
        ])

        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let shared = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 })

        XCTAssertEqual(shared.resolution, .conflicted)
        XCTAssertNil(shared.geometry)
        XCTAssertTrue(reconciliation.conflicts.contains {
            $0.code == .partitionThicknessMismatch && abs(($0.magnitudeMM ?? 0) - 120) < 1e-8
        })
    }

    func testCandidateSharedBoundaryIsNotPhysicallyMerged() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topologyBefore = StructureTopologyEngine().generate(from: project)
        let sharedBefore = try XCTUnwrap(topologyBefore.sharedBoundaries.first)
        let roomIndex = try XCTUnwrap(project.rooms.firstIndex { $0.walls.contains(where: { $0.id == sharedBefore.wallAID }) })
        let wallIndex = try XCTUnwrap(project.rooms[roomIndex].walls.firstIndex { $0.id == sharedBefore.wallAID })
        project.rooms[roomIndex].walls[wallIndex].start.x += 120

        let topology = StructureTopologyEngine().generate(from: project)
        XCTAssertEqual(topology.sharedBoundaries.first?.strength, .candidate)

        let reconciliation = StructureReconciliationEngine().generate(from: project, topology: topology)
        XCTAssertEqual(reconciliation.partitions.count, 8)
        XCTAssertTrue(reconciliation.partitions.allSatisfy { $0.sourceWalls.count == 1 })
        XCTAssertTrue(reconciliation.conflicts.contains { $0.code == .candidateSharedBoundary })
        XCTAssertTrue(reconciliation.passages.isEmpty)
    }

    func testReconciliationFilteringKeepsSharedPhysicalOwnershipVisibleFromEitherRoom() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let roomAID = try XCTUnwrap(project.rooms.first?.id)
        let roomBID = try XCTUnwrap(project.rooms.last?.id)

        let roomA = reconciliation.filtered(to: roomAID)
        let roomB = reconciliation.filtered(to: roomBID)

        XCTAssertEqual(roomA.partitions.count, 4)
        XCTAssertEqual(roomB.partitions.count, 4)
        XCTAssertEqual(roomA.partitions.filter { $0.sourceWalls.count == 2 }.count, 1)
        XCTAssertEqual(roomB.partitions.filter { $0.sourceWalls.count == 2 }.count, 1)
        XCTAssertEqual(roomA.passages.count, 1)
        XCTAssertEqual(roomB.passages.count, 1)
    }

    func testGeometrySnapshotCarriesDeterministicReconciliationAndRebuildsAfterSave() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let engine = ParametricGeometryEngine()
        let before = engine.generate(from: project)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v5-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProjectStore(url: url)
        try store.save(project)
        let reopened = try store.load()
        let after = engine.generate(from: reopened)

        XCTAssertEqual(before.reconciliation, after.reconciliation)
        XCTAssertEqual(before, after)
    }

    func testV6SemanticDisplayPreservesAllEightRoomLocalWallIdentities() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let semantic = ParametricGeometryEngine().generate(from: project).semanticDisplaySnapshot()

        XCTAssertEqual(semantic.representation, .semanticObservations)
        XCTAssertEqual(semantic.physicalPartitionIDs.count, 8)
        XCTAssertTrue(semantic.planWallSegments.allSatisfy { $0.sourceWallIDs.count == 1 })
        XCTAssertEqual(Set(semantic.planWallSegments.flatMap(\.sourceWallIDs)), Set(project.rooms.flatMap { $0.walls.map(\.id) }))
    }

    func testV6ReconciledDisplayCollapsesStrongSharedWallToOnePhysicalPartition() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let semantic = ParametricGeometryEngine().generate(from: project)
        let physical = PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)

        XCTAssertEqual(physical.representation, .reconciledPhysical)
        XCTAssertEqual(physical.physicalPartitionIDs.count, 7)
        let sharedSegments = physical.planWallSegments.filter { $0.sourceWallIDs.count == 2 }
        XCTAssertFalse(sharedSegments.isEmpty)
        XCTAssertEqual(Set(sharedSegments.map(\.partitionID)).count, 1)
        XCTAssertTrue(sharedSegments.allSatisfy { $0.sourceRoomIDs.count == 2 })
    }

    func testV6ResolvedPhysicalPassageCutsCanonicalPartitionOnlyOnce() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let physical = PhysicalDisplayGeometryEngine().generate(from: project)
        let sharedPassage = try XCTUnwrap(physical.hostedOpenings.first { $0.sourceOpeningIDs.count == 2 })

        XCTAssertTrue(sharedPassage.cutsWall)
        XCTAssertEqual(sharedPassage.kind, .mixedPassage)
        XCTAssertEqual(sharedPassage.width, 1_000, accuracy: 1e-8)
        XCTAssertEqual(sharedPassage.height, 2_100, accuracy: 1e-8)
        XCTAssertEqual(physical.hostedOpenings.filter { Set($0.sourceOpeningIDs) == Set(sharedPassage.sourceOpeningIDs) }.count, 1)
    }

    func testV6SharedPhysicalPartitionRemainsVisibleWhenEitherRoomIsFocused() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let physical = PhysicalDisplayGeometryEngine().generate(from: project)
        let roomA = try XCTUnwrap(project.rooms.first)
        let roomB = try XCTUnwrap(project.rooms.last)
        let filteredA = physical.filtered(to: roomA.id)
        let filteredB = physical.filtered(to: roomB.id)

        let sharedA = Set(filteredA.planWallSegments.filter { $0.sourceWallIDs.count == 2 }.map(\.partitionID))
        let sharedB = Set(filteredB.planWallSegments.filter { $0.sourceWallIDs.count == 2 }.map(\.partitionID))
        XCTAssertEqual(sharedA.count, 1)
        XCTAssertEqual(sharedA, sharedB)
    }

    func testV6CandidateSharedBoundaryDoesNotCollapseDisplayGeometry() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let shared = try XCTUnwrap(topology.sharedBoundaries.first)
        let roomIndex = try XCTUnwrap(project.rooms.firstIndex { $0.walls.contains(where: { $0.id == shared.wallAID }) })
        let wallIndex = try XCTUnwrap(project.rooms[roomIndex].walls.firstIndex { $0.id == shared.wallAID })
        project.rooms[roomIndex].walls[wallIndex].start.x += 120

        let physical = PhysicalDisplayGeometryEngine().generate(from: project)
        XCTAssertEqual(physical.physicalPartitionIDs.count, 8)
        XCTAssertTrue(physical.planWallSegments.allSatisfy { $0.sourceWallIDs.count == 1 })
    }

    func testV6ConflictedPhysicalPartitionFallsBackToBothSemanticWalls() throws {
        let wallA = PlanOpsisWall(
            start: Point2D(x: 0, y: 0),
            length: 3_000,
            angleRadians: .pi / 2,
            height: 2_800,
            thickness: 100,
            confidence: .high
        )
        let wallB = PlanOpsisWall(
            start: Point2D(x: 0, y: 3_000),
            length: 3_000,
            angleRadians: -.pi / 2,
            height: 2_800,
            thickness: 220,
            confidence: .high
        )
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wallA]), PlanOpsisRoom(walls: [wallB])])
        let physical = PhysicalDisplayGeometryEngine().generate(from: project)

        XCTAssertTrue(physical.issues.contains { $0.code == .conflictedPartitionSemanticFallback })
        XCTAssertEqual(Set(physical.planWallSegments.flatMap(\.sourceWallIDs)), Set([wallA.id, wallB.id]))
        XCTAssertTrue(physical.planWallSegments.allSatisfy { $0.sourceWallIDs.count == 1 })
    }

    func testV6EqualConfidencePassageConflictIsEvidenceOnlyAndDoesNotCutCanonicalWall() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let topology = StructureTopologyEngine().generate(from: project)
        let connection = try XCTUnwrap(topology.passageConnections.first)

        for roomIndex in project.rooms.indices {
            for openingIndex in project.rooms[roomIndex].openings.indices {
                let id = project.rooms[roomIndex].openings[openingIndex].id
                guard id == connection.openingAID || id == connection.openingBID else { continue }
                var parameters = project.rooms[roomIndex].openings[openingIndex].parameters
                parameters.confidence = .high
                if id == connection.openingAID { parameters.height = 1_600 }
                if id == connection.openingBID { parameters.height = 2_100 }
                project.rooms[roomIndex].openings[openingIndex].parameters = parameters
            }
        }

        let physical = PhysicalDisplayGeometryEngine().generate(from: project)
        XCTAssertTrue(physical.issues.contains { $0.code == .conflictedPassageEvidenceOnly })
        let evidence = physical.hostedOpenings.filter { opening in
            !opening.cutsWall && !Set(opening.sourceOpeningIDs).isDisjoint(with: [connection.openingAID, connection.openingBID])
        }
        XCTAssertEqual(evidence.count, 2)
    }

    func testV6PhysicalDisplayIsDeterministicAndRebuildsFromSemanticPersistence() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let engine = PhysicalDisplayGeometryEngine()
        let before = engine.generate(from: project)
        XCTAssertEqual(before, engine.generate(from: project))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v6-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(url: url)
        try store.save(project)
        let reopened = try store.load()
        let after = engine.generate(from: reopened)

        XCTAssertEqual(project, reopened)
        XCTAssertEqual(before, after)
    }


    func testV7ResolvedPhysicalPartitionCreatesApprovalDraftAndPreviewWithoutMutatingProject() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        let originalProject = project
        let original = try XCTUnwrap(partition.geometry)
        let direction = (original.end - original.start).normalized
        draft.targetGeometry.end = original.start + direction * (original.length + 600)
        draft.targetGeometry.height += 200
        draft.targetGeometry.thickness += 20

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.wallMutations.count, 2)
        XCTAssertFalse(plan.openingMutations.isEmpty)
        XCTAssertEqual(project, originalProject, "Preview must be pure and must not mutate semantic state")
        XCTAssertTrue(plan.wallMutations.allSatisfy { abs($0.after.length - (original.length + 600)) < 1e-8 })
        XCTAssertTrue(plan.wallMutations.allSatisfy { abs($0.after.height - (original.height + 200)) < 1e-8 })
        XCTAssertTrue(plan.wallMutations.allSatisfy { abs($0.after.thickness - (original.thickness + 20)) < 1e-8 })
    }

    func testV7SimulationProducesPreviewProjectAndDisplayWithoutMutatingAuthoritativeProject() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let original = project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        draft.targetGeometry.thickness += 35
        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)

        let simulated = try engine.simulate(plan, on: project)
        let previewDisplay = PhysicalDisplayGeometryEngine().generate(from: simulated)
        let currentDisplay = PhysicalDisplayGeometryEngine().generate(from: project)

        XCTAssertEqual(project, original)
        XCTAssertNotEqual(simulated, project)
        XCTAssertNotEqual(previewDisplay, currentDisplay)
        XCTAssertEqual(Set(simulated.rooms.flatMap { $0.walls.map(\.id) }), Set(project.rooms.flatMap { $0.walls.map(\.id) }))
    }

    func testV7PhysicalEditPreservesSourceWallUUIDsAndAppliesBothSidesAtomically() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        let original = try XCTUnwrap(partition.geometry)
        let direction = (original.end - original.start).normalized
        draft.targetGeometry.end = original.start + direction * 3_600
        draft.targetGeometry.height = 3_000
        draft.targetGeometry.thickness = 140

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        let result = try engine.apply(plan, to: project)
        let sourceIDs = Set(partition.sourceWalls.map(\.wallID))
        let changedWalls = result.project.rooms.flatMap(\.walls).filter { sourceIDs.contains($0.id) }

        XCTAssertEqual(changedWalls.count, 2)
        XCTAssertEqual(Set(changedWalls.map(\.id)), sourceIDs)
        XCTAssertTrue(changedWalls.allSatisfy { abs($0.length - 3_600) < 1e-8 })
        XCTAssertTrue(changedWalls.allSatisfy { abs($0.height - 3_000) < 1e-8 })
        XCTAssertTrue(changedWalls.allSatisfy { abs($0.thickness - 140) < 1e-8 })

        let untouchedIDs = Set(project.rooms.flatMap { $0.walls.map(\.id) }).subtracting(sourceIDs)
        for id in untouchedIDs {
            let before = project.rooms.flatMap(\.walls).first { $0.id == id }
            let after = result.project.rooms.flatMap(\.walls).first { $0.id == id }
            XCTAssertEqual(before, after)
        }
    }

    func testV7HostedOpeningsPreserveNormalizedCentersThroughPhysicalLengthEdit() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        let original = try XCTUnwrap(partition.geometry)
        let direction = (original.end - original.start).normalized
        draft.targetGeometry.end = original.start + direction * (original.length * 1.25)

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        XCTAssertTrue(plan.canApply)
        XCTAssertFalse(plan.openingMutations.isEmpty)

        for opening in plan.openingMutations {
            let wall = try XCTUnwrap(plan.wallMutations.first { $0.wallID == opening.before.hostWallID })
            let beforeRatio = opening.before.offsetAlongWall / wall.before.length
            let afterRatio = opening.after.offsetAlongWall / wall.after.length
            XCTAssertEqual(afterRatio, beforeRatio, accuracy: 1e-10)
        }
    }

    func testV7PreviewRejectsPhysicalEditWhenHostedOpeningWouldNotFit() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        let original = try XCTUnwrap(partition.geometry)
        let direction = (original.end - original.start).normalized
        draft.targetGeometry.end = original.start + direction * 600

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.issues.contains { $0.code == .openingDoesNotFitLength })
        XCTAssertThrowsError(try engine.apply(plan, to: project)) { error in
            XCTAssertEqual(error as? PhysicalEditTransactionError, .invalidPlan)
        }
    }

    func testV7PreviewRejectsWallHeightThatCutsHostedOpening() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        draft.targetGeometry.height = 1_500

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.issues.contains { $0.code == .openingExceedsWallHeight })
    }

    func testV7ApplyRejectsStaleSemanticStateAfterPreview() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        draft.targetGeometry.thickness += 10
        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        XCTAssertTrue(plan.canApply)

        let source = try XCTUnwrap(partition.sourceWalls.first)
        let roomIndex = try XCTUnwrap(project.rooms.firstIndex { $0.id == source.roomID })
        let wallIndex = try XCTUnwrap(project.rooms[roomIndex].walls.firstIndex { $0.id == source.wallID })
        project.rooms[roomIndex].walls[wallIndex].height += 1

        XCTAssertThrowsError(try engine.apply(plan, to: project)) { error in
            XCTAssertEqual(error as? PhysicalEditTransactionError, .staleSemanticState)
        }
    }

    func testV7UndoRestoresExactSemanticProjectAfterApprovedPhysicalEdit() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        draft.targetGeometry.height += 150
        draft.targetGeometry.thickness += 15

        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        let applied = try engine.apply(plan, to: project)
        XCTAssertNotEqual(applied.project, project)

        let undone = try engine.undo(applied.receipt, from: applied.project)
        XCTAssertEqual(undone, project)
        XCTAssertEqual(ParametricGeometryEngine().generate(from: undone), ParametricGeometryEngine().generate(from: project))
    }

    func testV7ConflictedPartitionCannotStartPhysicalTransaction() throws {
        let wallA = PlanOpsisWall(start: .zero, length: 3_000, angleRadians: .pi / 2, height: 2_800, thickness: 100, confidence: .high)
        let wallB = PlanOpsisWall(start: Point2D(x: 0, y: 3_000), length: 3_000, angleRadians: -.pi / 2, height: 2_800, thickness: 240, confidence: .high)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wallA]), PlanOpsisRoom(walls: [wallB])])
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 })
        let engine = PhysicalPartitionEditTransactionEngine()

        XCTAssertEqual(partition.resolution, .conflicted)
        XCTAssertNil(engine.draft(for: partition))

        let manualDraft = PhysicalPartitionEditDraft(
            partitionID: partition.id,
            targetGeometry: CanonicalPartitionGeometry(start: .zero, end: Point2D(x: 0, y: 3_000), height: 2_800, thickness: 170)
        )
        let plan = engine.preview(draft: manualDraft, project: project, reconciliation: reconciliation)
        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.issues.contains { $0.code == .unresolvedPartition })
    }

    func testV7ApprovedTransactionPersistsAndRegeneratesFromSemanticJSONOnly() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let reconciliation = StructureReconciliationEngine().generate(from: project)
        let partition = try XCTUnwrap(reconciliation.partitions.first { $0.sourceWalls.count == 2 && $0.geometry != nil })
        let engine = PhysicalPartitionEditTransactionEngine()
        var draft = try XCTUnwrap(engine.draft(for: partition))
        draft.targetGeometry.thickness += 25
        let plan = engine.preview(draft: draft, project: project, reconciliation: reconciliation)
        let applied = try engine.apply(plan, to: project).project
        let geometryBefore = ParametricGeometryEngine().generate(from: applied)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v7-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(url: url)
        try store.save(applied)
        let reopened = try store.load()
        let geometryAfter = ParametricGeometryEngine().generate(from: reopened)

        XCTAssertEqual(reopened, applied)
        XCTAssertEqual(geometryAfter, geometryBefore)
    }


    func testV8StartGripEditingPreservesPreviousEndAndUpdatesCanonicalLengthAngle() {
        var wall = PlanOpsisWall(
            start: Point2D(x: 0, y: 0),
            length: 4_000,
            angleRadians: 0,
            height: 2_800,
            thickness: 120
        )
        let fixedEnd = wall.end
        wall.editStartKeepingEnd(Point2D(x: 500, y: 500))

        XCTAssertEqual(wall.end.x, fixedEnd.x, accuracy: 1e-8)
        XCTAssertEqual(wall.end.y, fixedEnd.y, accuracy: 1e-8)
        XCTAssertEqual(wall.length, sqrt(3_500 * 3_500 + 500 * 500), accuracy: 1e-8)
        XCTAssertEqual(wall.angleRadians, atan2(-500.0, 3_500.0), accuracy: 1e-8)
    }

    func testV8JunctionResolverSnapsNearEndpointsAndProducesJoinedDisplayCaps() throws {
        let wallA = PlanOpsisWall(
            start: Point2D(x: 0, y: 0),
            length: 3_000,
            angleRadians: 0,
            height: 2_800,
            thickness: 120
        )
        let wallB = PlanOpsisWall(
            start: Point2D(x: 3_080, y: 20),
            length: 2_500,
            angleRadians: .pi / 2,
            height: 2_800,
            thickness: 120
        )
        let room = PlanOpsisRoom(walls: [wallA, wallB])
        let resolver = WallJunctionResolver()
        let axes = resolver.resolve(room: room)
        let a = try XCTUnwrap(axes[wallA.id])
        let b = try XCTUnwrap(axes[wallB.id])

        XCTAssertTrue(a.joinedAtEnd)
        XCTAssertTrue(b.joinedAtStart)
        XCTAssertEqual(a.end.x, b.start.x, accuracy: 1e-8)
        XCTAssertEqual(a.end.y, b.start.y, accuracy: 1e-8)

        let aSpan = resolver.displaySpan(wall: wallA, axis: a, startOffset: 0, length: wallA.length)
        let bSpan = resolver.displaySpan(wall: wallB, axis: b, startOffset: 0, length: wallB.length)
        XCTAssertGreaterThan(aSpan.length, a.length)
        XCTAssertGreaterThan(bSpan.length, b.length)
    }

    func testV8GeneratedJoinedWallSolidsCarryExtendedRenderAxisWithoutChangingSemanticOffsets() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let room = try XCTUnwrap(project.rooms.first)
        let geometry = ParametricGeometryEngine().generate(from: project)
        let wall = try XCTUnwrap(room.walls.first)
        let solids = geometry.wallSolids.filter { $0.hostWallID == wall.id }

        XCTAssertFalse(solids.isEmpty)
        XCTAssertTrue(solids.contains { $0.renderLength > $0.length })
        XCTAssertTrue(solids.allSatisfy { $0.startOffset >= 0 && $0.startOffset <= wall.length })
    }

    func testV8DoorSwingPersistsAndRegeneratesIntoDisplayGeometry() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let roomIndex = try XCTUnwrap(project.rooms.indices.first)
        let doorIndex = try XCTUnwrap(project.rooms[roomIndex].openings.firstIndex { $0.kind == .door })
        project.rooms[roomIndex].openings[doorIndex].doorSwing = .leftIn
        let doorID = project.rooms[roomIndex].openings[doorIndex].id

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-v8-door-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectStore(url: url)
        try store.save(project)
        let reopened = try store.load()
        let reopenedDoor = try XCTUnwrap(reopened.rooms.flatMap(\.openings).first { $0.id == doorID })
        XCTAssertEqual(reopenedDoor.doorSwing, .leftIn)

        let display = ParametricGeometryEngine().generate(from: reopened).semanticDisplaySnapshot()
        let displayDoor = try XCTUnwrap(display.hostedOpenings.first { $0.sourceOpeningIDs.contains(doorID) })
        XCTAssertEqual(displayDoor.doorSwing, .leftIn)
    }

    func testV8UnspecifiedDoorSwingRemainsBackwardCompatible() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let door = try XCTUnwrap(project.rooms.flatMap(\.openings).first { $0.kind == .door })
        XCTAssertEqual(door.doorSwing, .unspecified)
    }


    func testV8ReconciledPhysicalDisplayAlsoUsesJoinedRenderCaps() {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let display = PhysicalDisplayGeometryEngine().generate(from: project)
        XCTAssertTrue(display.wallSolids.contains { $0.renderLength > $0.length })
    }

    func testV83GridSnapUsesDeterministic250MillimetreLattice() {
        let engine = PlanEditingConstraintEngine()
        let snapped = engine.snapToGrid(Point2D(x: 620, y: 380), spacing: 250)
        XCTAssertEqual(snapped.x, 500, accuracy: 1e-9)
        XCTAssertEqual(snapped.y, 500, accuracy: 1e-9)
    }

    func testV83OrthoLocksEndpointToDominantGlobalAxis() {
        let engine = PlanEditingConstraintEngine()
        let horizontal = engine.orthoPoint(Point2D(x: 1_000, y: 700), anchor: .zero)
        XCTAssertEqual(horizontal.x, 1_000, accuracy: 1e-9)
        XCTAssertEqual(horizontal.y, 0, accuracy: 1e-9)

        let vertical = engine.orthoPoint(Point2D(x: 300, y: 900), anchor: .zero)
        XCTAssertEqual(vertical.x, 0, accuracy: 1e-9)
        XCTAssertEqual(vertical.y, 900, accuracy: 1e-9)
    }

    func testV83EndpointTouchCreatesCoincidentJunctionAndFutureMovePropagatesConnection() throws {
        let wallA = PlanOpsisWall(start: .zero, length: 1_000, angleRadians: 0, height: 2_800, thickness: 120)
        let wallB = PlanOpsisWall(start: Point2D(x: 1_200, y: 100), length: 1_000, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let engine = PlanEditingConstraintEngine()
        let settings = PlanEditingSettings(endpointSnapTolerance: 140)

        let connected = try XCTUnwrap(engine.moveEndpoint(
            wallID: wallA.id,
            endpoint: .end,
            proposed: Point2D(x: 1_190, y: 100),
            in: [wallA, wallB],
            settings: settings
        ))
        let a1 = try XCTUnwrap(connected.walls.first { $0.id == wallA.id })
        let b1 = try XCTUnwrap(connected.walls.first { $0.id == wallB.id })
        XCTAssertEqual(a1.end.x, b1.start.x, accuracy: 1e-9)
        XCTAssertEqual(a1.end.y, b1.start.y, accuracy: 1e-9)
        XCTAssertNotNil(connected.constraint.snappedEndpoint)

        let moved = try XCTUnwrap(engine.moveEndpoint(
            wallID: wallA.id,
            endpoint: .end,
            proposed: Point2D(x: 1_500, y: 300),
            in: connected.walls,
            settings: settings,
            applyConstraints: false
        ))
        let a2 = try XCTUnwrap(moved.walls.first { $0.id == wallA.id })
        let b2 = try XCTUnwrap(moved.walls.first { $0.id == wallB.id })
        XCTAssertEqual(a2.end.x, 1_500, accuracy: 1e-9)
        XCTAssertEqual(a2.end.y, 300, accuracy: 1e-9)
        XCTAssertEqual(b2.start.x, 1_500, accuracy: 1e-9)
        XCTAssertEqual(b2.start.y, 300, accuracy: 1e-9)
        XCTAssertEqual(moved.propagatedEndpointIDs.count, 1)
    }

    func testV83ExactNumericEndpointMoveBypassesGridQuantization() throws {
        let wall = PlanOpsisWall(start: .zero, length: 3_000, angleRadians: 0, height: 2_800, thickness: 120)
        let engine = PlanEditingConstraintEngine()
        let result = try XCTUnwrap(engine.moveEndpoint(
            wallID: wall.id,
            endpoint: .end,
            proposed: Point2D(x: 3_875, y: 0),
            in: [wall],
            settings: PlanEditingSettings(gridEnabled: true, gridSpacing: 250),
            applyConstraints: false
        ))
        let edited = try XCTUnwrap(result.walls.first)
        XCTAssertEqual(edited.length, 3_875, accuracy: 1e-9)
        XCTAssertEqual(edited.end.x, 3_875, accuracy: 1e-9)
        XCTAssertFalse(result.constraint.usedGrid)
    }

    func testV83OrthoDoesNotSnapToEndpointThatWouldBreakOrthogonality() throws {
        let wallA = PlanOpsisWall(start: .zero, length: 500, angleRadians: 0, height: 2_800, thickness: 120)
        let wallB = PlanOpsisWall(start: Point2D(x: 1_000, y: 200), length: 800, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let engine = PlanEditingConstraintEngine()
        let result = try XCTUnwrap(engine.moveEndpoint(
            wallID: wallA.id,
            endpoint: .end,
            proposed: Point2D(x: 990, y: 190),
            in: [wallA, wallB],
            settings: PlanEditingSettings(orthoEnabled: true, endpointSnapTolerance: 140)
        ))
        let edited = try XCTUnwrap(result.walls.first { $0.id == wallA.id })
        XCTAssertNil(result.constraint.snappedEndpoint)
        XCTAssertEqual(edited.end.y, 0, accuracy: 1e-9)
    }

    func testV84SemanticEditorAddsWallDoorWindowAndOpeningWithArchitecturalDefaults() throws {
        let engine = SemanticObjectEditingEngine()
        let roomID = UUID()
        var project = PlanOpsisProject(rooms: [PlanOpsisRoom(id: roomID)])
        let wallResult = try XCTUnwrap(engine.addWall(
            to: roomID,
            start: .zero,
            end: Point2D(x: 4_000, y: 0),
            project: project
        ))
        project = wallResult.0
        let wallID = wallResult.1
        let wall = try XCTUnwrap(project.rooms[0].walls.first)
        XCTAssertEqual(wall.thickness, 200, accuracy: 1e-9)
        XCTAssertEqual(wall.height, 2_800, accuracy: 1e-9)

        let door = try XCTUnwrap(engine.addOpening(kind: .door, to: roomID, hostWallID: wallID, center: Point2D(x: 1_000, y: 0), project: project))
        project = door.0
        let window = try XCTUnwrap(engine.addOpening(kind: .window, to: roomID, hostWallID: wallID, center: Point2D(x: 2_400, y: 0), project: project))
        project = window.0
        let opening = try XCTUnwrap(engine.addOpening(kind: .opening, to: roomID, hostWallID: wallID, center: Point2D(x: 3_300, y: 0), project: project))
        project = opening.0

        XCTAssertEqual(project.rooms[0].openings.count, 3)
        let addedDoor = try XCTUnwrap(project.rooms[0].openings.first { $0.id == door.1 })
        XCTAssertEqual(addedDoor.parameters.width, 900, accuracy: 1e-9)
        XCTAssertEqual(addedDoor.parameters.height, 2_100, accuracy: 1e-9)
        XCTAssertEqual(addedDoor.doorSwing, .leftIn)
        let addedWindow = try XCTUnwrap(project.rooms[0].openings.first { $0.id == window.1 })
        XCTAssertEqual(addedWindow.parameters.width, 1_200, accuracy: 1e-9)
        XCTAssertEqual(addedWindow.parameters.sillHeight, 900, accuracy: 1e-9)
    }

    func testV84DeletingWallCascadesHostedOpeningsButNotOtherWalls() throws {
        let engine = SemanticObjectEditingEngine()
        let roomID = UUID()
        let wallA = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 200)
        let wallB = PlanOpsisWall(start: Point2D(x: 4_000, y: 0), length: 3_000, angleRadians: .pi / 2, height: 2_800, thickness: 200)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: wallA.id, offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0), swing: .leftIn))
        let window = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(hostWallID: wallB.id, offsetAlongWall: 1_500, width: 1_000, height: 1_200, sillHeight: 900)))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(id: roomID, walls: [wallA, wallB], openings: [door, window])])
        let result = try XCTUnwrap(engine.delete(entityID: wallA.id, from: project))
        XCTAssertEqual(result.project.rooms[0].walls.map(\.id), [wallB.id])
        XCTAssertEqual(result.project.rooms[0].openings.map(\.id), [window.id])
        XCTAssertEqual(Set(result.deletedIDs), Set([wallA.id, door.id]))
    }

    func testV84DXFExportUsesMillimetresArchitecturalLayersLineweightsAndDoorArc() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let roomIndex = try XCTUnwrap(project.rooms.indices.first)
        let doorIndex = try XCTUnwrap(project.rooms[roomIndex].openings.firstIndex { $0.kind == .door })
        project.rooms[roomIndex].openings[doorIndex].doorSwing = .leftIn
        let engine = DXFExchangeEngine()
        let dxf = engine.export(project: project)
        let normalized = dxf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(normalized.contains("$ACADVER\n1\nAC1015"))
        XCTAssertTrue(normalized.contains("$INSUNITS\n70\n4"))
        XCTAssertTrue(normalized.contains("A-WALL"))
        XCTAssertTrue(normalized.contains("A-DOOR-SWNG"))
        XCTAssertTrue(normalized.contains("A-WIND"))
        XCTAssertTrue(normalized.contains("A-DIMS"))
        XCTAssertTrue(normalized.contains("\n0\nARC\n"))
        XCTAssertTrue(normalized.contains("\n0\nTEXT\n"))
        XCTAssertTrue(normalized.contains("\n1001\nPLANOPSIS\n"))
    }

    func testV84DXFRoundTripPreservesSemanticWallAndOpeningIdentityAndDoorSwing() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        for roomIndex in project.rooms.indices {
            for openingIndex in project.rooms[roomIndex].openings.indices where project.rooms[roomIndex].openings[openingIndex].kind == .door {
                project.rooms[roomIndex].openings[openingIndex].doorSwing = .rightOut
            }
        }
        let engine = DXFExchangeEngine()
        let imported = engine.import(engine.export(project: project))
        XCTAssertTrue(imported.preview.primitives.contains { $0.kind == .arc && $0.layer == ArchitecturalDraftingConvention.Layer.doorSwing.rawValue })
        XCTAssertTrue(imported.preview.primitives.contains { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue })
        let reopened = try XCTUnwrap(imported.project)
        XCTAssertEqual(Set(reopened.rooms.map(\.id)), Set(project.rooms.map(\.id)))
        XCTAssertEqual(Set(reopened.rooms.flatMap(\.walls).map(\.id)), Set(project.rooms.flatMap(\.walls).map(\.id)))
        XCTAssertEqual(Set(reopened.rooms.flatMap(\.openings).map(\.id)), Set(project.rooms.flatMap(\.openings).map(\.id)))
        for wall in project.rooms.flatMap(\.walls) {
            let r = try XCTUnwrap(reopened.rooms.flatMap(\.walls).first { $0.id == wall.id })
            XCTAssertEqual(r.start.x, wall.start.x, accuracy: 1e-6)
            XCTAssertEqual(r.start.y, wall.start.y, accuracy: 1e-6)
            XCTAssertEqual(r.length, wall.length, accuracy: 1e-5)
            XCTAssertEqual(r.height, wall.height, accuracy: 1e-6)
            XCTAssertEqual(r.thickness, wall.thickness, accuracy: 1e-6)
        }
        XCTAssertTrue(reopened.rooms.flatMap(\.openings).filter { $0.kind == .door }.allSatisfy { $0.doorSwing == .rightOut })
    }

    func testV84DXFPreviewUsesArchitecturalRepresentationAndHidesMetadataAxes() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let preview = DXFExchangeEngine().preview(for: project)
        XCTAssertTrue(preview.primitives.contains { $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue && $0.kind == .line })
        XCTAssertFalse(preview.primitives.contains { $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue && $0.kind == .polyline })
        XCTAssertTrue(preview.primitives.contains { $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue && $0.kind == .text })
        XCTAssertFalse(preview.primitives.contains { $0.layer == ArchitecturalDraftingConvention.Layer.wallCenter.rawValue })
        XCTAssertFalse(preview.primitives.contains { $0.layer == ArchitecturalDraftingConvention.Layer.metadata.rawValue })
    }

    func testV84GenericDXFWithoutExplicitWallAxesIsViewOnlyNotGuessedIntoArchitecture() {
        let dxf = "0\nSECTION\n2\nENTITIES\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n1000\n21\n0\n0\nENDSEC\n0\nEOF\n"
        let result = DXFExchangeEngine().import(dxf)
        XCTAssertNil(result.project)
        XCTAssertEqual(result.preview.primitives.count, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .noParametricWalls })
    }

    func testV84GenericArchitecturalCenterlineDXFCanCreateParametricWallConservatively() throws {
        let dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\nA-WALL-CNTR\n90\n2\n70\n0\n43\n180\n10\n0\n20\n0\n10\n3500\n20\n0\n0\nENDSEC\n0\nEOF\n"
        let result = DXFExchangeEngine().import(dxf)
        let project = try XCTUnwrap(result.project)
        let wall = try XCTUnwrap(project.rooms.first?.walls.first)
        XCTAssertEqual(wall.length, 3_500, accuracy: 1e-9)
        XCTAssertEqual(wall.thickness, 180, accuracy: 1e-9)
        XCTAssertEqual(wall.height, 2_800, accuracy: 1e-9)
    }

    func testV84ArchitecturalDrawingHierarchyKeepsCutWallsHeavierThanOpeningsAndDimensions() {
        XCTAssertGreaterThan(ArchitecturalDraftingConvention.lineWeightMM(for: .wall), ArchitecturalDraftingConvention.lineWeightMM(for: .door))
        XCTAssertGreaterThan(ArchitecturalDraftingConvention.lineWeightMM(for: .door), ArchitecturalDraftingConvention.lineWeightMM(for: .dimensions))
        XCTAssertEqual(ArchitecturalDraftingConvention.Layer.wall.rawValue, "A-WALL")
        XCTAssertEqual(ArchitecturalDraftingConvention.Layer.window.rawValue, "A-WIND")
    }

    func testV9SurveyReadinessAcceptsClosedMockForDXF() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let geometry = ParametricGeometryEngine().generate(from: project)
        let report = ArchitecturalSurveyReadinessEngine().evaluate(project: project, geometry: geometry)
        XCTAssertTrue(report.canExportDXF)
        XCTAssertEqual(report.roomCount, 1)
        XCTAssertEqual(report.closedRoomCount, 1)
        XCTAssertEqual(report.errorCount, 0)
    }

    func testV9SurveyReadinessWarnsForOpenBoundaryWithoutInventingClosure() {
        let walls = [
            PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 200, confidence: .high),
            PlanOpsisWall(start: Point2D(x: 4_000, y: 0), length: 3_000, angleRadians: .pi / 2, height: 2_800, thickness: 200, confidence: .high),
            PlanOpsisWall(start: Point2D(x: 4_000, y: 3_000), length: 4_000, angleRadians: .pi, height: 2_800, thickness: 200, confidence: .high)
        ]
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: walls)])
        let report = ArchitecturalSurveyReadinessEngine().evaluate(project: project)
        XCTAssertTrue(report.canExportDXF)
        XCTAssertFalse(report.isProfessionalReady)
        XCTAssertTrue(report.issues.contains { $0.code == .openRoomBoundary && $0.severity == .warning })
    }

    func testV9SurveyReadinessBlocksOrphanOpening() {
        let walls = [
            PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 200, confidence: .high),
            PlanOpsisWall(start: Point2D(x: 4_000, y: 0), length: 3_000, angleRadians: .pi / 2, height: 2_800, thickness: 200, confidence: .high),
            PlanOpsisWall(start: Point2D(x: 4_000, y: 3_000), length: 4_000, angleRadians: .pi, height: 2_800, thickness: 200, confidence: .high),
            PlanOpsisWall(start: Point2D(x: 0, y: 3_000), length: 3_000, angleRadians: -.pi / 2, height: 2_800, thickness: 200, confidence: .high)
        ]
        let orphan = PlanOpsisOpening.opening(HostedOpeningParameters(
            hostWallID: UUID(), offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0, confidence: .high
        ))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: walls, openings: [orphan])])
        let report = ArchitecturalSurveyReadinessEngine().evaluate(project: project)
        XCTAssertFalse(report.canExportDXF)
        XCTAssertTrue(report.issues.contains { $0.code == .invalidOpeningHost && $0.severity == .error })
    }

    func testV9ReconciledDXFPreviewCollapsesDuplicateSharedWallPresentation() {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let engine = DXFExchangeEngine()
        let observed = engine.preview(for: project, representation: .semanticObservations)
        let reconciled = engine.preview(for: project, representation: .reconciledPhysical)
        let observedWalls = observed.primitives.filter { $0.kind == .line && $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue }.count
        let reconciledWalls = reconciled.primitives.filter { $0.kind == .line && $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue }.count
        XCTAssertLessThan(reconciledWalls, observedWalls)
    }

    func testV9DXFAddsProfessionalHeaderRoomAreaAndOpeningJambs() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let roomIndex = try XCTUnwrap(project.rooms.indices.first)
        let doorIndex = try XCTUnwrap(project.rooms[roomIndex].openings.firstIndex { $0.kind == .door })
        project.rooms[roomIndex].openings[doorIndex].doorSwing = .leftIn
        let engine = DXFExchangeEngine()
        let preview = engine.preview(for: project, representation: .reconciledPhysical)
        let dxf = engine.export(project: project, representation: .reconciledPhysical)
        let normalized = dxf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(normalized.contains("$LUNITS\n70\n2"))
        XCTAssertTrue(normalized.contains("$LUPREC\n70\n0"))
        XCTAssertTrue(preview.primitives.contains { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue && ($0.text ?? "").contains("m2") })
        let doorLines = preview.primitives.filter { $0.kind == .line && $0.layer == ArchitecturalDraftingConvention.Layer.door.rawValue }
        XCTAssertGreaterThanOrEqual(doorLines.count, 3) // two jambs + leaf
    }

    func testV9ReconciledPhysicalDisplayPreservesExplicitDoorSwing() throws {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        for roomIndex in project.rooms.indices {
            for openingIndex in project.rooms[roomIndex].openings.indices where project.rooms[roomIndex].openings[openingIndex].kind == .door {
                project.rooms[roomIndex].openings[openingIndex].doorSwing = .rightOut
            }
        }
        let semantic = ParametricGeometryEngine().generate(from: project)
        let display = PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)
        let doors = display.hostedOpenings.filter { $0.kind == .door }
        XCTAssertFalse(doors.isEmpty)
        XCTAssertTrue(doors.allSatisfy { $0.doorSwing == .rightOut })
    }

    func testV93DXFSerializationUsesCRLFCoreSectionsAndInternalValidation() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let result = DXFExchangeEngine().exportValidated(project: project)
        XCTAssertTrue(result.canWrite)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.text.contains("\r\n"))
        let normalized = result.text.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(normalized.contains("0\nSECTION\n2\nHEADER\n"))
        XCTAssertTrue(normalized.contains("0\nSECTION\n2\nTABLES\n"))
        XCTAssertTrue(normalized.contains("0\nSECTION\n2\nBLOCKS\n"))
        XCTAssertTrue(normalized.contains("0\nSECTION\n2\nENTITIES\n"))
        XCTAssertTrue(normalized.hasSuffix("0\nEOF\n"))
        XCTAssertTrue(normalized.contains("0\nTABLE\n2\nBLOCK_RECORD\n"))
        XCTAssertTrue(normalized.contains("100\nAcDbLayerTableRecord\n"))
    }

    func testV93DXFLayersMapArchitecturalSemanticsToIFCClasses() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let roomIndex = try XCTUnwrap(project.rooms.indices.first)
        if let doorIndex = project.rooms[roomIndex].openings.firstIndex(where: { $0.kind == .door }) {
            project.rooms[roomIndex].openings[doorIndex].doorSwing = .leftIn
        }
        let engine = DXFExchangeEngine()
        let preview = engine.preview(for: project, representation: .semanticObservations)
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .wall && $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue })
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .door && $0.layer == ArchitecturalDraftingConvention.Layer.door.rawValue })
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .window && $0.layer == ArchitecturalDraftingConvention.Layer.window.rawValue })
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .opening && $0.layer == ArchitecturalDraftingConvention.Layer.opening.rawValue })
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .space && $0.layer == ArchitecturalDraftingConvention.Layer.space.rawValue })

        let normalized = engine.export(project: project, representation: .semanticObservations).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(normalized.contains("A-SPACE"))
        XCTAssertTrue(normalized.contains("IfcWall"))
        XCTAssertTrue(normalized.contains("IfcDoor"))
        XCTAssertTrue(normalized.contains("IfcWindow"))
        XCTAssertTrue(normalized.contains("IfcOpeningElement"))
        XCTAssertTrue(normalized.contains("IfcSpace"))
    }

    func testV93DXFRejectsNonFiniteGeometryBeforeWritingFile() {
        let wall = PlanOpsisWall(start: Point2D(x: .nan, y: 0), length: 3_000, angleRadians: 0, height: 2_800, thickness: 200)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall])])
        let result = DXFExchangeEngine().exportValidated(project: project)
        XCTAssertFalse(result.canWrite)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.severity == .error && $0.message.contains("non-finite") })
    }

    func testV93DXFTechnicalLayersAreNonPlotAndArchitecturalLayersRemainVisible() {
        XCTAssertFalse(ArchitecturalDraftingConvention.isPlotLayer(.wallCenter))
        XCTAssertFalse(ArchitecturalDraftingConvention.isPlotLayer(.metadata))
        XCTAssertFalse(ArchitecturalDraftingConvention.isInitiallyVisible(.wallCenter))
        XCTAssertFalse(ArchitecturalDraftingConvention.isInitiallyVisible(.metadata))
        XCTAssertTrue(ArchitecturalDraftingConvention.isPlotLayer(.wall))
        XCTAssertTrue(ArchitecturalDraftingConvention.isInitiallyVisible(.wall))
        XCTAssertFalse(ArchitecturalDraftingConvention.isPlotLayer(.space))
        XCTAssertFalse(ArchitecturalDraftingConvention.isInitiallyVisible(.space))
        XCTAssertEqual(ArchitecturalDraftingConvention.layer(for: .space), .space)
    }

    func testV94DXFWallRepresentationUsesFacesWithoutFalseRectangleCaps() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        let walls = preview.primitives.filter { $0.ifcClass == .wall }
        XCTAssertFalse(walls.isEmpty)
        XCTAssertTrue(walls.allSatisfy { $0.layer == ArchitecturalDraftingConvention.Layer.wall.rawValue && $0.kind == .line && $0.points.count == 2 })
        XCTAssertFalse(walls.contains { $0.kind == .polyline })
    }

    func testV94DXFGenericOpeningIsVoidWithJambsOnly() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        let genericOpening = try XCTUnwrap(project.rooms[0].openings.first { $0.kind == .opening })
        let primitives = preview.primitives.filter { $0.objectIDs.contains(genericOpening.id) }
        XCTAssertEqual(primitives.filter { $0.layer == ArchitecturalDraftingConvention.Layer.opening.rawValue && $0.kind == .line }.count, 2)
        XCTAssertTrue(primitives.allSatisfy { $0.ifcClass == .opening })
    }

    func testV94DXFSpaceUsesClearInteriorAreaAndIsSemanticNonPlot() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        let space = try XCTUnwrap(preview.primitives.first { $0.ifcClass == .space })
        XCTAssertEqual(space.layer, ArchitecturalDraftingConvention.Layer.space.rawValue)
        XCTAssertEqual(space.kind, .polyline)
        XCTAssertEqual(space.points.count, 4)
        var twiceArea = 0.0
        for index in space.points.indices {
            let next = space.points[(index + 1) % space.points.count]
            twiceArea += space.points[index].x * next.y - next.x * space.points[index].y
        }
        let area = abs(twiceArea) * 0.5 / 1_000_000
        XCTAssertEqual(area, 11.1744, accuracy: 0.01)
        XCTAssertFalse(ArchitecturalDraftingConvention.isPlotLayer(.space))
        XCTAssertFalse(ArchitecturalDraftingConvention.isInitiallyVisible(.space))
        XCTAssertTrue(preview.primitives.contains { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue && ($0.text ?? "").contains("11.17") })
    }

    func testV94DXFIFCClassGeometryStaysOnCorrectArchitecturalLayers() {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        if let doorIndex = project.rooms[0].openings.firstIndex(where: { $0.kind == .door }) {
            project.rooms[0].openings[doorIndex].doorSwing = .leftIn
        }
        let primitives = DXFExchangeEngine().preview(for: project, representation: .semanticObservations).primitives
        for primitive in primitives {
            switch primitive.ifcClass {
            case .wall?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.wall.rawValue)
            case .door?: XCTAssertTrue([ArchitecturalDraftingConvention.Layer.door.rawValue, ArchitecturalDraftingConvention.Layer.doorSwing.rawValue].contains(primitive.layer))
            case .window?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.window.rawValue)
            case .opening?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.opening.rawValue)
            case .space?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.space.rawValue)
            case .column?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.column.rawValue)
            case .beam?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.beam.rawValue)
            case .furnishing?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.furnishing.rawValue)
            case .sanitaryTerminal?: XCTAssertEqual(primitive.layer, ArchitecturalDraftingConvention.Layer.sanitary.rawValue)
            case nil: break
            }
        }
    }

    func testV94DXFTextIsCenteredAndDimensionsCarryRotation() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let engine = DXFExchangeEngine()
        let preview = engine.preview(for: project, representation: .semanticObservations)
        XCTAssertTrue(preview.primitives.contains { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue && $0.rotationDegrees != nil })
        let normalized = engine.export(project: project, representation: .semanticObservations).replacingOccurrences(of: "\r\n", with: "\n")
        // v9.5: 11/21 alignment point must remain in the first AcDbText subclass,
        // before the second AcDbText marker that carries group 73.
        XCTAssertTrue(normalized.range(of: "\n72\n1\n11\n") != nil)
        XCTAssertTrue(normalized.range(of: "\n31\n0\n100\nAcDbText\n73\n2\n") != nil)
    }

    func testV95DimensionTextStaysOutsideClearRoomBoundary() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        let space = try XCTUnwrap(preview.primitives.first { $0.ifcClass == .space })
        let labels = preview.primitives.filter { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue }
        XCTAssertEqual(labels.count, project.rooms[0].walls.count)
        for label in labels {
            let point = try XCTUnwrap(label.points.first)
            XCTAssertFalse(testPointInPolygon(point, polygon: space.points), "Dimension label must remain outside IfcSpace clear boundary")
        }
    }

    func testV95WallFacesAreCutAtEveryHostedOpening() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let room = try XCTUnwrap(project.rooms.first)
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        for opening in room.openings {
            let wall = try XCTUnwrap(room.walls.first { $0.id == opening.parameters.hostWallID })
            let start = opening.parameters.offsetAlongWall - opening.parameters.width * 0.5
            let end = opening.parameters.offsetAlongWall + opening.parameters.width * 0.5
            let wallLines = preview.primitives.filter {
                $0.ifcClass == .wall && $0.objectIDs.contains(wall.id) && $0.kind == .line && $0.points.count == 2
            }
            XCTAssertFalse(wallLines.isEmpty)
            for line in wallLines {
                let t0 = (line.points[0] - wall.start).dot(wall.direction)
                let t1 = (line.points[1] - wall.start).dot(wall.direction)
                let lo = min(t0, t1)
                let hi = max(t0, t1)
                XCTAssertFalse(lo < end - 1 && hi > start + 1, "A-WALL face must not bridge the hosted opening void")
            }
        }
    }

    func testV95RotatedRoomKeepsDimensionsOutsideAndGeometryFinite() throws {
        let angle = Double.pi / 6
        let origin = Point2D(x: 1200, y: -800)
        func rotate(_ p: Point2D) -> Point2D {
            Point2D(
                x: origin.x + p.x * cos(angle) - p.y * sin(angle),
                y: origin.y + p.x * sin(angle) + p.y * cos(angle)
            )
        }
        let base = [Point2D(x: 0, y: 0), Point2D(x: 4200, y: 0), Point2D(x: 4200, y: 2800), Point2D(x: 0, y: 2800)]
        var walls: [PlanOpsisWall] = []
        for i in base.indices {
            let a = rotate(base[i])
            let b = rotate(base[(i + 1) % base.count])
            let v = b - a
            walls.append(PlanOpsisWall(start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: 2800, thickness: 180, confidence: .high))
        }
        let doorParameters = HostedOpeningParameters(
            hostWallID: walls[0].id,
            offsetAlongWall: 1200,
            width: 900,
            height: 2100,
            sillHeight: 0,
            confidence: .high
        )
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: doorParameters, swing: .leftIn))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: walls, openings: [door])])
        let result = DXFExchangeEngine().exportValidated(project: project, representation: .semanticObservations)
        XCTAssertTrue(result.canWrite)
        XCTAssertFalse(result.text.isEmpty)
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        let space = try XCTUnwrap(preview.primitives.first { $0.ifcClass == .space })
        let labels = preview.primitives.filter { $0.kind == .text && $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue }
        XCTAssertEqual(labels.count, 4)
        for label in labels {
            let point = try XCTUnwrap(label.points.first)
            XCTAssertFalse(testPointInPolygon(point, polygon: space.points))
        }
        XCTAssertTrue(preview.primitives.flatMap(\.points).allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testV95SingleRoomReconciledAndObservedShareTheSameArchitecturalDraft() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let engine = DXFExchangeEngine()
        let observed = engine.preview(for: project, representation: .semanticObservations).primitives.filter {
            [ArchitecturalDraftingConvention.Layer.wall.rawValue,
             ArchitecturalDraftingConvention.Layer.door.rawValue,
             ArchitecturalDraftingConvention.Layer.window.rawValue,
             ArchitecturalDraftingConvention.Layer.opening.rawValue,
             ArchitecturalDraftingConvention.Layer.dimensions.rawValue].contains($0.layer)
        }
        let reconciled = engine.preview(for: project, representation: .reconciledPhysical).primitives.filter {
            [ArchitecturalDraftingConvention.Layer.wall.rawValue,
             ArchitecturalDraftingConvention.Layer.door.rawValue,
             ArchitecturalDraftingConvention.Layer.window.rawValue,
             ArchitecturalDraftingConvention.Layer.opening.rawValue,
             ArchitecturalDraftingConvention.Layer.dimensions.rawValue].contains($0.layer)
        }
        XCTAssertEqual(observed, reconciled)
    }

    func testV95DXFTextAlignmentRecordOrderIsR2000Compatible() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let dxf = DXFExchangeEngine().export(project: project, representation: .semanticObservations).replacingOccurrences(of: "\r\n", with: "\n")
        guard let range72 = dxf.range(of: "\n72\n1\n11\n") else {
            return XCTFail("Expected centered TEXT alignment point after group 72")
        }
        let suffix = dxf[range72.lowerBound...]
        XCTAssertNotNil(suffix.range(of: "\n31\n0\n100\nAcDbText\n73\n2\n"))
    }


    func testV96SemanticEditorCreatesTypedDoorsWindowsAndComponents() throws {
        let engine = SemanticObjectEditingEngine()
        let wall = PlanOpsisWall(start: .zero, length: 6_000, angleRadians: 0, height: 2_800, thickness: 200)
        let room = PlanOpsisRoom(walls: [wall])
        var project = PlanOpsisProject(rooms: [room])

        let doorResult = try XCTUnwrap(engine.addOpening(kind: .door, to: room.id, hostWallID: wall.id, center: Point2D(x: 1_500, y: 0), project: project, doorOperation: .doubleHinged))
        project = doorResult.0
        let windowResult = try XCTUnwrap(engine.addOpening(kind: .window, to: room.id, hostWallID: wall.id, center: Point2D(x: 4_000, y: 0), project: project, windowOperation: .sliding))
        project = windowResult.0
        let componentResult = try XCTUnwrap(engine.addComponent(kind: .table, to: room.id, position: Point2D(x: 2_000, y: 1_500), project: project))
        project = componentResult.0

        let door = try XCTUnwrap(project.rooms[0].openings.first { $0.id == doorResult.1 })
        let window = try XCTUnwrap(project.rooms[0].openings.first { $0.id == windowResult.1 })
        let component = try XCTUnwrap(project.rooms[0].components.first { $0.id == componentResult.1 })
        XCTAssertEqual(door.doorOperation, .doubleHinged)
        XCTAssertEqual(window.windowOperation, .sliding)
        XCTAssertEqual(component.kind, .table)
        XCTAssertEqual(component.width, 1_200, accuracy: 0.001)
        XCTAssertEqual(component.depth, 750, accuracy: 0.001)
    }

    func testV96ComponentPersistencePreservesStableUUIDAndParameters() throws {
        let component = PlanOpsisComponent(kind: .sofa, position: Point2D(x: 1_200, y: 2_400), width: 2_100, depth: 900, height: 760, rotationRadians: .pi / 6)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [component])])
        let data = try JSONEncoder().encode(project)
        let reopened = try JSONDecoder().decode(PlanOpsisProject.self, from: data)
        let decoded = try XCTUnwrap(reopened.rooms.first?.components.first)
        XCTAssertEqual(decoded.id, component.id)
        XCTAssertEqual(decoded.kind, .sofa)
        XCTAssertEqual(decoded.position, component.position)
        XCTAssertEqual(decoded.width, 2_100, accuracy: 0.001)
        XCTAssertEqual(decoded.rotationRadians, .pi / 6, accuracy: 1e-9)
    }

    func testV96RoomJSONWithoutComponentsRemainsBackwardCompatible() throws {
        let room = PlanOpsisRoom(walls: [PlanOpsisWall(start: .zero, length: 1_000, angleRadians: 0, height: 2_800, thickness: 200)])
        let data = try JSONEncoder().encode(room)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "components")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PlanOpsisRoom.self, from: legacyData)
        XCTAssertTrue(decoded.components.isEmpty)
        XCTAssertEqual(decoded.walls.count, 1)
    }

    func testV96DeletingComponentDoesNotMutateArchitecture() throws {
        let wall = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 200)
        let component = PlanOpsisComponent(kind: .chair, position: Point2D(x: 1_000, y: 1_000))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], components: [component])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().delete(entityID: component.id, from: project))
        XCTAssertEqual(result.project.rooms[0].walls, [wall])
        XCTAssertTrue(result.project.rooms[0].components.isEmpty)
        XCTAssertEqual(result.deletedIDs, [component.id])
    }

    func testV96DXFComponentsUseCorrectIFCLayers() {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        project.rooms[0].components = [
            PlanOpsisComponent(kind: .column, position: Point2D(x: 700, y: 700)),
            PlanOpsisComponent(kind: .bed, position: Point2D(x: 1_800, y: 1_500)),
            PlanOpsisComponent(kind: .wc, position: Point2D(x: 3_200, y: 1_000))
        ]
        let primitives = DXFExchangeEngine().preview(for: project, representation: .semanticObservations).primitives
        let column = primitives.filter { $0.objectIDs.contains(project.rooms[0].components[0].id) }
        let bed = primitives.filter { $0.objectIDs.contains(project.rooms[0].components[1].id) }
        let wc = primitives.filter { $0.objectIDs.contains(project.rooms[0].components[2].id) }
        XCTAssertFalse(column.isEmpty); XCTAssertTrue(column.allSatisfy { $0.ifcClass == .column && $0.layer == ArchitecturalDraftingConvention.Layer.column.rawValue })
        XCTAssertFalse(bed.isEmpty); XCTAssertTrue(bed.allSatisfy { $0.ifcClass == .furnishing && $0.layer == ArchitecturalDraftingConvention.Layer.furnishing.rawValue })
        XCTAssertFalse(wc.isEmpty); XCTAssertTrue(wc.allSatisfy { $0.ifcClass == .sanitaryTerminal && $0.layer == ArchitecturalDraftingConvention.Layer.sanitary.rawValue })
    }

    func testV96SlidingDoorHasNoSwingArcAndCarriesSubtype() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let index = try XCTUnwrap(project.rooms[0].openings.firstIndex { $0.kind == .door })
        project.rooms[0].openings[index].doorOperation = .sliding
        project.rooms[0].openings[index].doorSwing = .unspecified
        let doorID = project.rooms[0].openings[index].id
        let primitives = DXFExchangeEngine().preview(for: project, representation: .semanticObservations).primitives.filter { $0.objectIDs.contains(doorID) }
        XCTAssertFalse(primitives.isEmpty)
        XCTAssertFalse(primitives.contains { $0.kind == .arc })
        XCTAssertTrue(primitives.contains { $0.semanticType == "door.sliding" && $0.layer == ArchitecturalDraftingConvention.Layer.door.rawValue })
    }

    func testV96DoubleHingedDoorProducesTwoLeavesAndSwingArcs() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let index = try XCTUnwrap(project.rooms[0].openings.firstIndex { $0.kind == .door })
        project.rooms[0].openings[index].doorOperation = .doubleHinged
        project.rooms[0].openings[index].doorSwing = .leftIn
        let doorID = project.rooms[0].openings[index].id
        let primitives = DXFExchangeEngine().preview(for: project, representation: .semanticObservations).primitives.filter { $0.objectIDs.contains(doorID) }
        XCTAssertEqual(primitives.filter { $0.id.contains("door-double-leaf") }.count, 2)
        XCTAssertEqual(primitives.filter { $0.kind == .arc }.count, 2)
        XCTAssertTrue(primitives.filter { $0.kind == .arc }.allSatisfy { $0.layer == ArchitecturalDraftingConvention.Layer.doorSwing.rawValue })
    }

    func testV96DXFLineweightsQuantizeToLegalR2000Values() {
        XCTAssertEqual(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(0.1925), 18)
        XCTAssertEqual(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(0.117), 13)
        XCTAssertEqual(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(0.135), 13)
        XCTAssertEqual(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: .column), 35)
        XCTAssertEqual(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: .furnishing), 18)
    }

    func testV96DXFRoundTripPreservesFamiliesAndComponents() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let doorIndex = try XCTUnwrap(project.rooms[0].openings.firstIndex { $0.kind == .door })
        let windowIndex = try XCTUnwrap(project.rooms[0].openings.firstIndex { $0.kind == .window })
        project.rooms[0].openings[doorIndex].doorOperation = .pocket
        project.rooms[0].openings[doorIndex].doorSwing = .unspecified
        project.rooms[0].openings[windowIndex].windowOperation = .doubleCasement
        let component = PlanOpsisComponent(kind: .sink, position: Point2D(x: 2_250, y: 1_150), width: 650, depth: 520, height: 860, rotationRadians: 0.2)
        project.rooms[0].components.append(component)

        let text = DXFExchangeEngine().export(project: project, representation: .semanticObservations)
        let imported = try XCTUnwrap(DXFExchangeEngine().import(text).project)
        let importedDoor = try XCTUnwrap(imported.rooms.flatMap(\.openings).first { $0.id == project.rooms[0].openings[doorIndex].id })
        let importedWindow = try XCTUnwrap(imported.rooms.flatMap(\.openings).first { $0.id == project.rooms[0].openings[windowIndex].id })
        let importedComponent = try XCTUnwrap(imported.rooms.flatMap(\.components).first { $0.id == component.id })
        XCTAssertEqual(importedDoor.doorOperation, .pocket)
        XCTAssertEqual(importedWindow.windowOperation, .doubleCasement)
        XCTAssertEqual(importedComponent, component)
    }


    func testV97DuplicateComponentCreatesIndependentUUIDAndOffset() throws {
        let component = PlanOpsisComponent(kind: .table, position: Point2D(x: 1_000, y: 1_500), width: 1_400, depth: 800, height: 760, rotationRadians: 0.25)
        let room = PlanOpsisRoom(walls: [], openings: [], components: [component])
        let project = PlanOpsisProject(rooms: [room])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().duplicate(entityID: component.id, in: project, offsetMM: 250))
        let copy = try XCTUnwrap(result.0.rooms[0].components.first { $0.id == result.1 })
        XCTAssertNotEqual(copy.id, component.id)
        XCTAssertEqual(copy.kind, component.kind)
        XCTAssertEqual(copy.position.x, 1_250, accuracy: 1e-9)
        XCTAssertEqual(copy.position.y, 1_750, accuracy: 1e-9)
        XCTAssertEqual(copy.width, component.width, accuracy: 1e-9)
        XCTAssertEqual(copy.depth, component.depth, accuracy: 1e-9)
        XCTAssertEqual(copy.rotationRadians, component.rotationRadians, accuracy: 1e-9)
    }

    func testV97DuplicateWallRemapsHostedOpeningToNewWall() throws {
        let wall = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 120)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(
            hostWallID: wall.id,
            offsetAlongWall: 1_000,
            width: 900,
            height: 2_100,
            sillHeight: 0
        ), swing: .rightIn, operation: .singleHinged))
        let room = PlanOpsisRoom(walls: [wall], openings: [door])
        let project = PlanOpsisProject(rooms: [room])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().duplicate(entityID: wall.id, in: project, offsetMM: 300))
        let copiedWall = try XCTUnwrap(result.0.rooms[0].walls.first { $0.id == result.1 })
        XCTAssertNotEqual(copiedWall.id, wall.id)
        XCTAssertNil(copiedWall.sourceRoomPlanID)
        XCTAssertEqual(copiedWall.start.y, 300, accuracy: 1e-9)
        let copiedDoor = try XCTUnwrap(result.0.rooms[0].openings.first { $0.id != door.id })
        XCTAssertEqual(copiedDoor.parameters.hostWallID, copiedWall.id)
        XCTAssertNotEqual(copiedDoor.id, door.id)
        XCTAssertEqual(copiedDoor.doorSwing, .rightIn)
        XCTAssertEqual(copiedDoor.doorOperation, .singleHinged)
    }

    func testV97DuplicateOpeningKeepsHostAndCreatesIndependentIdentity() throws {
        let wall = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 120)
        let window = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(
            hostWallID: wall.id,
            offsetAlongWall: 1_000,
            width: 1_200,
            height: 1_200,
            sillHeight: 900
        ), operation: .sliding))
        let room = PlanOpsisRoom(walls: [wall], openings: [window])
        let project = PlanOpsisProject(rooms: [room])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().duplicate(entityID: window.id, in: project, offsetMM: 250))
        let copy = try XCTUnwrap(result.0.rooms[0].openings.first { $0.id == result.1 })
        XCTAssertEqual(copy.parameters.hostWallID, wall.id)
        XCTAssertNotEqual(copy.id, window.id)
        XCTAssertEqual(copy.windowOperation, .sliding)
        XCTAssertEqual(copy.parameters.offsetAlongWall, 2_450, accuracy: 1e-9)
        XCTAssertNil(copy.parameters.sourceRoomPlanID)
    }

    func testV97ComponentMoveSnapNudgeAndRotateAreDeterministic() throws {
        let component = PlanOpsisComponent(kind: .chair, position: Point2D(x: 120, y: 180), rotationRadians: 0)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [component])])
        let engine = SemanticObjectEditingEngine()
        let moved = try XCTUnwrap(engine.moveComponent(entityID: component.id, to: Point2D(x: 376, y: 624), in: project, gridSpacing: 250))
        XCTAssertEqual(moved.rooms[0].components[0].position, Point2D(x: 500, y: 500))
        let nudged = try XCTUnwrap(engine.nudgeComponent(entityID: component.id, delta: Point2D(x: 100, y: -50), in: moved))
        XCTAssertEqual(nudged.rooms[0].components[0].position, Point2D(x: 600, y: 450))
        let rotated = try XCTUnwrap(engine.rotateComponent(entityID: component.id, byDegrees: 88, in: nudged, snapIncrementDegrees: 15))
        XCTAssertEqual(rotated.rooms[0].components[0].rotationRadians * 180 / .pi, 90, accuracy: 1e-9)
    }


    func testV98BatchDeleteCascadesHostedOpeningsAndDeletesComponentsAtomically() throws {
        let wall = PlanOpsisWall(start: .zero, length: 4_000, angleRadians: 0, height: 2_800, thickness: 120)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(
            hostWallID: wall.id, offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0
        )))
        let table = PlanOpsisComponent(kind: .table, position: Point2D(x: 2_000, y: 1_000))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door], components: [table])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().delete(entityIDs: [wall.id, door.id, table.id], from: project))
        XCTAssertTrue(result.project.rooms[0].walls.isEmpty)
        XCTAssertTrue(result.project.rooms[0].openings.isEmpty)
        XCTAssertTrue(result.project.rooms[0].components.isEmpty)
        XCTAssertEqual(Set(result.deletedIDs), Set([wall.id, door.id, table.id]))
    }

    func testV98EditHistoryUndoRedoRestoresProjectAndSelection() throws {
        let a = PlanOpsisComponent(kind: .chair, position: Point2D(x: 100, y: 100))
        let b = PlanOpsisComponent(kind: .chair, position: Point2D(x: 500, y: 100))
        let projectA = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [a])])
        let projectB = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [a, b])])
        var history = PlanOpsisEditHistory(maxDepth: 10)
        history.record(EditorHistorySnapshot(project: projectA, selectionIDs: [a.id], primarySelectionID: a.id), label: "Add chair")
        let undo = try XCTUnwrap(history.undo(current: EditorHistorySnapshot(project: projectB, selectionIDs: [b.id], primarySelectionID: b.id)))
        XCTAssertEqual(undo.project, projectA)
        XCTAssertEqual(undo.selectionIDs, [a.id])
        XCTAssertEqual(undo.primarySelectionID, a.id)
        let redo = try XCTUnwrap(history.redo(current: undo))
        XCTAssertEqual(redo.project, projectB)
        XCTAssertEqual(redo.selectionIDs, [b.id])
    }

    func testV98EditHistoryNewRecordClearsRedoBranch() throws {
        let base = PlanOpsisProject(rooms: [PlanOpsisRoom()])
        let c1 = PlanOpsisComponent(kind: .chair, position: .zero)
        let p1 = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [c1])])
        var history = PlanOpsisEditHistory()
        history.record(EditorHistorySnapshot(project: base), label: "First")
        _ = try XCTUnwrap(history.undo(current: EditorHistorySnapshot(project: p1)))
        XCTAssertTrue(history.canRedo)
        history.record(EditorHistorySnapshot(project: base), label: "Branch")
        XCTAssertFalse(history.canRedo)
    }

    func testV98AlignComponentsUsesRotatedFootprintBounds() throws {
        let a = PlanOpsisComponent(kind: .table, position: Point2D(x: 1_000, y: 1_000), width: 800, depth: 400, rotationRadians: 0)
        let b = PlanOpsisComponent(kind: .chair, position: Point2D(x: 2_000, y: 1_600), width: 500, depth: 500, rotationRadians: .pi / 4)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [a, b])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().alignComponents(entityIDs: [a.id, b.id], alignment: .left, in: project))
        let components = result.project.rooms[0].components
        let minXs = components.map { $0.footprint.map(\.x).min()! }
        XCTAssertEqual(minXs[0], minXs[1], accuracy: 1e-8)
    }

    func testV98DistributeComponentsCreatesEqualHorizontalClearGaps() throws {
        let a = PlanOpsisComponent(kind: .chair, position: Point2D(x: 250, y: 0), width: 500, depth: 500)
        let b = PlanOpsisComponent(kind: .chair, position: Point2D(x: 1_100, y: 0), width: 400, depth: 500)
        let c = PlanOpsisComponent(kind: .chair, position: Point2D(x: 2_250, y: 0), width: 500, depth: 500)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [a, b, c])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().distributeComponents(entityIDs: [a.id, b.id, c.id], axis: .horizontal, in: project))
        let ordered = result.project.rooms[0].components.sorted { $0.footprint.map(\.x).min()! < $1.footprint.map(\.x).min()! }
        let gap1 = ordered[1].footprint.map(\.x).min()! - ordered[0].footprint.map(\.x).max()!
        let gap2 = ordered[2].footprint.map(\.x).min()! - ordered[1].footprint.map(\.x).max()!
        XCTAssertEqual(gap1, gap2, accuracy: 1e-8)
        XCTAssertEqual(ordered.first!.position, a.position)
        XCTAssertEqual(ordered.last!.position, c.position)
    }

    func testV98LinearArrayCreatesIndependentUUIDsAtExactStep() throws {
        let source = PlanOpsisComponent(kind: .column, position: Point2D(x: 100, y: 200), width: 300, depth: 300)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [source])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().linearArrayComponents(entityIDs: [source.id], axis: .horizontal, count: 4, stepMM: 750, in: project))
        XCTAssertEqual(result.createdIDs.count, 3)
        let xs = result.project.rooms[0].components.map(\.position.x).sorted()
        XCTAssertEqual(xs, [100, 850, 1_600, 2_350])
        XCTAssertEqual(Set(result.project.rooms[0].components.map(\.id)).count, 4)
    }

    func testV98GroupArrayPreservesRelativeGeometry() throws {
        let a = PlanOpsisComponent(kind: .chair, position: Point2D(x: 0, y: 0))
        let b = PlanOpsisComponent(kind: .table, position: Point2D(x: 1_200, y: 300))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [a, b])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().linearArrayComponents(entityIDs: [a.id, b.id], axis: .vertical, count: 2, stepMM: 2_000, in: project))
        let copies = result.project.rooms[0].components.filter { result.createdIDs.contains($0.id) }
        XCTAssertEqual(copies.count, 2)
        let copyChair = try XCTUnwrap(copies.first { $0.kind == .chair })
        let copyTable = try XCTUnwrap(copies.first { $0.kind == .table })
        XCTAssertEqual(copyTable.position.x - copyChair.position.x, 1_200, accuracy: 1e-9)
        XCTAssertEqual(copyTable.position.y - copyChair.position.y, 300, accuracy: 1e-9)
        XCTAssertEqual(copyChair.position.y, 2_000, accuracy: 1e-9)
    }

    func testV99MoveConnectedWallGroupPreservesHostedOpeningAndJunction() throws {
        let a = PlanOpsisWall(start: .zero, length: 2_000, angleRadians: 0, height: 2_800, thickness: 120)
        let b = PlanOpsisWall(start: a.end, length: 1_500, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: a.id, offsetAlongWall: 800, width: 900, height: 2_100, sillHeight: 0)))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [a, b], openings: [door])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().moveArchitecturalSelection(entityIDs: [a.id, b.id], delta: Point2D(x: 500, y: -250), in: project))
        let movedA = try XCTUnwrap(result.project.rooms[0].walls.first { $0.id == a.id })
        let movedB = try XCTUnwrap(result.project.rooms[0].walls.first { $0.id == b.id })
        let movedDoor = try XCTUnwrap(result.project.rooms[0].openings.first { $0.id == door.id })
        XCTAssertEqual(movedA.start, Point2D(x: 500, y: -250))
        XCTAssertEqual(movedA.end, movedB.start)
        XCTAssertEqual(movedDoor.parameters.hostWallID, a.id)
        XCTAssertEqual(movedDoor.parameters.offsetAlongWall, 800, accuracy: 1e-9)
    }

    func testV99MoveConnectedWallSubsetIsRejectedToProtectTopology() {
        let a = PlanOpsisWall(start: .zero, length: 2_000, angleRadians: 0, height: 2_800, thickness: 120)
        let b = PlanOpsisWall(start: a.end, length: 1_500, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [a, b])])
        XCTAssertNil(SemanticObjectEditingEngine().moveArchitecturalSelection(entityIDs: [a.id], delta: Point2D(x: 100, y: 0), in: project))
        XCTAssertNil(SemanticObjectEditingEngine().offsetWall(wallID: a.id, distanceMM: 100, in: project))
    }

    func testV99CopyWallGroupRemapsHostedOpeningsAndClearsProvenance() throws {
        let wall = PlanOpsisWall(sourceRoomPlanID: UUID(), start: .zero, length: 3_000, angleRadians: 0, height: 2_800, thickness: 120, confidence: .high)
        let sourceOpeningID = UUID()
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(id: UUID(), sourceRoomPlanID: sourceOpeningID, hostWallID: wall.id, offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0, confidence: .high), swing: .leftIn))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().copyArchitecturalSelection(entityIDs: [wall.id], delta: Point2D(x: 0, y: 500), in: project))
        let copiedWall = try XCTUnwrap(result.project.rooms[0].walls.first { $0.id != wall.id })
        let copiedDoor = try XCTUnwrap(result.project.rooms[0].openings.first { $0.id != door.id })
        XCTAssertNil(copiedWall.sourceRoomPlanID)
        XCTAssertEqual(copiedWall.confidence, .unknown)
        XCTAssertEqual(copiedDoor.parameters.hostWallID, copiedWall.id)
        XCTAssertNil(copiedDoor.parameters.sourceRoomPlanID)
        XCTAssertEqual(copiedDoor.doorSwing, .leftIn)
    }

    func testV99RotateAndMirrorWallWithDoorPreservesHostingAndMirrorsHandedness() throws {
        let wall = PlanOpsisWall(start: Point2D(x: 0, y: 0), length: 2_000, angleRadians: 0, height: 2_800, thickness: 120)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: wall.id, offsetAlongWall: 700, width: 800, height: 2_100, sillHeight: 0), swing: .leftIn))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door])])
        let rotated = try XCTUnwrap(SemanticObjectEditingEngine().rotateArchitecturalSelection(entityIDs: [wall.id], degrees: 90, in: project))
        let rw = rotated.project.rooms[0].walls[0]
        XCTAssertEqual(rw.length, wall.length, accuracy: 1e-8)
        XCTAssertEqual(rw.angleRadians, .pi / 2, accuracy: 1e-8)
        XCTAssertEqual(rotated.project.rooms[0].openings[0].parameters.offsetAlongWall, 700, accuracy: 1e-9)
        let mirrored = try XCTUnwrap(SemanticObjectEditingEngine().mirrorArchitecturalSelection(entityIDs: [wall.id], axis: .vertical, in: project))
        XCTAssertEqual(mirrored.project.rooms[0].openings[0].doorSwing, .rightIn)
        XCTAssertEqual(mirrored.project.rooms[0].openings[0].parameters.hostWallID, wall.id)
    }

    func testV99OffsetIsParallelAndKeepsHostedOpeningParameters() throws {
        let wall = PlanOpsisWall(start: Point2D(x: 100, y: 200), length: 2_000, angleRadians: 0, height: 2_800, thickness: 120)
        let window = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(hostWallID: wall.id, offsetAlongWall: 1_100, width: 1_000, height: 1_200, sillHeight: 900)))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [window])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().offsetWall(wallID: wall.id, distanceMM: 250, in: project))
        let offset = result.project.rooms[0].walls[0]
        XCTAssertEqual(offset.start, Point2D(x: 100, y: 450))
        XCTAssertEqual(offset.length, wall.length, accuracy: 1e-9)
        XCTAssertEqual(offset.angleRadians, wall.angleRadians, accuracy: 1e-9)
        XCTAssertEqual(result.project.rooms[0].openings[0].parameters, window.parameters)
    }

    func testV99TrimExtendToNearestIntersectionPreservesOpeningWorldStation() throws {
        let wall = PlanOpsisWall(start: .zero, length: 1_000, angleRadians: 0, height: 2_800, thickness: 120)
        let target = PlanOpsisWall(start: Point2D(x: 1_500, y: -500), length: 1_000, angleRadians: .pi / 2, height: 2_800, thickness: 120)
        let opening = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(hostWallID: wall.id, offsetAlongWall: 600, width: 400, height: 1_000, sillHeight: 900)))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall, target], openings: [opening])])
        let result = try XCTUnwrap(SemanticObjectEditingEngine().trimOrExtendWallToNearestIntersection(wallID: wall.id, in: project))
        let edited = try XCTUnwrap(result.project.rooms[0].walls.first { $0.id == wall.id })
        XCTAssertEqual(edited.end.x, 1_500, accuracy: 1e-8)
        XCTAssertEqual(edited.end.y, 0, accuracy: 1e-8)
        XCTAssertEqual(edited.length, 1_500, accuracy: 1e-8)
        XCTAssertEqual(result.project.rooms[0].openings[0].parameters.offsetAlongWall, 600, accuracy: 1e-9)
    }

    func testV993DoubleCasementUsesParallelRailsAndSingleMullion() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let index = try XCTUnwrap(project.rooms[0].openings.firstIndex { $0.kind == .window })
        project.rooms[0].openings[index].windowOperation = .doubleCasement
        let windowID = project.rooms[0].openings[index].id
        let primitives = DXFExchangeEngine()
            .preview(for: project, representation: .semanticObservations)
            .primitives
            .filter { $0.objectIDs.contains(windowID) }

        XCTAssertEqual(primitives.filter { $0.id.contains("window-rail-") }.count, 2)
        XCTAssertEqual(primitives.filter { $0.id.contains("window-mullion") }.count, 1)
        XCTAssertFalse(primitives.contains { $0.id.contains("window-casement-a") || $0.id.contains("window-casement-b") })
    }

    func testV993ChairDXFHasSeatBackRailsAndFourLegMarkers() {
        let chair = PlanOpsisComponent(kind: .chair, position: Point2D(x: 1_000, y: 1_000), width: 500, depth: 500, height: 850)
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(components: [chair])])
        let primitives = DXFExchangeEngine()
            .preview(for: project, representation: .semanticObservations)
            .primitives
            .filter { $0.objectIDs.contains(chair.id) }

        XCTAssertEqual(primitives.filter { $0.id.contains(":seat") }.count, 1)
        XCTAssertEqual(primitives.filter { $0.id.contains(":back:") }.count, 2)
        XCTAssertEqual(primitives.filter { $0.id.contains(":leg:") }.count, 4)
    }

    func testV10IFCGUIDCompressionMatchesBuildingSMARTReferenceAlgorithm() throws {
        let zero = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let sample = try XCTUnwrap(UUID(uuidString: "DA85046C-CE8A-4226-A38D-732788C5C1E7"))
        let sample2 = try XCTUnwrap(UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678"))
        XCTAssertEqual(PlanOpsisExchangeIdentity.ifcGlobalID(for: zero), "0000000000000000000000")
        XCTAssertEqual(PlanOpsisExchangeIdentity.ifcGlobalID(for: sample), "3QXGHipef29gEDSoU8nS7d")
        XCTAssertEqual(PlanOpsisExchangeIdentity.ifcGlobalID(for: sample2), "0ID5Pu4ZHMU9gytl0ID5Pu")
    }

    func testV10IFC4ExportsSemanticHierarchyGeometryAndRelationships() throws {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        project.rooms[0].components.append(PlanOpsisComponent(kind: .chair, position: Point2D(x: 1_200, y: 1_000)))
        project.rooms[0].components.append(PlanOpsisComponent(kind: .column, position: Point2D(x: 500, y: 500)))
        project.rooms[0].components.append(PlanOpsisComponent(kind: .wc, position: Point2D(x: 2_000, y: 700)))
        let result = IFC4ExchangeEngine().exportValidated(project: project)
        XCTAssertTrue(result.canWrite)
        XCTAssertTrue(result.text.hasPrefix("ISO-10303-21;\r\nHEADER;"))
        XCTAssertTrue(result.text.contains("FILE_SCHEMA(('IFC4'));"))
        XCTAssertTrue(result.text.contains("IFCPROJECT("))
        XCTAssertTrue(result.text.contains("IFCSITE("))
        XCTAssertTrue(result.text.contains("IFCBUILDING("))
        XCTAssertTrue(result.text.contains("IFCBUILDINGSTOREY("))
        XCTAssertTrue(result.text.contains("IFCSPACE("))
        XCTAssertTrue(result.text.contains("IFCWALL("))
        XCTAssertTrue(result.text.contains("IFCOPENINGELEMENT("))
        XCTAssertTrue(result.text.contains("IFCRELVOIDSELEMENT("))
        XCTAssertTrue(result.text.contains("IFCRELFILLSELEMENT("))
        XCTAssertTrue(result.text.contains("IFCCOLUMN("))
        XCTAssertTrue(result.text.contains("IFCFURNISHINGELEMENT("))
        XCTAssertTrue(result.text.contains("IFCSANITARYTERMINAL("))
        XCTAssertTrue(result.text.contains("IFCEXTRUDEDAREASOLID("))
        XCTAssertTrue(result.text.contains("Pset_PlanOpsisIdentity"))
        XCTAssertTrue(result.text.hasSuffix("ENDSEC;\r\nEND-ISO-10303-21;\r\n"))
    }

    func testV10DXFAndIFCSharePlanOpsisSemanticReference() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let wall = try XCTUnwrap(project.rooms.first?.walls.first)
        let gid = PlanOpsisExchangeIdentity.ifcGlobalID(for: wall.id)
        let ifc = IFC4ExchangeEngine().export(project: project)
        let dxf = DXFExchangeEngine().export(project: project, representation: .semanticObservations)
        XCTAssertTrue(ifc.contains("IFCWALL('\(gid)'"))
        XCTAssertTrue(ifc.contains("IFCLABEL('\(wall.id.uuidString)')"))
        XCTAssertTrue(dxf.contains("OBJECT:\(wall.id.uuidString)"))
        XCTAssertTrue(dxf.contains("IFC_GUID:\(gid)"))
    }

    func testV10DoorUsesSemanticGUIDAndDistinctDerivedVoidGUID() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let door = try XCTUnwrap(project.rooms[0].openings.first { $0.kind == .door })
        let semanticGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: door.id)
        let voidGUID = PlanOpsisExchangeIdentity.ifcGlobalID(namespace: door.id, role: "ifc.void")
        XCTAssertNotEqual(semanticGUID, voidGUID)
        let ifc = IFC4ExchangeEngine().export(project: project)
        XCTAssertTrue(ifc.contains("IFCDOOR('\(semanticGUID)'"))
        XCTAssertTrue(ifc.contains("IFCOPENINGELEMENT('\(voidGUID)'"))
        XCTAssertTrue(ifc.contains("IFCRELVOIDSELEMENT("))
        XCTAssertTrue(ifc.contains("IFCRELFILLSELEMENT("))
        XCTAssertEqual(ifc.components(separatedBy: "IFCPROPERTYSINGLEVALUE('PlanOpsisUUID',$,IFCLABEL('\(door.id.uuidString)')").count - 1, 1)
        XCTAssertTrue(ifc.contains("IFCPROPERTYSINGLEVALUE('DerivedFromPlanOpsisUUID',$,IFCLABEL('\(door.id.uuidString)')"))
        XCTAssertTrue(ifc.contains("'Pset_PlanOpsisDerivedIdentity'"))
    }

    func testV10IFCExportIsDeterministicForSameSemanticProject() {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let engine = IFC4ExchangeEngine()
        XCTAssertEqual(engine.export(project: project), engine.export(project: project))
    }

    func testV10IFCRejectsOrphanOpeningRatherThanInventingHost() throws {
        let wall = PlanOpsisWall(start: .zero, length: 3_000, angleRadians: 0, height: 2_800, thickness: 120)
        let orphan = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: UUID(), offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0)))
        let project = PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [orphan])])
        let result = IFC4ExchangeEngine().exportValidated(project: project)
        XCTAssertFalse(result.canWrite)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.severity == .error && $0.message.contains("missing host wall") })
    }

    func testV10IFCGlobalIDsAre22CharactersForAllSemanticObjects() {
        var project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        project.rooms[0].components.append(PlanOpsisComponent(kind: .table, position: .zero))
        let result = IFC4ExchangeEngine().exportValidated(project: project)
        XCTAssertTrue(result.canWrite)
        XCTAssertFalse(result.objectGlobalIDs.isEmpty)
        XCTAssertTrue(result.objectGlobalIDs.values.allSatisfy { $0.count == 22 })
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")
        XCTAssertTrue(result.objectGlobalIDs.values.allSatisfy { Set($0).isSubset(of: allowed) })
    }

    private func testPointInPolygon(_ point: Point2D, polygon: [Point2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i], pj = polygon[j]
            let denominator = abs(pj.y - pi.y) < 1e-12 ? 1e-12 : (pj.y - pi.y)
            let crosses = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / denominator + pi.x)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }

    private func hostedWallLengths(room: PlanOpsisRoom) -> [String] {
        room.openings.map { opening in
            let wall = room.walls.first { $0.id == opening.parameters.hostWallID }!
            return "\(opening.kind.rawValue):\(Int(wall.length.rounded())):\(Int(opening.parameters.width.rounded())):\(Int(opening.parameters.height.rounded()))"
        }.sorted()
    }

    private func remapProvenance(_ snapshot: RoomCaptureSnapshot) -> RoomCaptureSnapshot {
        let newRoomID = UUID()
        var mapping: [UUID: UUID] = [:]
        for surface in snapshot.surfaces {
            mapping[surface.sourceRoomPlanID] = UUID()
        }
        let surfaces = snapshot.surfaces.map { surface in
            CapturedSurfaceSnapshot(
                sourceRoomPlanID: mapping[surface.sourceRoomPlanID]!,
                parentIdentifier: surface.parentIdentifier.flatMap { mapping[$0] },
                category: surface.category,
                transform: surface.transform,
                dimensions: surface.dimensions,
                confidence: surface.confidence,
                shapeHints: surface.shapeHints
            )
        }
        return RoomCaptureSnapshot(sourceRoomPlanID: newRoomID, surfaces: surfaces)
    }

    private func solidContains(_ solid: WallSolidSegment, x: Double, y: Double) -> Bool {
        x >= solid.startOffset - 1e-9 &&
        x <= solid.startOffset + solid.length + 1e-9 &&
        y >= solid.bottom - 1e-9 &&
        y <= solid.bottom + solid.height + 1e-9
    }
}
