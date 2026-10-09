import XCTest
@testable import PlanOpsisCore

/// v12.10 a photo of a plan read as walls, doors, windows, stairs and scale, and built into rooms.
final class PlanOpsisV1210PhotoReadingTests: XCTestCase {
    typealias Ink = (Double, Double) -> Bool

    /// A synthetic plan photo: `ink` says where the drawing is inked, in y-up pixels; the paper is lit
    /// unevenly and the sheet turned `degrees`.
    static func photo(width: Int = 800, height: Int = 600, degrees: Double = 0, ink: Ink) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        let a = -degrees * .pi / 180, c = cos(a), s = sin(a)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for row in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5 - cx, py = Double(height - row) - 0.5 - cy
                let qx = px * c - py * s + cx, qy = px * s + py * c + cy
                let paper = 245 - Int(60 * Double(x) / Double(width))
                image[x, row] = ink(qx, qy) ? 35 : UInt8(paper)
            }
        }
        return image
    }

    static func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Ink { { x, y in x >= x0 && x < x1 && y >= y0 && y < y1 } }

    /// A quarter circle about `center` of `radius`, between `from` and `to` degrees, 1.6 px wide.
    static func arc(_ center: (Double, Double), _ radius: Double, from: Double, to: Double) -> Ink {
        { x, y in
            let dx = x - center.0, dy = y - center.1
            let r = (dx * dx + dy * dy).squareRoot()
            var angle = atan2(dy, dx) * 180 / .pi
            if angle < -1 { angle += 360 }
            return abs(r - radius) <= 0.8 && angle >= from - 1 && angle <= to + 1
        }
    }

    static func union(_ parts: [Ink]) -> Ink { { x, y in parts.contains { $0(x, y) } } }

    /// Two rooms at 20 mm per pixel: a 13.6 × 9.6 m outline with 240 mm walls, a 120 mm partition with a
    /// door, an entrance door, two windows, a stair, and two dimension lines underneath.
    static func house(withDimensions: Bool = true) -> (ink: Ink, texts: [PlanPhotoReading.Text]) {
        var parts: [Ink] = [
            // Bottom wall with the entrance (x 150–195), top wall with a window (x 500–620).
            box(60, 60, 150, 72), box(195, 60, 740, 72),
            box(60, 528, 500, 540), box(620, 528, 740, 540),
            // Left wall with a window (y 300–380), right wall.
            box(60, 60, 72, 300), box(60, 380, 72, 540), box(728, 60, 740, 540),
            // Partition with a door (y 250–295).
            box(397, 72, 403, 250), box(397, 295, 403, 528),
            // Entrance: hinged at (150, 66), opening inwards.
            arc((150, 66), 45, from: 0, to: 90), box(149.5, 66, 150.5, 111),
            // Partition door: hinged at (400, 250), opening into the right room.
            arc((400, 250), 45, from: 0, to: 90), box(400, 249.5, 445, 250.5),
            // Windows: wall faces carried across and the glass between.
            box(500, 528, 620, 529), box(500, 533.5, 620, 534.5), box(500, 539, 620, 540),
            box(60, 300, 61, 380), box(65.5, 300, 66.5, 380), box(71, 300, 72, 380),
        ]
        // A stair: nine treads 50 px (1 m) wide, 13 px (260 mm) apart, inside its outline.
        for k in 0..<9 { parts.append(box(600, 100 + Double(k) * 13, 650, 101 + Double(k) * 13)) }
        parts += [box(600, 100, 601, 205), box(649, 100, 650, 205)]
        var texts = [PlanPhotoReading.Text(position: Point2D(x: 230, y: 450), string: "Living", height: 12),
                     PlanPhotoReading.Text(position: Point2D(x: 520, y: 420), string: "Kitchen", height: 12)]
        if withDimensions {
            parts += [box(60, 30, 740, 31), box(60, 10, 400, 11)]
            texts += [PlanPhotoReading.Text(position: Point2D(x: 400, y: 38), string: "13600", height: 10),
                      PlanPhotoReading.Text(position: Point2D(x: 230, y: 17), string: "6.80", height: 10)]
        }
        return (union(parts), texts)
    }

    func read(_ ink: Ink, texts: [PlanPhotoReading.Text], degrees: Double = 0) -> PlanPhotoReading {
        let vectors = PlanPhotoVectorizer().vectorize(Self.photo(degrees: degrees, ink: ink))
        return PlanPhotoInterpreter().read(vectors, texts: texts)
    }

    func testAHouseIsReadAsWallsDoorsWindowsAndStairs() throws {
        let (ink, texts) = Self.house()
        let reading = read(ink, texts: texts)
        XCTAssertEqual(reading.wallStyle, .filled)
        XCTAssertEqual(reading.scaleSource, .dimensions(2))
        XCTAssertEqual(reading.millimetresPerPixel, 20, accuracy: 0.4)
        XCTAssertEqual(reading.doorCount, 2, "\(reading.openings)")
        XCTAssertEqual(reading.windowCount, 2, "\(reading.openings)")
        XCTAssertEqual(reading.doorwayCount, 0)
        XCTAssertEqual(reading.walls.count, 5, "gaps bridged: four outer walls and the partition")
        let stair = try XCTUnwrap(reading.stairs.first)
        XCTAssertEqual(reading.stairs.count, 1)
        XCTAssertEqual(stair.width * 20, 1_000, accuracy: 60)
        XCTAssertEqual(stair.treads, 9)
        XCTAssertEqual(abs(stair.runDirection.y), 1, accuracy: 0.01)

        // Doors keep their drawn swing.
        for door in reading.openings where door.kind == .door {
            XCTAssertNotNil(door.hingeAtEnd)
            XCTAssertNotNil(door.opensToLeft)
            XCTAssertEqual(door.width * 20, 900, accuracy: 60)
        }
    }

    func testThePhotoBecomesAPlanWithNamedRoomsAndAStair() throws {
        let (ink, texts) = Self.house()
        let reading = read(ink, texts: texts)
        let transform = CADAffine.scale(reading.millimetresPerPixel, reading.millimetresPerPixel)
        let plan = reading.plan(transform: transform)
        XCTAssertEqual(plan.rooms.filter { !$0.walls.isEmpty }.count, 2, "\(plan.rooms.map(\.walls.count))")
        XCTAssertEqual(Set(plan.roomNames.values), ["Living", "Kitchen"])
        // The partition (and its door) belongs to both rooms: count each opening once by where it is.
        let openings = Dictionary(grouping: plan.rooms.flatMap { room in
            room.openings.compactMap { opening -> (PlanOpsisOpening.Kind, String)? in
                guard let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { return nil }
                let u = Point2D(x: cos(wall.angleRadians), y: sin(wall.angleRadians))
                let c = wall.start + u * opening.parameters.offsetAlongWall
                return (opening.kind, "\(Int((c.x / 100).rounded())),\(Int((c.y / 100).rounded()))")
            }
        }, by: { $0.0 }).mapValues { Set($0.map(\.1)).count }
        XCTAssertEqual(openings[.door], 2, "\(openings)")
        XCTAssertEqual(openings[.window], 2)
        let stairs = plan.rooms.flatMap(\.components).filter { $0.kind == .stairs }
        XCTAssertEqual(stairs.count, 1)
        let kitchen = try XCTUnwrap(plan.rooms.first { plan.roomNames[$0.id] == "Kitchen" })
        XCTAssertTrue(kitchen.components.contains { $0.kind == .stairs }, "the stair is in the room it was drawn in")
        let wallThicknesses = plan.rooms.flatMap(\.walls).map(\.thickness)
        XCTAssertTrue(wallThicknesses.contains { abs($0 - 240) < 30 }, "\(wallThicknesses)")
        XCTAssertTrue(wallThicknesses.contains { abs($0 - 120) < 30 }, "\(wallThicknesses)")
    }

    func testATurnedPhotoReadsTheSame() {
        let (ink, texts) = Self.house()
        // Texts are read on the photo as taken: turn them with it.
        let turn = PlanSimilarity.rotation(2 * .pi / 180, about: Point2D(x: 400, y: 300))
        let turned = texts.map { PlanPhotoReading.Text(position: turn.apply($0.position), string: $0.string, height: $0.height) }
        let reading = read(ink, texts: turned, degrees: 2)
        XCTAssertEqual(reading.millimetresPerPixel, 20, accuracy: 0.6)
        XCTAssertEqual(reading.doorCount, 2, "\(reading.openings)")
        XCTAssertEqual(reading.windowCount, 2, "\(reading.openings)")
        XCTAssertEqual(reading.stairs.count, 1)
    }

    func testAPlainGapIsADoorwayAndADoorByACornerClosesTheRoom() {
        // No swing at the entrance; the partition's door sits against the bottom wall.
        let parts: [Ink] = [
            Self.box(60, 60, 150, 72), Self.box(195, 60, 740, 72), Self.box(60, 528, 740, 540),
            Self.box(60, 60, 72, 540), Self.box(728, 60, 740, 540),
            Self.box(397, 117, 403, 528), Self.arc((400, 117), 45, from: 270, to: 360), Self.box(400, 116.5, 445, 117.5),
            Self.box(60, 30, 740, 31), Self.box(60, 10, 400, 11),
        ]
        let texts = [PlanPhotoReading.Text(position: Point2D(x: 400, y: 38), string: "13600", height: 10),
                     PlanPhotoReading.Text(position: Point2D(x: 230, y: 17), string: "6800", height: 10)]
        let reading = read(Self.union(parts), texts: texts)
        XCTAssertEqual(reading.doorwayCount, 1, "\(reading.openings)")
        XCTAssertEqual(reading.doorCount, 1, "\(reading.openings)")
        XCTAssertEqual(reading.walls.count, 5)
        let plan = reading.plan(transform: .scale(reading.millimetresPerPixel, reading.millimetresPerPixel))
        XCTAssertEqual(plan.rooms.filter { !$0.walls.isEmpty }.count, 2, "the partition reaches the bottom wall")
        XCTAssertTrue(plan.rooms.flatMap(\.openings).contains { $0.kind == .opening })
    }

    func testWithoutDimensionsTheDoorsGiveTheScale() {
        let (ink, texts) = Self.house(withDimensions: false)
        let reading = read(ink, texts: texts)
        guard case let .doors(count) = reading.scaleSource else { return XCTFail("\(reading.scaleSource)") }
        XCTAssertEqual(count, 2)
        // 45 px doors taken as 850 mm.
        XCTAssertEqual(reading.millimetresPerPixel, 850.0 / 45, accuracy: 1)
    }

    func testWallsDrawnAsOutlines() {
        // One room, 12 px walls drawn as two 1 px faces; a door gap on the bottom wall with its swing and
        // a window on the top wall (faces carried across, a glass line between).
        var parts: [Ink] = [
            // Bottom wall faces, broken by the door at x 300–345.
            Self.box(100, 100, 300, 101), Self.box(100, 111, 300, 112), Self.box(345, 100, 700, 101), Self.box(345, 111, 700, 112),
            // Door jambs and swing.
            Self.box(299, 100, 300, 112), Self.box(345, 100, 346, 112), Self.arc((300, 106), 45, from: 0, to: 90),
            // Top wall faces with the glass line from x 400 to 520.
            Self.box(100, 488, 700, 489), Self.box(100, 499, 700, 500), Self.box(400, 493.5, 520, 494.5),
            // Side walls.
            Self.box(100, 100, 101, 500), Self.box(111, 111, 112, 489), Self.box(699, 100, 700, 500), Self.box(688, 111, 689, 489),
        ]
        parts.append(Self.box(400, 488, 401, 500))
        parts.append(Self.box(520, 488, 521, 500))
        let reading = read(Self.union(parts), texts: [])
        XCTAssertEqual(reading.wallStyle, .outline)
        XCTAssertEqual(reading.doorCount, 1, "\(reading.openings)")
        XCTAssertEqual(reading.windowCount, 1, "\(reading.openings)")
        let plan = reading.plan(transform: .scale(reading.millimetresPerPixel, reading.millimetresPerPixel))
        XCTAssertEqual(plan.rooms.filter { !$0.walls.isEmpty }.count, 1)
    }

    func testTilesAreNotStairs() {
        var parts: [Ink] = [Self.house(withDimensions: false).ink]
        for k in 0..<8 {
            parts.append(Self.box(150, 380 + Double(k) * 12, 330, 381 + Double(k) * 12))
            parts.append(Self.box(150 + Double(k) * 24, 380, 151 + Double(k) * 24, 470))
        }
        let reading = read(Self.union(parts), texts: [])
        XCTAssertEqual(reading.stairs.count, 1, "the grid is tiling; only the drawn stair counts")
    }

    func testDimensionFigures() {
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("3500"), [3_500])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("3.50"), [3_500])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("3,5 m"), [3_500])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("350"), [350, 3_500])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("90 cm"), [900])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("12'-6\""), [3_810])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("12.5 m²"), [])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("Kitchen"), [])
        XCTAssertEqual(PlanPhotoInterpreter.dimensionValues("4"), [])
    }
}
