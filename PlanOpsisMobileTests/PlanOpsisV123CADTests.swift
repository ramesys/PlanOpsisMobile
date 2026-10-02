import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// Builds small ASCII DXF files for the CAD reader tests.
private struct DXFText {
    private var lines: [String] = []

    mutating func add(_ code: Int, _ value: Any) {
        lines.append(String(code))
        lines.append("\(value)")
    }

    mutating func add(_ pairs: [(Int, Any)]) {
        for (code, value) in pairs { add(code, value) }
    }

    static func file(header: [(Int, Any)] = [], layers: [[(Int, Any)]] = [], blocks: [[(Int, Any)]] = [], entities: [[(Int, Any)]]) -> String {
        var d = DXFText()
        d.add([(0, "SECTION"), (2, "HEADER")])
        d.add([(9, "$ACADVER"), (1, "AC1015")])
        d.add(header)
        d.add(0, "ENDSEC")
        d.add([(0, "SECTION"), (2, "TABLES"), (0, "TABLE"), (2, "LAYER")])
        for layer in layers { d.add(0, "LAYER"); d.add(layer) }
        d.add([(0, "ENDTAB"), (0, "ENDSEC")])
        d.add([(0, "SECTION"), (2, "BLOCKS")])
        for block in blocks { d.add(block) }
        d.add(0, "ENDSEC")
        d.add([(0, "SECTION"), (2, "ENTITIES")])
        for entity in entities { d.add(entity) }
        d.add([(0, "ENDSEC"), (0, "EOF")])
        return d.lines.joined(separator: "\r\n") + "\r\n"
    }
}

private func near(_ a: Point2D, _ b: Point2D, _ tolerance: Double = 1e-6) -> Bool { (a - b).length <= tolerance }

final class PlanOpsisV123CADTests: XCTestCase {
    // MARK: Reader

