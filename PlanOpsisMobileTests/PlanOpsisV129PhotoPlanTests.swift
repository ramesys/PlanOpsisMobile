import XCTest
@testable import PlanOpsisCore

/// v12.9 a photo of a plan turned into walls and rooms.
final class PlanOpsisV129PhotoPlanTests: XCTestCase {
    /// A synthetic plan photo, `width` × `height` px: paper lit unevenly (darker to the right), ink bands
    /// for walls, all turned `degrees` counter-clockwise about the centre. Shapes are rectangles in y-up
    /// pixel coordinates; `ink` is how dark they print.
    static func photo(width: Int = 800, height: Int = 600, degrees: Double = 0,
                      rectangles: [(x0: Double, y0: Double, x1: Double, y1: Double)], ink: UInt8 = 40) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        let a = -degrees * .pi / 180, c = cos(a), s = sin(a)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for row in 0..<height {
            for x in 0..<width {
                // Pixel centre in y-up terms, turned back to the plan's own axes.
                let px = Double(x) + 0.5 - cx, py = Double(height - row) - 0.5 - cy
                let qx = px * c - py * s + cx, qy = px * s + py * c + cy
                let inside = rectangles.contains { qx >= $0.x0 && qx < $0.x1 && qy >= $0.y0 && qy < $0.y1 }
                let paper = 245 - Int(70 * Double(x) / Double(width)) // shadow towards the right
                image[x, row] = inside ? ink : UInt8(paper)
            }
        }
        return image
    }

    /// Two rooms, 8 px walls: the outline from (80, 80) to (720, 520), a partition at x = 400.
    static let twoRooms: [(x0: Double, y0: Double, x1: Double, y1: Double)] = [
        (80, 80, 720, 88), (80, 512, 720, 520), (80, 80, 88, 520), (712, 80, 720, 520), (396, 80, 404, 520),
    ]

    func testWallsOfAStraightPhotoAreFound() throws {
        let result = PlanPhotoVectorizer().vectorize(Self.photo(rectangles: Self.twoRooms))
        XCTAssertEqual(result.skewDegrees, 0, accuracy: 0.1)
        XCTAssertEqual(result.walls.count, 5, "\(result.walls)")
        for wall in result.walls { XCTAssertEqual(wall.thickness, 8, accuracy: 1) }
        let top = try XCTUnwrap(result.walls.first { abs($0.start.y - 516) < 2 && abs($0.end.y - 516) < 2 })
        XCTAssertEqual(min(top.start.x, top.end.x), 80, accuracy: 2)
        XCTAssertEqual(max(top.start.x, top.end.x), 720, accuracy: 2)
    }

    func testTurnedPhotoIsStraightenedAndStrokesFollowIt() throws {
        let result = PlanPhotoVectorizer().vectorize(Self.photo(degrees: 3, rectangles: Self.twoRooms))
        XCTAssertEqual(result.skewDegrees, 3, accuracy: 0.15)
        XCTAssertEqual(result.walls.count, 5, "\(result.walls.count) walls")
        let longest = try XCTUnwrap(result.walls.max { $0.length < $1.length })
        var angle = atan2(longest.end.y - longest.start.y, longest.end.x - longest.start.x) * 180 / .pi
        if angle > 45 { angle -= 90 }
        XCTAssertEqual(angle, 3, accuracy: 0.3, "strokes sit on the photo as taken")
    }

    func testThinLinesTextAndFilledAreas() {
        var shapes = Self.twoRooms
        shapes.append((150, 300, 350, 302))                   // a dimension line, 2 px
        for i in 0..<12 { shapes.append((450 + Double(i) * 12, 300, 456 + Double(i) * 12, 309)) } // "text"
        shapes.append((500, 150, 680, 260))                   // a filled legend box
        let result = PlanPhotoVectorizer().vectorize(Self.photo(rectangles: shapes))
        XCTAssertEqual(result.walls.count, 5, "letters and the legend are not walls")
        XCTAssertTrue(result.lines.contains { abs($0.start.y - 301) < 2 && $0.length > 150 }, "the dimension line is a thin line: \(result.lines)")
        XCTAssertFalse(result.strokes.contains { $0.thickness > 50 }, "the filled box is not a stroke")
    }

    func testPhotoBecomesRoomsOnceScaled() throws {
        let result = PlanPhotoVectorizer().vectorize(Self.photo(degrees: -2, rectangles: Self.twoRooms))
        let document = PlanPhotoVectorizer.document(from: result, texts: [
            (Point2D(x: 240, y: 300), "Kitchen", 14), (Point2D(x: 560, y: 300), "Living", 14),
        ])
        XCTAssertTrue(UnderlayWallTracer.isWallLayer(PlanPhotoVectorizer.wallLayer()))
        XCTAssertTrue(UnderlayWallTracer.isWallLayer(PlanPhotoVectorizer.wallLayer(.discipline)))
        // Calibrated: 1 px = 25 mm, so the walls are 200 mm and the outline 16 × 11 m.
        let placement = UnderlayPlacement()
        let scene = CADScene(document: document, transform: placement.transform(unitScale: 25))
        let traced = UnderlayWallTracer(scene: scene, layers: UnderlayWallTracer.isWallLayer).traceAll()
        for wall in traced.walls { XCTAssertEqual(wall.thickness, 200, accuracy: 30) }
        let split = RoomLoopDetector().split(traced.makeRoom())
        XCTAssertEqual(split.rooms.count, 2)
        let names = RoomLoopDetector.names(for: split.rooms.map(\.loop), texts: scene.texts())
        XCTAssertEqual(Set(names.compactMap { $0 }), ["Kitchen", "Living"])
        let areas = split.rooms.map { PlanPolygon.area($0.loop) / 1_000_000 }.sorted()
        // Axis loops: (400 − 84) × (516 − 84) px and (716 − 400) × 432 px, at 25 mm per px.
        XCTAssertEqual(areas[0], 316 * 432 * 0.000625, accuracy: 3)
        XCTAssertEqual(areas[1], 316 * 432 * 0.000625, accuracy: 3)
    }

    func testPhotoLinesExportAsAScaledDXF() throws {
        let result = PlanPhotoVectorizer().vectorize(Self.photo(rectangles: Self.twoRooms + [(150, 300, 350, 302)]))
        let document = PlanPhotoVectorizer.document(from: result, texts: [(Point2D(x: 240, y: 200), "Kitchen", 14)])
        let placement = UnderlayPlacement(offset: Point2D(x: -2_000, y: -2_000))
        let text = CADDocumentDXFWriter().write(document, transform: placement.transform(unitScale: 25))
        let read = try CADDocumentReader().read(text: text)
        XCTAssertEqual(read.entities.count, document.entities.count)
        // PlanOpsis semantic layers: the same names as the app's own DXF.
        XCTAssertEqual(Set(read.layers.map(\.name)), ["IfcWall", "IfcAnnotation"])
        let discipline = try CADDocumentReader().read(text: CADDocumentDXFWriter().write(document, layerNaming: .discipline))
        XCTAssertEqual(Set(discipline.layers.map(\.name)), ["A-WALL", "A-ANNO", "A-ANNO-ROOM"])
        // The top wall's outer face: y = 520 px → 520 × 25 − 2000 mm.
        let faces = read.entities.compactMap { entity -> (Point2D, Point2D)? in
            if case let .line(a, b) = entity.geometry, entity.layer == PlanPhotoVectorizer.wallLayer() { return (a, b) }
            return nil
        }
        XCTAssertTrue(faces.contains { abs($0.0.y - 11_000) < 30 && abs($0.1.y - 11_000) < 30 }, "\(faces.map { $0.0.y })")
        let label = try XCTUnwrap(read.entities.compactMap { entity -> CADText? in
            if case let .text(t) = entity.geometry { return t }; return nil
        }.first)
        XCTAssertEqual(label.string, "Kitchen")
        XCTAssertEqual(label.height, 350, accuracy: 1e-6)
    }

    func testBlankPaperHasNoStrokes() {
        let result = PlanPhotoVectorizer().vectorize(Self.photo(rectangles: []))
        XCTAssertTrue(result.strokes.isEmpty)
        XCTAssertEqual(result.skewDegrees, 0)
    }
}
