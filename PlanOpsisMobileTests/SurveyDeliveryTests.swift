import XCTest
import CoreGraphics
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyDeliveryTests:XCTestCase {
    func testCompletePackageMovesWithVerifiedEvidenceAndRejectsMissingAssets() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let attachments=SurveyAttachmentStore(root:root.appendingPathComponent("source"))
        var p=GoldenExchangeTests.project();p.survey.roomNames[p.rooms[0].id]="Καθιστικό"
        let ref=try attachments.importAsset(data:Data("photo fixture".utf8),projectID:p.id,kind:.photo,sourceName:"room.jpg")
        p.survey.evidence=[ref]
        let destination=root.appendingPathComponent("delivery")
        let manifest=try SurveyDeliveryWriter().write(project:p,attachmentStore:attachments,destination:destination)
        XCTAssertTrue(manifest.files.contains{$0.path=="Survey.pdf"})
        XCTAssertTrue(manifest.files.contains{$0.path=="Survey.ifc"})
        let moved=root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:destination,to:moved)
        XCTAssertEqual(try SurveyDeliveryReader().read(root:moved),p)
        XCTAssertEqual(try SurveyAttachmentStore(root:moved).readVerified(ref,projectID:p.id),Data("photo fixture".utf8))
        for entry in manifest.files { XCTAssertEqual(SurveyHash.data(try Data(contentsOf:moved.appendingPathComponent(entry.path))),entry.sha256) }
        try FileManager.default.removeItem(at:attachments.root.appendingPathComponent(ref.relativePath))
        XCTAssertThrowsError(try SurveyDeliveryWriter().write(project:p,attachmentStore:attachments,destination:destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    }
    func testSheetsAreRealVectorPDFAtAllDrawingScales() throws {
        var p=GoldenExchangeTests.project();p.survey.roomNames[p.rooms[0].id]="Καθιστικό / Living room"
        for scale in [20,50,100] {
            p.survey.settings.scale=scale
            let data=try SurveySheetRenderer().render(project:p,dimensions:SurveyDimensionBuilder().build(project:p))
            let provider=try XCTUnwrap(CGDataProvider(data:data as CFData)),pdf=try XCTUnwrap(CGPDFDocument(provider))
            XCTAssertGreaterThan(pdf.numberOfPages,0)
            XCTAssertEqual(try XCTUnwrap(pdf.page(at:1)).getBoxRect(.mediaBox).width,420*72/25.4,accuracy:0.001)
            if let dir=ProcessInfo.processInfo.environment["PLANOPSIS_SURVEY_SHEET_DIR"] {
                let url=URL(fileURLWithPath:dir);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                try data.write(to:url.appendingPathComponent("Survey-1-\(scale).pdf"))
            }
        }
    }
}