    func testHeaderLayersAndBasicEntities() throws {
        let text = DXFText.file(
            header: [(9, "$INSUNITS"), (70, 4)],
            layers: [
                [(2, "WALLS"), (70, 0), (62, 1), (6, "CONTINUOUS"), (370, 50)],
                [(2, "HIDDEN"), (70, 0), (62, -3)],
                [(2, "FROZEN"), (70, 1), (62, 5)],
            ],
            entities: [
                [(0, "LINE"), (8, "WALLS"), (10, 0), (20, 0), (30, 0), (11, 1000), (21, 0), (31, 0)],
                [(0, "CIRCLE"), (8, "HIDDEN"), (10, 500), (20, 500), (40, 100)],
                [(0, "ARC"), (8, "FROZEN"), (62, 3), (10, 0), (20, 0), (40, 200), (50, 0), (51, 90)],
                [(0, "LINE"), (8, "WALLS"), (67, 1), (10, 0), (20, 0), (11, 1), (21, 1)],
                [(0, "MLINE"), (8, "WALLS")],
            ]
        )
        let document = try CADDocumentReader().read(text: text)
        XCTAssertEqual(document.version, "AC1015")
        XCTAssertEqual(document.units, .millimetres)
        XCTAssertEqual(document.entities.count, 3)
        XCTAssertEqual(document.diagnostics.paperSpaceEntities, 1)
        XCTAssertEqual(document.diagnostics.unsupportedEntities["MLINE"], 1)
        XCTAssertEqual(document.layer(named: "walls").color, CADColor.aci(1))
        XCTAssertEqual(document.layer(named: "WALLS").lineWeight, .hundredthsMM(50))
        XCTAssertFalse(document.layer(named: "HIDDEN").isOn)
        XCTAssertTrue(document.layer(named: "FROZEN").isFrozen)

        let scene = CADScene(document: document)
        XCTAssertEqual(scene.initiallyHiddenLayers, ["HIDDEN", "FROZEN"])
        let line = try XCTUnwrap(scene.items.first)
        XCTAssertEqual(line.color, CADColor.aci(1))
        XCTAssertEqual(line.lineWeightMM, 0.5)
        XCTAssertEqual(scene.items[2].color, CADColor.aci(3), "an explicit colour beats the layer colour")
        XCTAssertEqual(scene.items(in: scene.bounds, hiddenLayers: scene.initiallyHiddenLayers).count, 1)
        XCTAssertEqual(scene.bounds.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(scene.bounds.maxX, 1000, accuracy: 1e-9)
    }

    func testBinaryAndNonDXFAreRejected() {
        XCTAssertThrowsError(try CADDocumentReader().read(data: Data("AutoCAD Binary DXF\r\n\u{1a}\0".utf8))) { error in
            XCTAssertEqual(error as? CADReadError, .binaryDXF)
        }
        XCTAssertThrowsError(try CADDocumentReader().read(text: "hello\nworld\n"))
        XCTAssertThrowsError(try CADDocumentReader().read(data: Data()))
    }

    func testBulgedPolylineFlattensToTrueSemicircle() throws {
        // A closed slot: straight bottom, semicircular right end (bulge 1 = 180°).
        let text = DXFText.file(entities: [[
            (0, "LWPOLYLINE"), (8, "0"), (90, 2), (70, 1),
            (10, 0), (20, 0), (42, 1),
            (10, 0), (20, 200),
        ]])
        let scene = CADScene(document: try CADDocumentReader().read(text: text))
        let item = try XCTUnwrap(scene.items.first)
        guard case let .path(points, closed) = item.shape else { return XCTFail("expected a path") }
        XCTAssertTrue(closed)
        // Bulge +1 from (0,0) to (0,200) is a counter-clockwise half circle about (0,100), through (100,100).
        for p in points.dropFirst().dropLast() {
            XCTAssertEqual((p - Point2D(x: 0, y: 100)).length, 100, accuracy: 1e-6)
        }
        XCTAssertEqual(scene.bounds.maxX, 100, accuracy: 1e-6)
        XCTAssertTrue(item.keyPoints.contains { $0.kind == .center && near($0.point, Point2D(x: 0, y: 100)) })
        XCTAssertTrue(item.keyPoints.contains { $0.kind == .midpoint && near($0.point, Point2D(x: 100, y: 100)) })
    }

    func testNestedRotatedScaledArrayInsertsInheritLayerAndColour() throws {
        let text = DXFText.file(
            layers: [[(2, "FURN"), (70, 0), (62, 4)]],
            blocks: [
                [(0, "BLOCK"), (8, "0"), (2, "LEG"), (70, 0), (10, 0), (20, 0),
                 (0, "LINE"), (8, "0"), (62, 0), (10, 0), (20, 0), (11, 10), (21, 0),
                 (0, "ENDBLK"), (8, "0")],
                [(0, "BLOCK"), (8, "0"), (2, "TABLE"), (70, 0), (10, 100), (20, 100),
                 (0, "INSERT"), (8, "0"), (62, 0), (2, "LEG"), (10, 100), (20, 100),
                 (0, "CIRCLE"), (8, "0"), (10, 110), (20, 100), (40, 5),
                 (0, "ENDBLK"), (8, "0")],
            ],
            entities: [
                [(0, "INSERT"), (8, "FURN"), (62, 1), (2, "TABLE"), (10, 1000), (20, 0), (41, 2), (42, 2), (50, 90),
                 (70, 2), (71, 1), (44, 500), (45, 0)],
            ]
        )
        let document = try CADDocumentReader().read(text: text)
        XCTAssertTrue(document.diagnostics.missingBlocks.isEmpty)
        let scene = CADScene(document: document)
        // 2 columns × (one leg line + one circle).
        XCTAssertEqual(scene.items.count, 4)
        XCTAssertTrue(scene.items.allSatisfy { $0.layer == "FURN" && $0.hostLayer == "FURN" && $0.entityIndex == 0 })
        // The leg and its nested insert are ByBlock: they take the outer insert's red; the circle is ByLayer on layer 0 inside the block, so it
        // takes the inherited layer FURN's cyan.
        let legs = scene.items.filter { if case .path(_, false) = $0.shape { return true }; return false }
        XCTAssertEqual(legs.count, 2)
        XCTAssertTrue(legs.allSatisfy { $0.color == CADColor.aci(1) })
        let circles = scene.items.filter { $0.arc != nil }
        XCTAssertEqual(circles.count, 2)
        XCTAssertTrue(circles.allSatisfy { $0.color == CADColor.aci(4) })
        // Block base (100,100) maps to (1000,0); scale 2 then rotate 90°: the leg (100,100)→(110,100) runs
        // from (1000,0) to (1000,20). The second column is 500 along the rotated X axis: +500 in Y.
        guard case let .path(first, _) = legs[0].shape, case let .path(second, _) = legs[1].shape else { return XCTFail() }
        XCTAssertTrue(near(first[0], Point2D(x: 1000, y: 0)) && near(first[1], Point2D(x: 1000, y: 20)), "\(first)")
        XCTAssertTrue(near(second[0], Point2D(x: 1000, y: 500)) && near(second[1], Point2D(x: 1000, y: 520)), "\(second)")
        XCTAssertEqual(circles[0].arc?.radius ?? 0, 10, accuracy: 1e-9)
        XCTAssertTrue(near(circles[0].arc!.center, Point2D(x: 1000, y: 20)))
    }

    func testMirroredInsertAndSelfReferencingBlockAreSafe() throws {
        let text = DXFText.file(
            blocks: [
                [(0, "BLOCK"), (8, "0"), (2, "ARROW"), (70, 0), (10, 0), (20, 0),
                 (0, "LINE"), (8, "0"), (10, 0), (20, 0), (11, 100), (21, 0),
                 (0, "INSERT"), (8, "0"), (2, "ARROW"), (10, 0), (20, 0),
                 (0, "ENDBLK"), (8, "0")],
            ],
            entities: [
                // Extrusion (0,0,-1): the OCS X axis points to world -X.
                [(0, "INSERT"), (8, "0"), (2, "ARROW"), (10, 50), (20, 0), (210, 0), (220, 0), (230, -1)],
            ]
        )
        let scene = CADScene(document: try CADDocumentReader().read(text: text))
        XCTAssertTrue(scene.diagnostics.warnings.contains { $0.contains("ARROW") })
        guard case let .path(points, _) = scene.items[0].shape else { return XCTFail() }
        XCTAssertTrue(near(points[0], Point2D(x: -50, y: 0)) && near(points[1], Point2D(x: -150, y: 0)), "\(points)")
    }

    func testTextMTextAndAttributeFormatting() throws {
        XCTAssertEqual(CADTextFormatting.plainText("%%c50 at 90%%d %%p2"), "⌀50 at 90° ±2")
        XCTAssertEqual(CADTextFormatting.plainMText("{\\fArial|b1;Kitchen}\\PArea \\S1^2; m\\~2"), "Kitchen\nArea 1/2 m 2")
        XCTAssertEqual(CADTextFormatting.plainMText("a\\\\b \\{c\\}"), "a\\b {c}")
        let text = DXFText.file(entities: [
            [(0, "TEXT"), (8, "0"), (10, 0), (20, 0), (40, 100), (1, "LEFT"), (50, 90)],
            [(0, "TEXT"), (8, "0"), (10, 0), (20, 0), (11, 500), (21, 500), (40, 100), (1, "MID"), (72, 1), (73, 2)],
            [(0, "MTEXT"), (8, "0"), (10, 10), (20, 20), (40, 50), (71, 5), (3, "Living "), (1, "room\\Pfirst floor")],
        ])
        let scene = CADScene(document: try CADDocumentReader().read(text: text))
        let texts: [CADSceneText] = scene.items.compactMap { if case let .text(t) = $0.shape { return t }; return nil }
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(texts[0].rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertTrue(near(texts[1].position, Point2D(x: 500, y: 500)))
        XCTAssertEqual(texts[1].horizontal, .center)
        XCTAssertEqual(texts[1].vertical, .middle)
        XCTAssertEqual(texts[2].string, "Living room\nfirst floor")
        XCTAssertEqual(texts[2].vertical, .middle)
    }

    func testHatchSolidAndPatternClipToBoundary() throws {
        let square: [(Int, Any)] = [(92, 3), (72, 0), (73, 1), (93, 4), (10, 0), (20, 0), (10, 100), (20, 0), (10, 100), (20, 100), (10, 0), (20, 100), (97, 0)]
        let edgeCircle: [(Int, Any)] = [(92, 1), (93, 1), (72, 2), (10, 50), (20, 50), (40, 50), (50, 0), (51, 360), (73, 1), (97, 0)]
        let text = DXFText.file(entities: [
            [(0, "HATCH"), (8, "0"), (10, 0), (20, 0), (30, 0), (2, "SOLID"), (70, 1), (71, 0), (91, 1)] + square + [(75, 0), (76, 1), (98, 0)],
            [(0, "HATCH"), (8, "0"), (10, 0), (20, 0), (30, 0), (2, "ANSI31"), (70, 0), (71, 0), (91, 1)] + edgeCircle
                + [(75, 0), (76, 1), (52, 45), (41, 1), (77, 0), (78, 1), (53, 45), (43, 0), (44, 0), (45, -7.0710678), (46, 7.0710678), (79, 0), (98, 0)],
        ])
        let document = try CADDocumentReader().read(text: text)
        XCTAssertEqual(document.entities.count, 2)
        let scene = CADScene(document: document)
        guard case let .fill(loops) = scene.items[0].shape else { return XCTFail("solid hatch should fill") }
        XCTAssertEqual(CADMeasurement.area(loops[0]), 10_000, accuracy: 1e-6)
        guard case let .segments(segments) = scene.items[1].shape else { return XCTFail("pattern hatch should draw lines") }
        XCTAssertGreaterThan(segments.count, 20)
        for p in segments { XCTAssertLessThanOrEqual((p - Point2D(x: 50, y: 50)).length, 50 + 0.1) }
        XCTAssertFalse(scene.items[1].isSnappable)
    }

    func testEllipseSplineAndSynthesizedDimension() throws {
        let text = DXFText.file(entities: [
            [(0, "ELLIPSE"), (8, "0"), (10, 0), (20, 0), (11, 200), (21, 0), (40, 0.5), (41, 0), (42, 6.283185307179586)],
            [(0, "SPLINE"), (8, "0"), (70, 8), (71, 2), (72, 6), (73, 3), (40, 0), (40, 0), (40, 0), (40, 1), (40, 1), (40, 1),
             (10, 0), (20, 0), (10, 50), (20, 100), (10, 100), (20, 0)],
            [(0, "DIMENSION"), (8, "DIM"), (2, "*D99"), (10, 0), (20, 300), (11, 500), (21, 300), (70, 1), (1, ""), (13, 0), (23, 0), (14, 1000), (24, 0)],
        ])
        let document = try CADDocumentReader().read(text: text)
        let scene = CADScene(document: document)
        guard case let .path(ellipse, true) = scene.items[0].shape else { return XCTFail() }
        XCTAssertEqual(CADRect(points: ellipse)!.width, 400, accuracy: 1e-6)
        XCTAssertEqual(CADRect(points: ellipse)!.height, 200, accuracy: 0.5)
        guard case let .path(spline, false) = scene.items[1].shape else { return XCTFail() }
        XCTAssertTrue(near(spline.first!, .zero) && near(spline.last!, Point2D(x: 100, y: 0), 1e-6))
        // Quadratic Bézier apex: y = 50 at the middle.
        XCTAssertEqual(spline.map(\.y).max() ?? 0, 50, accuracy: 0.1)
        let dimensionText = scene.items.compactMap { item -> CADSceneText? in if case let .text(t) = item.shape { return t }; return nil }
        XCTAssertEqual(dimensionText.first?.string, "1000")
        XCTAssertTrue(scene.items.contains { $0.layer == "DIM" && { if case .segments = $0.shape { return true }; return false }($0) })
    }

    func testPlanOpsisExportsReadBackWithBlocksAndDimensions() throws {
        let project = GoldenExchangeTests.project()
        let revision = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let editable = EditableDXFWriter().export(project: project, dimensions: SurveyDimensionBuilder().build(project: project), revisionID: revision)
        XCTAssertTrue(editable.canWrite)
        let document = try CADDocumentReader().read(text: editable.text)
        XCTAssertEqual(document.units, .millimetres)
        XCTAssertTrue(document.diagnostics.missingBlocks.isEmpty, "\(document.diagnostics.missingBlocks)")
        XCTAssertTrue(document.diagnostics.unsupportedEntities.isEmpty, "\(document.diagnostics.unsupportedEntities)")
        XCTAssertTrue(document.entities.contains { $0.type == "INSERT" })
        XCTAssertTrue(document.entities.contains { $0.type == "DIMENSION" })
        let scene = CADScene(document: document)
        XCTAssertFalse(scene.items.isEmpty)
        XCTAssertTrue(scene.items.contains { $0.blockName != nil }, "block content is drawn")
        let derived = ProjectDerivation(project: project)
        let expected = CADRect(points: derived.drawing.primitives.flatMap(\.points))!
        XCTAssertGreaterThanOrEqual(scene.bounds.width, expected.width * 0.9)

        let compatible = DXFExchangeEngine().exportValidated(project: project)
        XCTAssertTrue(compatible.canWrite)
        let compatibleScene = CADScene(document: try CADDocumentReader().read(text: compatible.text))
        XCTAssertFalse(compatibleScene.items.isEmpty)
        XCTAssertTrue(compatibleScene.layers.contains { $0.id == ArchitecturalDraftingConvention.Layer.wall.rawValue })
    }

    func testProjectDrawingAdapterKeepsLayersAndIdentity() throws {
        let project = GoldenExchangeTests.project()
        let preview = ProjectDerivation(project: project).drawing
        let drawing = CADViewerDocument(source: .project, document: CADDocument(preview: preview))
        XCTAssertEqual(drawing.title, "Project drawing")
        XCTAssertEqual(drawing.document.units, .millimetres)
        XCTAssertEqual(drawing.document.entities.count, preview.primitives.filter { $0.kind != .text || $0.text != nil }.count)
        let wallLayer = ArchitecturalDraftingConvention.Layer.wall.rawValue
        XCTAssertEqual(drawing.document.layer(named: wallLayer).lineWeight, .hundredthsMM(50))
        XCTAssertTrue(drawing.scene.initiallyHiddenLayers.contains(ArchitecturalDraftingConvention.Layer.wallCenter.rawValue))
        let wall = try XCTUnwrap(drawing.scene.items.first { $0.layer == wallLayer })
        let entity = try XCTUnwrap(drawing.entity(for: wall))
        let wallIDs = Set(project.rooms.flatMap(\.walls).map(\.id.uuidString))
        XCTAssertTrue(entity.xdata[DXFExchangeEngine.applicationID]?.contains(where: wallIDs.contains) == true)
        let rows = drawing.inspection(of: wall)
        XCTAssertEqual(rows.first, CADInspectionRow("Type", entity.type))
        XCTAssertEqual(rows[1], CADInspectionRow("Layer", wallLayer))
        XCTAssertTrue(rows.contains { $0.title == "PlanOpsis object" })
        XCTAssertTrue(rows.contains { $0.title == "Area" || $0.title == "Length" })
    }

    /// Opens a DXF from outside the repository: `PLANOPSIS_DXF_SAMPLE=/path/to/file.dxf swift test`.
    func testExternalSampleDrawing() throws {
        guard let path = ProcessInfo.processInfo.environment["PLANOPSIS_DXF_SAMPLE"] else { throw XCTSkip("PLANOPSIS_DXF_SAMPLE not set") }
        let document = try CADDocumentReader().read(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        let scene = CADScene(document: document)
        print("CAD sample:", document.entities.count, "entities,", scene.items.count, "items,", scene.layers.count, "layers, bounds", scene.bounds, document.diagnostics.summary)
        XCTAssertFalse(scene.items.isEmpty)
        XCTAssertTrue(document.diagnostics.missingBlocks.isEmpty)
    }

    // MARK: Index, snaps and measuring

    func testSpatialIndexMatchesBruteForce() throws {
        var entities: [[(Int, Any)]] = []
        var seed: UInt64 = 42
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for _ in 0..<500 {
            let x = next() * 10_000, y = next() * 10_000
            entities.append([(0, "LINE"), (8, "0"), (10, x), (20, y), (11, x + next() * 800 - 400), (21, y + next() * 800 - 400)])
        }
        entities.append([(0, "LINE"), (8, "0"), (10, -5000), (20, -5000), (11, 15000), (21, 15000)])
        let scene = CADScene(document: try CADDocumentReader().read(text: DXFText.file(entities: entities)))
        for _ in 0..<50 {
            let x = next() * 10_000, y = next() * 10_000, w = next() * 2000
            let rect = CADRect(minX: x, minY: y, maxX: x + w, maxY: y + w)
            let expected = scene.items.filter { $0.bounds.intersects(rect) }.map(\.id)
            XCTAssertEqual(scene.index.query(rect), expected)
        }
    }

    func testObjectSnapsPreferPointSnapsAndComputeExactIntersections() throws {
        let text = DXFText.file(entities: [
            [(0, "LINE"), (8, "0"), (10, 0), (20, 0), (11, 1000), (21, 0)],
            [(0, "LINE"), (8, "0"), (10, 500), (20, -500), (11, 500), (21, 500)],
            [(0, "CIRCLE"), (8, "0"), (10, 2000), (20, 0), (40, 300)],
            [(0, "LINE"), (8, "0"), (10, 1500), (20, 0), (11, 2500), (21, 0)],
            [(0, "LINE"), (8, "0"), (10, 0), (20, 1000), (11, 400), (21, 1000)],
        ])
        let scene = CADScene(document: try CADDocumentReader().read(text: text))
        let engine = CADSnapEngine()
        XCTAssertEqual(engine.snap(at: Point2D(x: 990, y: 8), radius: 30, in: scene)?.kind, .endpoint)
        let crossing = try XCTUnwrap(engine.snap(at: Point2D(x: 512, y: 9), radius: 30, in: scene))
        XCTAssertEqual(crossing.kind, .intersection)
        XCTAssertTrue(near(crossing.point, Point2D(x: 500, y: 0)))
        XCTAssertEqual(engine.snap(at: Point2D(x: 205, y: 1006), radius: 30, in: scene)?.kind, .midpoint)
        let center = try XCTUnwrap(engine.snap(at: Point2D(x: 2010, y: 40), radius: 50, in: scene))
        XCTAssertEqual(center.kind, .center)
        // Line through the circle's centre meets it exactly at x = 1700 and 2300 (not the tessellation).
        let lineCircle = try XCTUnwrap(engine.snap(at: Point2D(x: 1705, y: 5), radius: 20, in: scene))
        XCTAssertTrue([.intersection, .quadrant].contains(lineCircle.kind))
        XCTAssertTrue(near(lineCircle.point, Point2D(x: 1700, y: 0), 1e-9))
        // Perpendicular from a point above the first line, away from its key points.
        let perpendicular = try XCTUnwrap(engine.snap(at: Point2D(x: 720, y: 10), radius: 30, in: scene, from: Point2D(x: 730, y: 400)))
        XCTAssertEqual(perpendicular.kind, .perpendicular)
        XCTAssertTrue(near(perpendicular.point, Point2D(x: 730, y: 0)))
        XCTAssertNil(engine.snap(at: Point2D(x: 720, y: 10), radius: 30, in: scene))
        var nearest = CADSnapEngine(kinds: [.nearest])
        nearest.maxIntersectionSegments = 10
        let n = try XCTUnwrap(nearest.snap(at: Point2D(x: 2000, y: 310), radius: 30, in: scene))
        XCTAssertTrue(near(n.point, Point2D(x: 2000, y: 300), 1e-9))
        XCTAssertNil(engine.snap(at: Point2D(x: 990, y: 8), radius: 30, in: scene, hiddenLayers: ["0"]))
    }

    func testPickingAndMeasurementFormatting() throws {
        let text = DXFText.file(entities: [
            [(0, "LINE"), (8, "A"), (10, 0), (20, 0), (11, 1000), (21, 0)],
            [(0, "SOLID"), (8, "B"), (10, 2000), (20, 0), (11, 3000), (21, 0), (12, 2000), (22, 1000), (13, 3000), (23, 1000)],
        ])
        let scene = CADScene(document: try CADDocumentReader().read(text: text))
        XCTAssertEqual(CADPicker.pick(at: Point2D(x: 400, y: 5), radius: 10, in: scene)?.layer, "A")
        XCTAssertEqual(CADPicker.pick(at: Point2D(x: 2500, y: 500), radius: 10, in: scene)?.layer, "B")
        XCTAssertNil(CADPicker.pick(at: Point2D(x: 400, y: 500), radius: 10, in: scene))
        guard case let .fill(loops) = scene.items[1].shape else { return XCTFail() }
        XCTAssertEqual(CADMeasurement.area(loops[0]), 1_000_000, accuracy: 1e-6, "SOLID corners are reordered to an outline")
        XCTAssertEqual(CADMeasurement.formatLength(3450, units: .millimetres), "3450 mm")
        XCTAssertEqual(CADMeasurement.formatLength(3.45, units: .metres), "3.450 m")
        XCTAssertEqual(CADMeasurement.formatArea(12_500_000, units: .millimetres), "12.50 m²")
        XCTAssertEqual(CADMeasurement.formatArea(12.5, units: .metres), "12.50 m²")
        XCTAssertEqual(CADMeasurement.chainLength([.zero, Point2D(x: 3, y: 4), Point2D(x: 3, y: 0)]), 9, accuracy: 1e-12)
        XCTAssertEqual(CADMeasurement.angleDegrees(.zero, Point2D(x: 0, y: -1)), 270, accuracy: 1e-9)
    }

    func testACIPaletteFixedColours() {
        XCTAssertEqual(CADColor.aci(1), CADColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(CADColor.aci(7), .white)
        XCTAssertEqual(CADColor.aci(10), CADColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(CADColor.aci(250), CADColor(red: 51, green: 51, blue: 51))
        XCTAssertEqual(CADColor(trueColor: 0x336699), CADColor(red: 0x33, green: 0x66, blue: 0x99))
    }
}
