import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class EditableDXFTests:XCTestCase {
    func testNativeDimensionsBlocksAndDeterministicIdentity() throws {
        let p=GoldenExchangeTests.project(),revision=UUID(uuidString:"20000000-0000-4000-8000-000000000001")!
        let writer=EditableDXFWriter(),dims=SurveyDimensionBuilder().build(project:p)
        let export=writer.export(project:p,dimensions:dims,revisionID:revision)
        XCTAssertTrue(export.canWrite,export.issues.joined(separator:";"))
        XCTAssertEqual(export.text,writer.export(project:p,dimensions:dims,revisionID:revision).text)
        let drawing=EditableDXFReader().read(export.text)
        XCTAssertTrue(drawing.issues.isEmpty,drawing.issues.joined(separator:";"))
        XCTAssertEqual(drawing.controls.filter{$0.kind=="wall"}.count,5)
        XCTAssertEqual(drawing.controls.filter{$0.kind=="component"}.count,8)
        XCTAssertEqual(drawing.controls.filter{$0.kind=="opening"}.count,4)
        XCTAssertEqual(drawing.dimensions.count,dims.dimensions.count)
        XCTAssertEqual(drawing.units,4)
        XCTAssertTrue(export.text.contains("1001\r\nRhino\r\n1002\r\n{\r\n1000\r\nPlanOpsisControl\r\n1000\r\nPO12:"))
        XCTAssertTrue(export.text.contains("\r\nDIMSTYLE\r\n"))
        XCTAssertTrue(export.text.contains("\r\nINSERT\r\n"))
        if let dir=ProcessInfo.processInfo.environment["PLANOPSIS_SURVEY_FIXTURE_DIR"] {
            let url=URL(fileURLWithPath:dir);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            try export.text.write(to:url.appendingPathComponent("Survey.dxf"),atomically:true,encoding:.utf8)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(export.manifest).write(to:url.appendingPathComponent("Survey.exchange.json"))
            try encoder.encode(p).write(to:url.appendingPathComponent("Survey.planopsis.json"))
        }
    }
}
