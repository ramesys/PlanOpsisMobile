import XCTest
@testable import PlanOpsisCore

/// v12.6 architects' files: two-point alignment, scale calibration, PDF underlay placement and walls
/// traced from double-line drawings.
final class PlanOpsisV126UnderlayTests: XCTestCase {
    func assertEqual(_ a: Point2D, _ b: Point2D, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x of \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y of \(a) vs \(b)", file: file, line: line)
    }

    // MARK: Alignment

    func testSimilarityAlignsTwoPointsWithAndWithoutScale() throws {
        let a = Point2D(x: 0, y: 0), b = Point2D(x: 1_000, y: 0)
        let fit = try XCTUnwrap(PlanSimilarity.aligning(a, b, to: Point2D(x: 500, y: 500), Point2D(x: 500, y: 2_500), matchScale: true))
        assertEqual(fit.apply(a), Point2D(x: 500, y: 500))
        assertEqual(fit.apply(b), Point2D(x: 500, y: 2_500))
        XCTAssertEqual(fit.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(fit.rotation, .pi / 2, accuracy: 1e-12)

        let kept = try XCTUnwrap(PlanSimilarity.aligning(a, b, to: Point2D(x: 500, y: 500), Point2D(x: 500, y: 2_500), matchScale: false))
        assertEqual(kept.apply(a), Point2D(x: 500, y: 500))
        assertEqual(kept.apply(b), Point2D(x: 500, y: 1_500), accuracy: 1e-9)
        XCTAssertNil(PlanSimilarity.aligning(a, a, to: b, b, matchScale: true), "coincident picks have no direction")
    }

    func testAlignmentCorrectsAnExistingPlacementSoRawPointsLandOnTheirTargets() throws {
        let start = UnderlayPlacement(offset: Point2D(x: 120, y: -40), rotationDegrees: 33, scale: 1)
        let unitScale = 1_000.0 // a drawing in metres
        let t0 = start.transform(unitScale: unitScale)
        let raw1 = Point2D(x: 2, y: 3), raw2 = Point2D(x: 9.5, y: 3)
        let targets = (Point2D(x: 0, y: 0), Point2D(x: 0, y: 7_500))

        var session = UnderlayAlignmentSession(mode: .align)
        XCTAssertTrue(session.needsUnderlayPoint)
        session.add(t0.apply(raw1))
        session.add(t0.apply(raw2))
        XCTAssertFalse(session.needsUnderlayPoint)
        XCTAssertEqual(session.prompt, "Tap where the first point belongs on the plan.")
        session.add(targets.0)
        XCTAssertFalse(session.isComplete)
        session.add(targets.1)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(try XCTUnwrap(session.alignmentScaleFactor), 1, accuracy: 1e-9, "the placed picks are 7.5 m apart, like the targets")

        let aligned = start.applying(try XCTUnwrap(session.alignment(matchScale: true)))
        let t1 = aligned.transform(unitScale: unitScale)
        assertEqual(t1.apply(raw1), targets.0, accuracy: 1e-6)
        assertEqual(t1.apply(raw2), targets.1, accuracy: 1e-6)
        XCTAssertEqual(aligned.rotationDegrees, 90, accuracy: 1e-9)
        XCTAssertEqual(aligned.scale, 1, accuracy: 1e-9)

        session.undo()
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.planPoints.count, 1)
    }

    func testCalibrationScalesAboutTheFirstPoint() throws {
        let start = UnderlayPlacement(offset: Point2D(x: 300, y: 200), rotationDegrees: -12, scale: 1)
        let t0 = start.transform(unitScale: 100) // a PDF page at an assumed 1:100
        let raw1 = Point2D(x: 10, y: 10), raw2 = Point2D(x: 18, y: 10) // 8 paper mm → 800 mm
        var session = UnderlayAlignmentSession(mode: .calibrate)
        session.add(t0.apply(raw1))
        session.add(t0.apply(raw2))
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(try XCTUnwrap(session.measuredLength), 800, accuracy: 1e-9)
        XCTAssertNil(session.calibration(knownLength: 0))

        let calibrated = start.applying(try XCTUnwrap(session.calibration(knownLength: 4_000)))
        let t1 = calibrated.transform(unitScale: 100)
        assertEqual(t1.apply(raw1), t0.apply(raw1), accuracy: 1e-6)
        XCTAssertEqual((t1.apply(raw2) - t1.apply(raw1)).length, 4_000, accuracy: 1e-6)
        XCTAssertEqual(calibrated.scale, 5, accuracy: 1e-12, "the sheet was really 1:500")
        XCTAssertEqual(calibrated.rotationDegrees, -12, accuracy: 1e-9)
    }

