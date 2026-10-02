import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyMeasurementTests: XCTestCase {
    func testResidualToleranceAndGeometryFingerprint() throws {
        var p=GoldenExchangeTests.project();p.rooms[0].walls[0].length=5000
        let target=SurveyMeasurementTarget.wallLength(roomID:p.rooms[0].id,wallID:p.rooms[0].walls[0].id)
        let engine=SurveyMeasurementEngine()
        var o=SurveyObservation(target:target,observedMM:5003,toleranceMM:2)
        XCTAssertEqual(engine.evaluate(o,in:p).residualMM,-3)
        XCTAssertEqual(engine.evaluate(o,in:p).status,.unchecked)
        o.verificationFingerprint=try engine.fingerprint(for:target,in:p)
        XCTAssertEqual(engine.evaluate(o,in:p).status,.outsideTolerance)
        o.toleranceMM=3
        XCTAssertEqual(engine.evaluate(o,in:p).status,.withinTolerance)
        p.rooms[0].components[0].position.x += 200
        XCTAssertEqual(engine.evaluate(o,in:p).status,.withinTolerance)
        p.rooms[0].walls[0].length += 1
        XCTAssertEqual(engine.evaluate(o,in:p).status,.needsRecheck)
    }
    func testFaceDistanceAndInvalidTargets() throws {
        var p=GoldenExchangeTests.project(); let r=p.rooms[0], w=r.walls[0]
        let a=SurveyPoint(roomID:r.id,wallID:w.id,location:.face(stationMM:0,side:1))
        let b=SurveyPoint(roomID:r.id,wallID:w.id,location:.face(stationMM:3000,side:1))
        let engine=SurveyMeasurementEngine(),o=SurveyObservation(target:.distance(from:a,to:b),observedMM:3000)
        XCTAssertEqual(try XCTUnwrap(engine.evaluate(o,in:p).currentMM),3000,accuracy:0.000001)
        p.rooms[0].walls[0].angleRadians = .pi/6
        XCTAssertEqual(try XCTUnwrap(engine.evaluate(o,in:p).currentMM),3000,accuracy:0.000001)
        p.rooms[0].walls=[]
        XCTAssertEqual(engine.evaluate(o,in:p).status,.invalidReference)
        XCTAssertEqual(SurveyUnit.m.factor*5,5000)
        XCTAssertEqual(SurveyUnit.cm.factor*500,5000)
    }
}
