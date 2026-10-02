import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class SurveyPersistenceTests: XCTestCase {
    func testRoomNamesHaveCanonicalObjectEncodingAndStableProjectHash() throws {
        var p=GoldenExchangeTests.project()
        p.survey.roomNames[p.rooms[0].id]="Living"
        let encoded=try JSONEncoder().encode(p)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        let survey=try XCTUnwrap(object["survey"] as? [String:Any])
        XCTAssertNotNil(survey["roomNames"] as? [String:String])
        XCTAssertEqual(try SurveyHash.value(p),try SurveyHash.value(ProjectMigrator().decode(encoded)))
    }
    func testV1MigrationPreservesIdentityGeometryAndEmptySurvey() throws {
        let original = GoldenExchangeTests.project()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "survey")
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let loaded = try ProjectStore(url: url).load()
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(loaded.rooms, original.rooms)
        XCTAssertEqual(ParametricGeometryEngine().generate(from: loaded), ParametricGeometryEngine().generate(from: original))
        XCTAssertEqual(try Data(contentsOf: url), data, "Loading never overwrites the original")
    }
    func testFutureSchemaDoesNotOverwriteExistingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{\"schemaVersion\":999}".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try ProjectStore(url: url).load())
        XCTAssertThrowsError(try ProjectStore(url: url).save(GoldenExchangeTests.project()))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testV2RoundTripPreservesSurveyAndRejectsDuplicateReferences() throws {
        var p = GoldenExchangeTests.project()
        p.survey.roomNames[p.rooms[0].id] = "Living room / Καθιστικό"
        p.survey.observations = [SurveyObservation(target: .wallLength(roomID:p.rooms[0].id, wallID:p.rooms[0].walls[0].id), observedMM:12000)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try ProjectMigrator().decode(data), p)
        p.survey.observations.append(p.survey.observations[0])
        XCTAssertThrowsError(try ProjectMigrator().decode(JSONEncoder().encode(p)))
        p.survey.observations.removeLast()
        p.survey.observations[0].target = .wallLength(roomID:p.rooms[0].id, wallID:UUID())
        XCTAssertThrowsError(try ProjectMigrator().decode(JSONEncoder().encode(p)))
    }

}