    func testPlacementMovesAndRotatesAboutAPoint() {
        let placement = UnderlayPlacement().moved(by: Point2D(x: 100, y: 0)).rotated(byDegrees: 90, about: Point2D(x: 100, y: 0))
        let t = placement.transform(unitScale: 1)
        assertEqual(t.apply(Point2D(x: 0, y: 0)), Point2D(x: 100, y: 0), accuracy: 1e-9)
        assertEqual(t.apply(Point2D(x: 10, y: 0)), Point2D(x: 100, y: 10), accuracy: 1e-9)
        XCTAssertEqual(UnderlayPlacement(rotationDegrees: 170).rotated(byDegrees: 20, about: .zero).rotationDegrees, -170, accuracy: 1e-9)
    }

    func testRasterUnderlayBoundsFollowPaperScaleAndPlacement() {
        let a3 = RasterUnderlay(name: "Plan", pageWidthMM: 420, pageHeightMM: 297, imageData: Data(), paperScale: 50)
        let bounds = a3.bounds(placement: UnderlayPlacement(offset: Point2D(x: 1_000, y: 2_000)))
        XCTAssertEqual(bounds.minX, 1_000, accuracy: 1e-9)
        XCTAssertEqual(bounds.width, 21_000, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 14_850, accuracy: 1e-9)
        assertEqual(a3.corners.topLeft, Point2D(x: 0, y: 297))
    }

