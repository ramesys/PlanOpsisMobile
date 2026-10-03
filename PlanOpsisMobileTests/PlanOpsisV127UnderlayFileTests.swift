import XCTest
@testable import PlanOpsisCore

/// v12.7 PDF line work for snapping and tracing, and the underlay saved with the project.
final class PlanOpsisV127UnderlayFileTests: XCTestCase {
    struct Forms: PDFFormResolver {
        var forms: [String: (String, CADAffine)]
        func form(named name: String) -> (content: Data, matrix: CADAffine, resources: PDFFormResolver?)? {
            forms[name].map { (Data($0.0.utf8), $0.1, self) }
        }
    }

    func assertEqual(_ a: Point2D, _ b: Point2D, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testPathsTransformsAndFormsBecomeSegments() {
        let content = """
        % a comment with operators m l S
        q 2 0 0 2 10 10 cm 0 0 m 100 0 l S Q
        0 0 50 50 re f
        BT /F1 12 Tf (Hello (nested\\)) l m S) Tj [(a) -120 (b)] TJ ET
        5 5 m 10 10 l 0 0 l h W n
        /GS0 gs <</MCID 3>> BDC 1 0 0 1 0 0 cm /Fm1 Do EMC
        """
        let resolver = Forms(forms: ["Fm1": ("0 0 m 1 1 l S /Fm2 Do", .scale(10, 10)), "Fm2": ("2 2 m 3 2 l s", .identity)])
        let segments = PDFVectorExtractor().segments(content: Data(content.utf8), resolver: resolver, pageTransform: .identity)
        XCTAssertEqual(segments.count, 1 + 4 + 1 + 2, "line, rectangle, form line, nested form line + its close; clipped path dropped")
        assertEqual(segments[0].0, Point2D(x: 10, y: 10))
        assertEqual(segments[0].1, Point2D(x: 210, y: 10))
        assertEqual(segments[5].1, Point2D(x: 10, y: 10), accuracy: 1e-9)
        assertEqual(segments[6].0, Point2D(x: 20, y: 20))
        assertEqual(segments[6].1, Point2D(x: 30, y: 20))
        assertEqual(segments[7].1, Point2D(x: 20, y: 20), accuracy: 1e-9)
    }

    func testCurvesAndInlineImages() {
        let content = Data("0 0 m 0 10 10 10 10 0 c S BI /W 2 /H 1 /BPC 8 /CS /G ID ".utf8) + Data([0x00, 0xFF, 0x45, 0x49]) + Data(" EI 0 0 m 5 0 l S".utf8)
        let segments = PDFVectorExtractor().segments(content: content, resolver: nil, pageTransform: .identity)
        XCTAssertEqual(segments.count, 8 + 1, "a flattened curve, then the line after the inline image")
        assertEqual(segments[7].1, Point2D(x: 10, y: 0))
        assertEqual(segments[8].1, Point2D(x: 5, y: 0))
    }

    func testPageTransformMapsRotatedPagesToPaperMillimetres() {
        let box = CADRect(minX: 10, minY: 20, maxX: 110, maxY: 220) // 100 × 200 pt, offset origin
        let k = 25.4 / 72
        let upright = PDFVectorExtractor.pageTransform(mediaBox: box, rotation: 0)
        assertEqual(upright.apply(Point2D(x: 10, y: 20)), .zero)
        assertEqual(upright.apply(Point2D(x: 110, y: 220)), Point2D(x: 100 * k, y: 200 * k))
        // Turned a quarter clockwise: the sheet is 200 pt wide and its old bottom-left is now top-left.
        let turned = PDFVectorExtractor.pageTransform(mediaBox: box, rotation: 90)
        assertEqual(turned.apply(Point2D(x: 10, y: 20)), Point2D(x: 0, y: 100 * k))
        assertEqual(turned.apply(Point2D(x: 110, y: 220)), Point2D(x: 200 * k, y: 0))
        let upside = PDFVectorExtractor.pageTransform(mediaBox: box, rotation: 180)
        assertEqual(upside.apply(Point2D(x: 10, y: 20)), Point2D(x: 100 * k, y: 200 * k))
        let back = PDFVectorExtractor.pageTransform(mediaBox: box, rotation: -90)
        assertEqual(back.apply(Point2D(x: 10, y: 20)), Point2D(x: 200 * k, y: 0))
    }

    func testVectorPDFPageTracesLikeADrawing() throws {
        // A 200 mm wall drawn at 1:100 on paper: faces 2 mm apart, in points.
        let pt = 72 / 25.4
        func y(_ mm: Double) -> String { String(format: "%.4f", mm * pt) }
        let content = "0.25 w 0 \(y(50)) m \(y(80)) \(y(50)) l S 0 \(y(52)) m \(y(80)) \(y(52)) l S 0 0 m 0 0.01 l S"
        let document = try XCTUnwrap(PDFVectorExtractor().document(content: Data(content.utf8), resolver: nil,
                                                                   pageTransform: PDFVectorExtractor.pageTransform(mediaBox: CADRect(minX: 0, minY: 0, maxX: 842, maxY: 595), rotation: 0)))
        XCTAssertEqual(document.entities.count, 2, "hair-thin specks are dropped")
        let placement = UnderlayPlacement()
        let scene = CADScene(document: document, transform: placement.transform(unitScale: 100))
        let wall = try XCTUnwrap(UnderlayWallTracer(scene: scene).trace(at: Point2D(x: 4_000, y: 5_100)))
        XCTAssertEqual(wall.thickness, 200, accuracy: 0.5)
        XCTAssertEqual(wall.length, 8_000, accuracy: 0.5)
        XCTAssertNil(PDFVectorExtractor().document(content: Data("BT (scan) Tj ET".utf8), resolver: nil, pageTransform: .identity))
    }

    func testProjectKeepsItsUnderlayAndOlderProjectsStillOpen() throws {
        var project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 100)
        let asset = SurveyEvidenceReference(id: UUID(), projectID: project.id, relativePath: "assets/x/y.asset", sha256: "abc", sourceName: "Plan.pdf", kind: .underlay)
        project.underlay = ProjectUnderlay(format: .pdf, asset: asset, fileName: "Plan.pdf",
                                           placement: UnderlayPlacement(offset: Point2D(x: 1, y: 2), rotationDegrees: 12, scale: 1.02),
                                           paperScale: 50, pageIndex: 2, isVisible: false)
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(PlanOpsisProject.self, from: data)
        XCTAssertEqual(decoded, project)

        let plain = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 100)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("underlay"), "projects without an underlay are written as before")
        XCTAssertNil(try JSONDecoder().decode(PlanOpsisProject.self, from: Data(plainJSON.utf8)).underlay)

        XCTAssertEqual(ProjectUnderlay.format(forFileName: "A-101.PDF"), .pdf)
        XCTAssertEqual(ProjectUnderlay.format(forFileName: "model.ifc"), .ifc)
        XCTAssertEqual(ProjectUnderlay.format(forFileName: "plan.dxf"), .dxf)
    }

    func testUnderlayAssetIsStoredAndVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planopsis-underlay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SurveyAttachmentStore(root: root)
        let projectID = UUID()
        let bytes = Data("0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n".utf8)
        let reference = try store.importAsset(data: bytes, projectID: projectID, kind: .underlay, sourceName: "Plan.dxf")
        XCTAssertEqual(reference.kind, .underlay)
        XCTAssertEqual(try store.readVerified(reference, projectID: projectID), bytes)
        XCTAssertThrowsError(try store.readVerified(reference, projectID: UUID()), "another project's underlay is refused")
    }
}
