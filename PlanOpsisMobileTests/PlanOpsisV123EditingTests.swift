import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class PlanOpsisV123EditingTests: XCTestCase {
    /// 4000 × 3000 room, walls counter-clockwise from the origin (wall 0 runs along +X, its normal +Y
    /// points into the room), a door on wall 0 and a window on wall 1.
    private func room() -> (project: PlanOpsisProject, walls: [UUID], door: UUID, window: UUID) {
        var project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 120)
        let walls = project.rooms[0].walls.map(\.id)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: walls[0], offsetAlongWall: 1_000, width: 900, height: 2_100, sillHeight: 0)))
        let window = PlanOpsisOpening.window(PlanOpsisWindow(parameters: HostedOpeningParameters(hostWallID: walls[1], offsetAlongWall: 1_000, width: 1_200, height: 1_200, sillHeight: 900)))
        project.rooms[0].openings = [door, window]
        return (project, walls, door.id, window.id)
    }

    private func wall(_ id: UUID, _ project: PlanOpsisProject) -> PlanOpsisWall {
        project.rooms.flatMap(\.walls).first { $0.id == id }!
    }

    private func near(_ a: Point2D, _ b: Point2D, _ tolerance: Double = 1e-6) -> Bool { (a - b).length <= tolerance }

    // MARK: Push/pull

    func testPushPullKeepsRectangleAndOpeningPositions() throws {
        let (project, walls, door, window) = room()
        let result = try WallPushPullEngine().pushPull(wallID: walls[0], offset: -500, in: project)
        XCTAssertEqual(result.changedWallIDs, [walls[0], walls[1], walls[3]])
        let pushed = wall(walls[0], result.project)
        XCTAssertTrue(near(pushed.start, Point2D(x: 0, y: -500)) && near(pushed.end, Point2D(x: 4_000, y: -500)), "\(pushed.start) \(pushed.end)")
        XCTAssertTrue(near(wall(walls[1], result.project).start, Point2D(x: 4_000, y: -500)))
        XCTAssertEqual(wall(walls[1], result.project).length, 3_500, accuracy: 1e-6)
        XCTAssertTrue(near(wall(walls[3], result.project).end, Point2D(x: 0, y: -500)))
        XCTAssertEqual(wall(walls[2], result.project), wall(walls[2], project))
        // Both openings stay where they were in the world.
        XCTAssertTrue(near(PlanOpsisV121Tests.worldCenter(of: door, in: result.project)!, Point2D(x: 1_000, y: -500)))
        XCTAssertTrue(near(PlanOpsisV121Tests.worldCenter(of: window, in: result.project)!, Point2D(x: 4_000, y: 1_000)))
    }

    func testPushPullStretchesTJunctionStemAndRejectsCollapse() throws {
        var (project, walls, _, _) = room()
        let stem = PlanOpsisWall(start: Point2D(x: 2_000, y: 0), length: 1_500, angleRadians: .pi / 2, height: 2_700, thickness: 100)
        project.rooms[0].walls.append(stem)
        let result = try WallPushPullEngine().pushPull(wallID: walls[0], offset: -400, in: project)
        let moved = wall(stem.id, result.project)
        XCTAssertTrue(near(moved.start, Point2D(x: 2_000, y: -400)))
        XCTAssertTrue(near(moved.end, stem.end))
        // Pushing the bottom wall onto the top one collapses the side walls.
        XCTAssertThrowsError(try WallPushPullEngine().pushPull(wallID: walls[0], offset: 3_000, in: project))
        XCTAssertThrowsError(try WallPushPullEngine().pushPull(wallID: UUID(), offset: 10, in: project))
    }

    func testPushPullRejectsMoveThatPushesOpeningOffItsWall() throws {
        let (project, walls, _, _) = room()
        // Pushing the left wall 3500 mm inward (its normal points +X) leaves wall 0 only 500 mm long,
        // too short for its door.
        XCTAssertThrowsError(try WallPushPullEngine().pushPull(wallID: walls[3], offset: 3_500, in: project)) { error in
            guard case PlanDirectEditError.openingWouldNotFit = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Openings

    func testSlideOpeningClampsSnapsAndKeepsWidth() throws {
        let (project, _, door, _) = room()
        func offset(_ p: PlanOpsisProject?) -> Double { p!.rooms[0].openings.first { $0.id == door }!.parameters.offsetAlongWall }
        XCTAssertEqual(offset(PlanOpeningEditing.slide(openingID: door, toward: Point2D(x: 2_600, y: 300), in: project)), 2_600, accuracy: 1e-9)
        XCTAssertEqual(offset(PlanOpeningEditing.slide(openingID: door, toward: Point2D(x: 9_000, y: 0), in: project)), 3_550, accuracy: 1e-9)
        XCTAssertEqual(offset(PlanOpeningEditing.slide(openingID: door, toward: Point2D(x: 1_013, y: 0), in: project, step: 50)), 1_000, accuracy: 1e-9)
        XCTAssertEqual(offset(PlanOpeningEditing.slide(openingID: door, toward: Point2D(x: 2_030, y: 0), in: project, step: 50)), 2_000, accuracy: 1e-9)
        // Near the end, the clear distance to the wall end is what gets rounded.
        XCTAssertEqual(offset(PlanOpeningEditing.slide(openingID: door, toward: Point2D(x: 3_290, y: 0), in: project, step: 50)), 4_000 - 250 - 450, accuracy: 1e-9)
        let clear = try XCTUnwrap(PlanOpeningEditing.clearances(openingID: door, in: project))
        XCTAssertEqual(clear.fromStart, 550, accuracy: 1e-9)
        XCTAssertEqual(clear.toEnd, 2_550, accuracy: 1e-9)
        XCTAssertNil(PlanOpeningEditing.slide(openingID: UUID(), toward: .zero, in: project))
    }

    // MARK: Selection

    func testBoxSelectionWindowVersusCrossing() throws {
        let (project, walls, door, _) = room()
        let semantic = ParametricGeometryEngine().generate(from: project)
        let snapshot = PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)
        let band = CADRect(minX: -300, minY: -300, maxX: 4_300, maxY: 300)
        let window = PlanSelectionQuery.objects(in: band, mode: .window, snapshot: snapshot, components: [])
        XCTAssertTrue(window.contains(walls[0]))
        XCTAssertTrue(window.contains(door))
        XCTAssertFalse(window.contains(walls[1]))
        let crossing = PlanSelectionQuery.objects(in: band, mode: .crossing, snapshot: snapshot, components: [])
        XCTAssertTrue(crossing.isSuperset(of: [walls[0], walls[1], walls[3], door]))
        XCTAssertFalse(crossing.contains(walls[2]))
        XCTAssertEqual(PlanBoxSelectionMode(from: Point2D(x: 10, y: 0), to: Point2D(x: 0, y: 5)), .crossing)
        XCTAssertEqual(PlanBoxSelectionMode(from: .zero, to: Point2D(x: 10, y: -5)), .window)
        let column = PlanOpsisComponent(kind: .column, position: Point2D(x: 2_000, y: 1_500), width: 300, depth: 300, height: 2_700)
        XCTAssertEqual(PlanSelectionQuery.objects(in: CADRect(minX: 1_000, minY: 1_000, maxX: 3_000, maxY: 2_000), mode: .window, snapshot: snapshot, components: [column]), [column.id])
    }

    func testConnectedAndSimilarSelection() throws {
        var (project, walls, door, _) = room()
        let loose = PlanOpsisWall(start: Point2D(x: 9_000, y: 0), length: 1_000, angleRadians: 0, height: 2_700, thickness: 100)
        let stem = PlanOpsisWall(start: Point2D(x: 2_000, y: 0), length: 1_000, angleRadians: .pi / 2, height: 2_700, thickness: 100)
        project.rooms[0].walls += [loose, stem]
        let secondDoor = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: walls[2], offsetAlongWall: 2_000, width: 800, height: 2_100, sillHeight: 0)))
        project.rooms[0].openings.append(secondDoor)
        XCTAssertEqual(PlanSelectionQuery.connectedWalls(from: walls[2], in: project), Set(walls + [stem.id]))
        XCTAssertEqual(PlanSelectionQuery.connectedWalls(from: loose.id, in: project), [loose.id])
        XCTAssertEqual(PlanSelectionQuery.similar(to: door, in: project), [door, secondDoor.id])
        XCTAssertEqual(PlanSelectionQuery.similar(to: walls[0], in: project).count, 6)
        XCTAssertTrue(PlanSelectionQuery.similar(to: UUID(), in: project).isEmpty)
    }

    // MARK: Dimensions, lengths, polar and typed input

    func testDimensionTargetsComeFromAnnotations() throws {
        let (project, walls, _, _) = room()
        XCTAssertEqual(PlanDimensionTarget(annotationID: "dim-text:\(walls[0].uuidString)"), .wallLength(walls[0]))
        XCTAssertEqual(PlanDimensionTarget(annotationID: "dim-line:opening:\(walls[1].uuidString)"), .openingWidth(walls[1]))
        XCTAssertNil(PlanDimensionTarget(annotationID: "room-name:\(walls[0].uuidString)"))
        XCTAssertNil(PlanDimensionTarget(annotationID: "dim-text:not-a-uuid"))
        let dimensions = PlanDimensionTarget.dimensions(in: DXFExchangeEngine().annotations(for: project))
        XCTAssertFalse(dimensions.isEmpty)
        for dimension in dimensions {
            guard case let .wallLength(id) = dimension.target else { continue }
            XCTAssertTrue(walls.contains(id))
            XCTAssertEqual(Double(dimension.text.text ?? "") ?? -1, dimension.measured.rounded(), accuracy: 0.5)
        }
    }

    func testChangeWallLengthAnchors() throws {
        let (project, walls, _, window) = room()
        let engine = PlanEditingConstraintEngine()
        let longer = try engine.changeWallLength(wallID: walls[0], by: 500, anchor: .start, in: project)
        XCTAssertTrue(near(wall(walls[0], longer).end, Point2D(x: 4_500, y: 0)))
        XCTAssertTrue(near(wall(walls[1], longer).start, Point2D(x: 4_500, y: 0)), "the corner moves with the wall")
        let centred = try engine.changeWallLength(wallID: walls[0], by: 400, anchor: .center, in: project)
        XCTAssertTrue(near(wall(walls[0], centred).start, Point2D(x: -200, y: 0)))
        XCTAssertTrue(near(wall(walls[0], centred).end, Point2D(x: 4_200, y: 0)))
        let shorter = try engine.changeWallLength(wallID: walls[1], by: -1_000, anchor: .start, in: project)
        XCTAssertEqual(wall(walls[1], shorter).length, 2_000, accuracy: 1e-6)
        XCTAssertTrue(near(PlanOpsisV121Tests.worldCenter(of: window, in: shorter)!, Point2D(x: 4_000, y: 1_000)))
        // Keeping the end moves the start past the window, which is refused.
        XCTAssertThrowsError(try engine.changeWallLength(wallID: walls[1], by: -1_000, anchor: .end, in: project))
        XCTAssertThrowsError(try engine.changeWallLength(wallID: walls[0], by: -4_000, anchor: .start, in: project))
    }

    func testPolarTrackingSnapsNearIncrements() throws {
        let engine = PlanEditingConstraintEngine()
        let p = Point2D(x: cos(43 * .pi / 180) * 1_000, y: sin(43 * .pi / 180) * 1_000)
        let snapped = try XCTUnwrap(engine.polarPoint(p, anchor: .zero, incrementDegrees: 45))
        XCTAssertEqual(snapped.x, snapped.y, accuracy: 1e-9)
        XCTAssertEqual(snapped.length, 1_000, accuracy: 1e-9)
        XCTAssertNil(engine.polarPoint(Point2D(x: cos(0.52) * 1_000, y: sin(0.52) * 1_000), anchor: .zero, incrementDegrees: 45))
        let settings = PlanEditingSettings(polarIncrementDegrees: 15)
        let result = engine.constrainedPoint(proposed: Point2D(x: 1_000, y: 20), anchor: .zero, edited: WallEndpointReference(wallID: UUID(), endpoint: .end, point: .zero), walls: [], settings: settings)
        XCTAssertEqual(result.point.y, 0, accuracy: 1e-9)
    }

    func testPrecisionInputForms() {
        let anchor = Point2D(x: 100, y: 100)
        XCTAssertTrue(near(PlanPrecisionInput.point(from: "3450<90", anchor: anchor, direction: nil)!, Point2D(x: 100, y: 3_550)))
        XCTAssertTrue(near(PlanPrecisionInput.point(from: "@ 1000 < 180", anchor: anchor, direction: nil)!, Point2D(x: -900, y: 100)))
        XCTAssertTrue(near(PlanPrecisionInput.point(from: "@1200,-300", anchor: anchor, direction: nil)!, Point2D(x: 1_300, y: -200)))
        XCTAssertTrue(near(PlanPrecisionInput.point(from: "#5000,2000", anchor: anchor, direction: nil)!, Point2D(x: 5_000, y: 2_000)))
        XCTAssertTrue(near(PlanPrecisionInput.point(from: "2500", anchor: anchor, direction: Point2D(x: 0, y: -3))!, Point2D(x: 100, y: -2_400)))
        XCTAssertNil(PlanPrecisionInput.point(from: "2500", anchor: anchor, direction: nil))
        XCTAssertNil(PlanPrecisionInput.point(from: "abc", anchor: anchor, direction: Point2D(x: 1, y: 0)))
        XCTAssertNil(PlanPrecisionInput.point(from: "1,2,3", anchor: anchor, direction: nil))
        XCTAssertNil(PlanPrecisionInput.point(from: "-5<0", anchor: anchor, direction: nil))
    }

    // MARK: Object snaps in the editor

    func testEditorSnapsToWallAxesAndUnderlay() throws {
        let (project, walls, _, _) = room()
        let snapper = PlanObjectSnapper(project: project)
        let mid = try XCTUnwrap(snapper.snap(Point2D(x: 2_020, y: 30), radius: 60))
        XCTAssertEqual(mid.kind, .midpoint)
        XCTAssertTrue(near(mid.point, Point2D(x: 2_000, y: 0)))
        let excluding = PlanObjectSnapper(project: project, excludingWallIDs: [walls[0]])
        XCTAssertNil(excluding.snap(Point2D(x: 2_020, y: 30), radius: 60))
        // A metre-unit underlay placed in millimetres.
        let text = """
        0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n6\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n8\nA\n10\n10\n20\n10\n11\n12\n21\n10\n0\nENDSEC\n0\nEOF\n
        """
        let document = try CADDocumentReader().read(text: text)
        XCTAssertEqual(document.units, .metres)
        let underlay = CADScene(document: document, transform: .scale(1_000, 1_000))
        let snap = try XCTUnwrap(excluding.snap(Point2D(x: 11_030, y: 10_020), radius: 60, underlay: underlay))
        XCTAssertEqual(snap.kind, .midpoint)
        XCTAssertTrue(near(snap.point, Point2D(x: 11_000, y: 10_000)))
        XCTAssertNil(excluding.snap(Point2D(x: 11_030, y: 10_020), radius: 60, underlay: underlay, underlayHiddenLayers: ["A"]))
    }
}