    func testSnapSourceLimitsAlignmentPicksToUnderlayOrPlan() throws {
        let project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 100)
        let snapper = PlanObjectSnapper(project: project)
        let underlay = CADScene(document: CADDocument(units: .millimetres, layers: [CADLayer(name: "A-WALL")], entities: [
            CADEntity(type: "LINE", layer: "A-WALL", geometry: .line(Point2D(x: 30, y: 0), Point2D(x: 30, y: 2_000))),
        ]))
        let near = Point2D(x: 12, y: 5)
        let both = try XCTUnwrap(snapper.snap(near, radius: 40, underlay: underlay))
        assertEqual(both.point, .zero, accuracy: 1e-9)
        let underlayOnly = try XCTUnwrap(snapper.snap(near, radius: 40, underlay: underlay, source: .underlayOnly))
        assertEqual(underlayOnly.point, Point2D(x: 30, y: 0), accuracy: 1e-9)
        let planOnly = try XCTUnwrap(snapper.snap(Point2D(x: 28, y: 2), radius: 40, underlay: underlay, source: .planOnly))
        assertEqual(planOnly.point, .zero, accuracy: 1e-9)
    }

    // MARK: Wall tracing

    /// An architect's plan: 8 × 5 m outside, 200 mm outer walls, two rooms split by a 100 mm partition,
    /// a 900 mm door (with its swing) in the south wall and a 1200 mm window in the east wall.
    static func architectDrawing(layer: String = "IfcWall", origin: Point2D = .zero) -> CADDocument {
        func p(_ x: Double, _ y: Double) -> Point2D { Point2D(x: origin.x + x, y: origin.y + y) }
        var entities: [CADEntity] = []
        func line(_ a: Point2D, _ b: Point2D, _ on: String = layer) {
            entities.append(CADEntity(type: "LINE", layer: on, geometry: .line(a, b)))
        }
        // Outer face, broken at the door and window.
        line(p(0, 0), p(1_000, 0)); line(p(1_900, 0), p(8_000, 0))
        line(p(8_000, 0), p(8_000, 2_000)); line(p(8_000, 3_200), p(8_000, 5_000))
        line(p(8_000, 5_000), p(0, 5_000)); line(p(0, 5_000), p(0, 0))
        // West room inner faces, door gap in the south.
        line(p(200, 200), p(1_000, 200)); line(p(1_900, 200), p(3_950, 200))
        entities.append(CADEntity(type: "LWPOLYLINE", layer: layer, geometry: .polyline(CADPolyline(
            vertices: [p(3_950, 200), p(3_950, 4_800), p(200, 4_800), p(200, 200)].map { CADVertex($0) }, closed: false))))
        // East room inner faces, window gap in the east.
        line(p(4_050, 200), p(7_800, 200)); line(p(7_800, 200), p(7_800, 2_000)); line(p(7_800, 3_200), p(7_800, 4_800))
        line(p(7_800, 4_800), p(4_050, 4_800)); line(p(4_050, 4_800), p(4_050, 200))
        // Door leaf swing and window glazing on their own layers.
        entities.append(CADEntity(type: "ARC", layer: "IfcDoor", geometry: .arc(center: p(1_000, 200), radius: 900, startAngle: 0, endAngle: .pi / 2)))
        line(p(7_900, 2_000), p(7_900, 3_200), "IfcWindow")
        // Furniture that must not become walls.
        entities.append(CADEntity(type: "LWPOLYLINE", layer: "IfcFurnishingElement", geometry: .polyline(CADPolyline(
            vertices: [p(5_000, 1_000), p(6_600, 1_000), p(6_600, 1_300), p(5_000, 1_300)].map { CADVertex($0) }, closed: true))))
        return CADDocument(units: .millimetres, layers: [CADLayer(name: layer), CADLayer(name: "IfcDoor"), CADLayer(name: "IfcWindow")], entities: entities)
    }

    func testTraceAtFindsTheWallBetweenTheTappedLines() throws {
        let scene = CADScene(document: Self.architectDrawing())
        let tracer = UnderlayWallTracer(scene: scene)
        let south = try XCTUnwrap(tracer.trace(at: Point2D(x: 3_000, y: 120)))
        XCTAssertEqual(south.thickness, 200, accuracy: 1e-6)
        XCTAssertEqual(south.start.y, 100, accuracy: 1e-6)
        XCTAssertEqual(min(south.start.x, south.end.x), 1_900, accuracy: 1e-6)
        XCTAssertEqual(max(south.start.x, south.end.x), 3_950, accuracy: 1e-6)

        let partition = try XCTUnwrap(tracer.trace(at: Point2D(x: 4_010, y: 2_500)))
        XCTAssertEqual(partition.thickness, 100, accuracy: 1e-6)
        XCTAssertEqual(partition.start.x, 4_000, accuracy: 1e-6)
        XCTAssertEqual(partition.length, 4_600, accuracy: 1e-6)

        XCTAssertNil(tracer.trace(at: Point2D(x: 2_000, y: 2_500)), "the middle of a room is not a wall")
    }

    func testCornerFacesReachTheCornerAxis() throws {
        let tracer = UnderlayWallTracer(scene: CADScene(document: Self.architectDrawing()))
        let west = try XCTUnwrap(tracer.trace(at: Point2D(x: 100, y: 2_500)))
        // The outer face runs 0…5000, the inner 200…4800: the axis spans 100…4900.
        XCTAssertEqual(min(west.start.y, west.end.y), 100, accuracy: 1e-6)
        XCTAssertEqual(max(west.start.y, west.end.y), 4_900, accuracy: 1e-6)
    }

    func testTraceAllBuildsJoinedWallsWithDoorAndWindow() throws {
        let scene = CADScene(document: Self.architectDrawing())
        let tracer = UnderlayWallTracer(scene: scene, layers: UnderlayWallTracer.isWallLayer)
        let result = tracer.traceAll()
        XCTAssertEqual(result.walls.count, 7, "\(result.walls)")
        XCTAssertEqual(result.walls.filter { abs($0.thickness - 200) < 1 }.count, 6)

        // Every wall end meets another wall's axis.
        for wall in result.walls {
            for end in [wall.start, wall.end] {
                let joined = result.walls.contains { other in
                    other != wall && abs(UnderlayWallTracer.cross(other.direction, end - other.start)) < 1e-6
                }
                XCTAssertTrue(joined, "\(end) of \(wall) is not on another wall's axis")
            }
        }

        let door = try XCTUnwrap(result.openings.first { $0.kind == .door })
        XCTAssertEqual(door.width, 900, accuracy: 1e-6)
        let doorWall = result.walls[door.wallIndex]
        assertEqual(doorWall.start + doorWall.direction * door.offset, Point2D(x: 1_450, y: 100), accuracy: 1e-6)

        let window = try XCTUnwrap(result.openings.first { $0.kind == .window })
        XCTAssertEqual(window.width, 1_200, accuracy: 1e-6)
        let windowWall = result.walls[window.wallIndex]
        XCTAssertEqual(windowWall.length, 4_800, accuracy: 1e-6, "the east wall runs through the window")
        assertEqual(windowWall.start + windowWall.direction * window.offset, Point2D(x: 7_900, y: 2_600), accuracy: 1e-6)
        XCTAssertEqual(result.openings.count, 2)
    }

    func testTracingFollowsTheUnderlayPlacement() throws {
        // The same plan in metres, far from the origin, then rotated by the placement.
        var document = Self.architectDrawing(origin: Point2D(x: 250_000, y: 80_000))
        document.entities = document.entities.map { entity in
            var scaled = entity
            switch entity.geometry {
            case let .line(a, b): scaled.geometry = .line(a * 0.001, b * 0.001)
            case let .polyline(poly): scaled.geometry = .polyline(CADPolyline(vertices: poly.vertices.map { CADVertex($0.point * 0.001) }, closed: poly.closed))
            case let .arc(center, radius, start, end): scaled.geometry = .arc(center: center * 0.001, radius: radius * 0.001, startAngle: start, endAngle: end)
            default: break
            }
            return scaled
        }
        document.units = .metres
        let placement = UnderlayPlacement(offset: Point2D(x: -250_000, y: -80_000))
            .rotated(byDegrees: 30, about: .zero)
        let scene = CADScene(document: document, transform: placement.transform(unitScale: 1_000))
        let result = UnderlayWallTracer(scene: scene, layers: UnderlayWallTracer.isWallLayer).traceAll()
        XCTAssertEqual(result.walls.count, 7)
        XCTAssertEqual(result.openings.count, 2)
        let total = result.walls.reduce(0) { $0 + $1.length }
        // 2 × (7800 + 4800) perimeter axis plus the 4800 partition axis.
        XCTAssertEqual(total, 2 * (7_800 + 4_800) + 4_800, accuracy: 0.01)
    }

    func testWallLayerNames() {
        for name in ["IfcWall", "IfcWallStandardCase", "A-WALL", "A-WALL-EXST", "WALLS", "MUR", "WAND-TRAG"] {
            XCTAssertTrue(UnderlayWallTracer.isWallLayer(name), name)
        }
        for name in ["IfcWall-Axis", "A-WALL-CNTR", "A-WALL-PATT", "IfcDoor", "A-FURN", "0"] {
            XCTAssertFalse(UnderlayWallTracer.isWallLayer(name), name)
        }
    }

    func testMergingJoinsCollinearPiecesAcrossFloatNoise() {
        let pieces = [
            UnderlayWallTracer.Segment(Point2D(x: 0, y: 0), Point2D(x: 1_000, y: 1e-9)),
            UnderlayWallTracer.Segment(Point2D(x: 2_000, y: 0), Point2D(x: 1_000, y: -1e-9)),
            UnderlayWallTracer.Segment(Point2D(x: 2_000, y: 0), Point2D(x: 3_000, y: 0)),
            UnderlayWallTracer.Segment(Point2D(x: 3_500, y: 0), Point2D(x: 4_000, y: 0)),
        ]
        let merged = UnderlayWallTracer.merged(pieces)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.length).sorted(), [500, 3_000].map(Double.init), "a 500 mm gap stays a gap")
    }
}
