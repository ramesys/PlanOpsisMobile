import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyAttachmentTests: XCTestCase {
    func testVerifiedAttachmentSurvivesMoveAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:moved) }
        let store = SurveyAttachmentStore(root:root), id = UUID(), data = Data("scan A".utf8)
        let ref = try store.importAsset(data:data,projectID:id,kind:.sourcePLY,sourceName:"A.ply")
        _ = try store.importAsset(data:Data("scan B".utf8),projectID:id,kind:.sourcePLY,sourceName:"B.ply")
        XCTAssertEqual(try store.readVerified(ref,projectID:id), data)
        XCTAssertThrowsError(try store.readVerified(ref,projectID:UUID()))
        try FileManager.default.moveItem(at:root,to:moved)
        let movedStore = SurveyAttachmentStore(root:moved)
        XCTAssertEqual(try movedStore.readVerified(ref,projectID:id),data)
        try Data("tampered".utf8).write(to:moved.appendingPathComponent(ref.relativePath))
        XCTAssertThrowsError(try movedStore.readVerified(ref,projectID:id))
    }
    func testMissingAndEscapingAssetsCannotBeRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = SurveyAttachmentStore(root:root), id=UUID()
        var ref = try store.importAsset(data:Data("photo".utf8),projectID:id,kind:.photo,sourceName:"photo.jpg")
        try FileManager.default.removeItem(at:root.appendingPathComponent(ref.relativePath))
        XCTAssertThrowsError(try store.readVerified(ref,projectID:id))
        ref.relativePath = "../secret"
        XCTAssertThrowsError(try store.readVerified(ref,projectID:id))
        ref.relativePath = "link"
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try store.readVerified(ref,projectID:id))
    }
}
