import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyCorrectionTests:XCTestCase {
    func testAnchoredCorrectionPropagatesAndUndoPreservesSurvey() throws {
        var p=GoldenExchangeTests.project();let r=p.rooms[0],w=r.walls[0]
        let o=SurveyObservation(target:.wallLength(roomID:r.id,wallID:w.id),observedMM:12500)
        p.survey.observations=[o]
        let engine=SurveyCorrectionEngine(),proposal=engine.preview(observationID:o.id,anchor:.start,project:p)
        XCTAssertTrue(proposal.canApply,proposal.issues.joined(separator:";"))
        let changed=try engine.apply(proposal,to:p)
        XCTAssertEqual(changed.rooms[0].walls[0].length,12500,accuracy:1e-6)
        XCTAssertEqual(changed.rooms[0].walls[0].start,w.start)
        XCTAssertEqual(changed.rooms[0].walls[1].start,changed.rooms[0].walls[0].end)
        // v12.1: openings keep their distance from the wall end that did not move. Wall 0 is anchored at
        // its start, so its door is unchanged; wall 1's start moved, so its window keeps its distance from wall 1's end.
        let w1Before=r.walls[1],w1After=changed.rooms[0].walls[1]
        for (before,after) in zip(p.rooms[0].openings,changed.rooms[0].openings) {
            if before.parameters.hostWallID==w1Before.id {
                XCTAssertEqual(w1After.length-after.parameters.offsetAlongWall,w1Before.length-before.parameters.offsetAlongWall,accuracy:1e-6)
            } else {
                XCTAssertEqual(after,before)
            }
        }
        var history=PlanOpsisEditHistory(maxDepth:10)
        history.record(EditorHistorySnapshot(project:p),label:"Correction")
        XCTAssertEqual(history.undo(current:EditorHistorySnapshot(project:changed))?.project,p)
        XCTAssertEqual(history.redo(current:EditorHistorySnapshot(project:p))?.project,changed)
        var stale=p;stale.survey.notes="changed"
        XCTAssertThrowsError(try engine.apply(proposal,to:stale))
    }
    func testClippedOpeningAndLockedChecksRejectWithoutMutation() throws {
        var p=GoldenExchangeTests.project();let r=p.rooms[0],w=r.walls[0]
        let o=SurveyObservation(target:.wallLength(roomID:r.id,wallID:w.id),observedMM:100)
        p.survey.observations=[o]
        let engine=SurveyCorrectionEngine(),proposal=engine.preview(observationID:o.id,anchor:.start,project:p)
        XCTAssertFalse(proposal.canApply)
        XCTAssertThrowsError(try engine.apply(proposal,to:p))
        p.survey.observations[0].observedMM=12500
        var locked=SurveyObservation(target:o.target,observedMM:12000,toleranceMM:1);locked.locked=true
        p.survey.observations.append(locked)
        XCTAssertFalse(engine.preview(observationID:o.id,anchor:.start,project:p).canApply)
    }
}
