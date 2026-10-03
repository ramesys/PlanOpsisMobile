import XCTest
@testable import PlanOpsisCore

/// v12.7 the survey compared with an aligned drawing.
final class PlanOpsisV127DeviationTests: XCTestCase {
    static func traced(_ wall: PlanOpsisWall, shift: Point2D = .zero) -> TracedWall {
        TracedWall(start: wall.start + shift, end: wall.end + shift, thickness: wall.thickness)
    }

    func testWallsAndOpeningsAgainstAModifiedDrawing() throws {
        let project = GoldenExchangeTests.project()
        let room = project.rooms[0]
        func wall(_ n: Int) -> PlanOpsisWall { room.walls.first { $0.id == GoldenExchangeTests.id(n) }! }
        // Drawing: the south wall 30 mm further south, the east wall turned (its north end 80 mm east),
        // the north wall 10 mm thicker, no stem wall, and one wall the survey does not have.
        let south = wall(10), east = wall(11), north = wall(12), west = wall(13)
        var reference = UnderlayTraceResult(walls: [
            Self.traced(south, shift: Point2D(x: 0, y: -30)),
            TracedWall(start: east.start, end: east.end + Point2D(x: 80, y: 0), thickness: east.thickness),
            TracedWall(start: north.start, end: north.end, thickness: north.thickness + 10),
            Self.traced(west),
            TracedWall(start: Point2D(x: 9_000, y: 0), end: Point2D(x: 12_000, y: 0), thickness: 200),
        ])
        // Doors and windows: D on the south wall 100 mm further east, a window 50 mm narrower.
        for opening in room.openings {
            let p = opening.parameters
            guard let index = [south, east, north, west].firstIndex(where: { $0.id == p.hostWallID }) else { continue }
            let isSouthDoor = index == 0 && opening.kind == .door
            reference.openings.append(TracedOpening(kind: opening.kind, wallIndex: index, offset: p.offsetAlongWall + (isSouthDoor ? 100 : 0),
                                                    width: p.width - (opening.kind == .window && index == 2 ? 50 : 0)))
        }
        let analysis = DeviationAnalysis(project: project, reference: reference)

        let rows = Dictionary(uniqueKeysWithValues: analysis.walls.map { ($0.wallID, $0) })
        let southRow = try XCTUnwrap(rows[south.id])
        XCTAssertEqual(southRow.offset ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(southRow.direction, "N", "the survey sits north of the drawing")
        XCTAssertEqual(southRow.status, .warning)
        XCTAssertEqual(southRow.lengthDifference ?? 99, 0, accuracy: 1e-6)

        let eastRow = try XCTUnwrap(rows[east.id])
        XCTAssertEqual(eastRow.endDeviation ?? 0, 80, accuracy: 0.5, "a turned wall shows at its far end")
        XCTAssertEqual(eastRow.status, .deviation)
        XCTAssertNotEqual(eastRow.angleDegrees ?? 0, 0)

        let northRow = try XCTUnwrap(rows[north.id])
        XCTAssertEqual(northRow.status, .ok)
        XCTAssertEqual(northRow.thicknessDifference ?? 0, -10, accuracy: 1e-6)
        XCTAssertEqual(rows[west.id]?.status, .ok)
        XCTAssertEqual(rows[wall(14).id]?.status, .unmatched, "the stem wall is not in the drawing")

        XCTAssertEqual(analysis.missingWalls.count, 1)
        XCTAssertEqual(analysis.missingWalls.first?.length ?? 0, 3_000, accuracy: 1e-6)

        let openings = Dictionary(uniqueKeysWithValues: analysis.openings.map { ($0.mark, $0) })
        let southDoor = try XCTUnwrap(openings.values.first { $0.kind == .door && abs($0.surveyPoint.y - south.start.y) < 1 })
        XCTAssertEqual(southDoor.positionDifference ?? 0, (100.0 * 100 + 30 * 30).squareRoot(), accuracy: 1e-6, "100 mm along a wall drawn 30 mm away")
        XCTAssertEqual(southDoor.status, .deviation)
        let northWindow = try XCTUnwrap(openings.values.first { $0.kind == .window && abs($0.surveyPoint.y - north.start.y) < 1 })
        XCTAssertEqual(northWindow.widthDifference ?? 0, 50, accuracy: 1e-6)
        XCTAssertEqual(northWindow.status, .warning)
        XCTAssertEqual(openings.values.filter { $0.status == .unmatched }.count, 1, "the stem door has no drawn counterpart")

        let summary = analysis.summary
        XCTAssertEqual(summary.values.reduce(0, +), analysis.walls.count + analysis.openings.count + 1)
        XCTAssertEqual(analysis.largestOffset, 80, accuracy: 0.5)
        let csv = ProjectSchedules.csv(analysis.tables)
        XCTAssertTrue(csv.contains("Wall deviations (ok ≤ 20 mm, check ≤ 50 mm)"))
        XCTAssertTrue(csv.contains("In the drawing, not surveyed"))
        XCTAssertTrue(csv.contains(",N,"), csv)
    }

    func testSurveyBuiltFromTheDrawingMatchesUntilTheDrawingMoves() throws {
        let document = PlanOpsisV126UnderlayTests.architectDrawing()
        let survey = UnderlayWallTracer(scene: CADScene(document: document), layers: UnderlayWallTracer.isWallLayer).traceAll()
        let project = PlanOpsisProject(rooms: RoomLoopDetector().split(survey.makeRoom()).allRooms)

        let aligned = DeviationAnalysis(project: project, reference: survey)
        XCTAssertTrue(aligned.walls.allSatisfy { $0.status == .ok }, "\(aligned.walls.map(\.status))")
        XCTAssertTrue(aligned.openings.allSatisfy { $0.status == .ok })
        XCTAssertTrue(aligned.missingWalls.isEmpty)
        XCTAssertEqual(aligned.walls.count, 7, "the shared partition is one row")

        let moved = UnderlayPlacement(offset: Point2D(x: 25, y: 0))
        let shifted = UnderlayWallTracer(scene: CADScene(document: document, transform: moved.transform(unitScale: 1)),
                                         layers: UnderlayWallTracer.isWallLayer).traceAll()
        let off = DeviationAnalysis(project: project, reference: shifted)
        let northSouth = off.walls.filter { abs($0.angleDegrees ?? 0) < 1 && $0.direction == "W" }
        XCTAssertFalse(northSouth.isEmpty)
        XCTAssertTrue(northSouth.allSatisfy { abs(($0.offset ?? 0) - 25) < 1e-6 && $0.status == .warning })
    }
}
