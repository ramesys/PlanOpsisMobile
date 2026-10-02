#if os(iOS)
import XCTest
@testable import PlanOpsisMobile
@MainActor final class SurveyNativeWorkflowTests:XCTestCase {
    func testCorrectionUndoSaveReopenAndReviewedRhinoReturn() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=PlanOpsisMobileStore(storageRoot:root)
        store.importSnapshot(MockRoomCaptureProvider().snapshot())
        let original=try XCTUnwrap(store.project),room=original.rooms[0],wall=room.walls[0]
        store.renameRoom(room.id,name:"Καθιστικό")
        let observation=SurveyObservation(target:.wallLength(roomID:room.id,wallID:wall.id),observedMM:wall.length+100,toleranceMM:1)
        store.recordObservation(observation)
        let before=try XCTUnwrap(store.project)
        let proposal=SurveyCorrectionEngine().preview(observationID:observation.id,anchor:.start,project:before)
        XCTAssertTrue(store.applySurveyCorrection(proposal),store.statusMessage ?? "")
        let corrected=try XCTUnwrap(store.project)
        store.undo();XCTAssertEqual(store.project,before)
        store.redo();XCTAssertEqual(store.project,corrected)
        store.verifyObservation(observation.id);store.setSurveyLock(observation.id,locked:true)
        let verified=try XCTUnwrap(store.project)
        XCTAssertTrue(verified.survey.observations[0].locked)
        store.save();store.closeProject();store.reopen();XCTAssertEqual(store.project,verified)
        store.dxfExportProfile = .rhinoEditable
        let text=try XCTUnwrap(store.exportDXFText(),store.statusMessage ?? "")
        store.previewSurveyReturn(text)
        XCTAssertTrue(try XCTUnwrap(store.surveyImportProposal).canApply)
        store.applySurveyReturn();XCTAssertEqual(store.project,verified)
        let prepared=await store.prepareSurveyDelivery()
        let package=try XCTUnwrap(prepared,store.statusMessage ?? "")
        let moved=root.appendingPathComponent("MovedPackage")
        try FileManager.default.moveItem(at:package,to:moved)
        store.closeProject();await store.openSurveyDelivery(moved)
        XCTAssertEqual(store.project,verified)
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let evidence=documents.appendingPathComponent("NativeSurveyAcceptance-"+UUID().uuidString)
        try FileManager.default.copyItem(at:moved,to:evidence)
        print("NATIVE_SURVEY_DELIVERY="+evidence.path)
    }
    func testGenericImportDoesNotReplaceSurveyWhenIdentityMetadataIsLost() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=PlanOpsisMobileStore(storageRoot:root)
        store.importSnapshot(MockRoomCaptureProvider().snapshot())
        let room=try XCTUnwrap(store.project?.rooms.first)
        store.renameRoom(room.id,name:"Retain survey")
        let before=try XCTUnwrap(store.project)
        store.dxfExportProfile = .rhinoEditable
        let text=try XCTUnwrap(store.exportDXFText()).replacingOccurrences(of:"PO12:",with:"REMOVED:")
        store.importDXF(data:Data(text.utf8))
        XCTAssertEqual(store.project,before)
        XCTAssertFalse(store.surveyImportProposal?.canApply ?? false)
        store.undo()
        XCTAssertNotEqual(store.project?.survey.roomNames[room.id],"Retain survey","Import must preserve undo history")
    }

    func testSurveyDocumentCanStageBesidePreparedPackage() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("PlanOpsis-Survey-Source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("survey".utf8).write(to:source.appendingPathComponent("Project.planopsis.json"))
        let document=try SurveyPackageDocument(url:source)
        let staged=root.appendingPathComponent(document.wrapper.preferredFilename ?? "PlanOpsis-Survey")
        XCTAssertFalse(FileManager.default.fileExists(atPath:staged.path),"Export staging name must not collide with prepared source")
        try document.wrapper.write(to:staged,options:.atomic,originalContentsURL:nil)
        XCTAssertEqual(try Data(contentsOf:staged.appendingPathComponent("Project.planopsis.json")),Data("survey".utf8))
    }

}
#endif
