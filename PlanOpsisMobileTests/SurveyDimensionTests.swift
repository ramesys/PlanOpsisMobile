import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyDimensionTests:XCTestCase {
    func testChainAndOverallReferencesFollowOpeningAndWallEdits() throws {
        var p=GoldenExchangeTests.project()
        p.survey.settings.showChains=true;p.survey.settings.showOverall=true
        let engine=SurveyDimensionBuilder(),snapshot=engine.build(project:p)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertTrue(snapshot.dimensions.contains{$0.kind=="overall" && abs($0.valueMM-12000)<0.001})
        let chains=snapshot.dimensions.filter{$0.kind=="chain" && $0.entityID==p.rooms[0].walls[0].id}
        XCTAssertEqual(chains.count,3)
        XCTAssertEqual(chains.reduce(0){$0+$1.valueMM},12000,accuracy:0.001)
        if case .door(var door)=p.rooms[0].openings[0] { door.parameters.offsetAlongWall += 100;p.rooms[0].openings[0] = .door(door) }
        let updated=engine.build(project:p)
        XCTAssertEqual(Set(updated.dimensions.filter{$0.kind=="chain"}.map(\.id)),Set(snapshot.dimensions.filter{$0.kind=="chain"}.map(\.id)))
        XCTAssertNotEqual(updated.dimensions.filter{$0.kind=="chain"}.map(\.valueMM),snapshot.dimensions.filter{$0.kind=="chain"}.map(\.valueMM))
    }
    func testDimensionsDeriveRealObliqueMeasurementsAndScale() throws {
        var p=GoldenExchangeTests.project()
        let engine=SurveyDimensionBuilder()
        let before=engine.build(project:p)
        XCTAssertTrue(before.issues.isEmpty)
        XCTAssertEqual(before.dimensions.filter{$0.kind == "wall"}.count,5)
        let id=p.rooms[0].walls[0].id
        XCTAssertEqual(before.dimensions.first{$0.entityID==id}?.valueMM,12000)
        p.rooms[0].walls[0].angleRadians = .pi/6
        let after=engine.build(project:p)
        XCTAssertEqual(try XCTUnwrap(after.dimensions.first{$0.entityID==id}?.valueMM),12000,accuracy:0.000001)
        for (scale,height) in [(20,50.0),(50,125.0),(100,250.0)] {
            p.survey.settings.scale=scale
            XCTAssertEqual(p.survey.settings.modelTextHeightMM,height)
        }
        var dimension=SurveyDimensionDefinition(target:.wallLength(roomID:p.rooms[0].id,wallID:id))
        dimension.textPosition=Point2D(x:1,y:2)
        p.survey.dimensions=[dimension]
        XCTAssertEqual(engine.build(project:p).dimensions.first{$0.id==dimension.id}?.textPosition,Point2D(x:1,y:2))
        p.rooms[0].walls.removeFirst()
        XCTAssertFalse(engine.build(project:p).issues.isEmpty)
    }
    func testPlacementOverridesRespectVisibilityAndReturnWhenEnabled() throws {
        var p=GoldenExchangeTests.project();p.survey.settings.showChains=true;p.survey.settings.showOverall=true
        let builder=SurveyDimensionBuilder(),snapshot=builder.build(project:p)
        let ids=Set(snapshot.dimensions.filter{["chain","overall"].contains($0.kind)}.map(\.id))
        p.survey.dimensions=builder.definitions(project:p).filter{ids.contains($0.id)}.map { original in
            var edited=original;edited.offsetMM += 50;return edited
        }
        let overrides=p.survey.dimensions
        p.survey.settings.showChains=false;p.survey.settings.showOverall=false
        XCTAssertTrue(builder.build(project:p).dimensions.allSatisfy{!["chain","overall"].contains($0.kind)})
        XCTAssertEqual(p.survey.dimensions,overrides)
        p.survey.settings.showChains=true;p.survey.settings.showOverall=true
        for d in overrides { XCTAssertEqual(builder.definitions(project:p).first{$0.id==d.id}?.offsetMM,d.offsetMM) }
    }

}
