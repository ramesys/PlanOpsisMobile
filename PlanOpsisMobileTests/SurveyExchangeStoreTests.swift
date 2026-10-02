import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyExchangeStoreTests:XCTestCase {
    func testStoredBaselineCanBeRecoveredButCannotBeReplacedOrMisassociated() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let p=GoldenExchangeTests.project(),revision=UUID()
        let export=EditableDXFWriter().export(project:p,dimensions:SurveyDimensionBuilder().build(project:p),revisionID:revision)
        let store=SurveyExchangeStore(root:root)
        try store.save(export.manifest)
        XCTAssertEqual(try store.load(projectID:p.id,revisionID:revision),export.manifest)
        var changed=export.manifest;changed.baseline.survey.notes="Changed baseline"
        XCTAssertThrowsError(try store.save(changed))
        XCTAssertThrowsError(try store.load(projectID:UUID(),revisionID:revision))
    }
}
