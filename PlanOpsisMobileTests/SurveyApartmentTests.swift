import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyApartmentTests:XCTestCase {
    static func project()->PlanOpsisProject {
        func id(_ n:Int)->UUID { UUID(uuidString:String(format:"30000000-0000-4000-8000-%012d",n))! }
        func room(_ index:Int,_ points:[Point2D])->PlanOpsisRoom {
            let walls=points.indices.map { i -> PlanOpsisWall in
                let v=points[(i+1)%points.count]-points[i]
                return PlanOpsisWall(id:id(index+10+i),start:points[i],length:v.length,angleRadians:atan2(v.y,v.x),height:2800,thickness:200)
            }
            return PlanOpsisRoom(id:id(index+2),walls:walls,openings:[],components:[])
        }
        var a=room(0,[.init(x:0,y:0),.init(x:5000,y:0),.init(x:5000,y:4000),.init(x:0,y:4000)])
        var b=room(100,[.init(x:5000,y:0),.init(x:9500,y:0),.init(x:9500,y:3000),.init(x:8500,y:4000),.init(x:5000,y:4000)])
        a.openings=[.door(.init(parameters:.init(id:id(20),hostWallID:a.walls[1].id,offsetAlongWall:1800,width:900,height:2100,sillHeight:0),swing:.leftIn))]
        b.openings=[.window(.init(parameters:.init(id:id(120),hostWallID:b.walls[1].id,offsetAlongWall:1500,width:1200,height:1300,sillHeight:900),operation:.fixed))]
        a.components=[.init(id:id(30),kind:.table,position:.init(x:2000,y:2000),elevationMM:250)]
        b.components=[.init(id:id(130),kind:.chair,position:.init(x:7500,y:2000),rotationRadians:.pi/6)]
        var p=PlanOpsisProject(id:id(1),rooms:[a,b]);p.survey.roomNames=[a.id:"Καθιστικό",b.id:"Studio"]
        p.survey.settings.showChains=true;p.survey.settings.showOverall=true
        return p
    }
    func testSharedWallCorrectionPreservesBothRoomsAndSharedDimensionUniqueness() throws {
        var p=Self.project();let wall=p.rooms[0].walls[1]
        let o=SurveyObservation(target:.wallLength(roomID:p.rooms[0].id,wallID:wall.id),observedMM:4200)
        p.survey.observations=[o]
        let engine=SurveyCorrectionEngine(),proposal=engine.preview(observationID:o.id,anchor:.start,project:p)
        XCTAssertTrue(proposal.canApply,proposal.issues.joined(separator:";"))
        let changed=try engine.apply(proposal,to:p)
        XCTAssertEqual(changed.rooms[1].walls[4].start.y,4200,accuracy:0.001)
        XCTAssertEqual(changed.rooms[1].walls[4].length,4200,accuracy:0.001)
        let dims=SurveyDimensionBuilder().build(project:p)
        XCTAssertTrue(dims.issues.isEmpty)
        XCTAssertEqual(dims.dimensions.filter{$0.kind=="wall"}.count,8,"Shared boundary has one dimension")
        XCTAssertEqual(ParametricGeometryEngine().generate(from:changed).topology.roomBoundaries.filter(\.isClosed).count,2)
    }
    func testApartmentExportAndDeliveryFixture() throws {
        let p=Self.project(),dims=SurveyDimensionBuilder().build(project:p)
        let export=EditableDXFWriter().export(project:p,dimensions:dims,revisionID:GoldenExchangeTests.id(900))
        XCTAssertTrue(export.canWrite,export.issues.joined(separator:";"))
        let parsed=EditableDXFReader().read(export.text)
        let result=SurveyDXFReconciliationEngine().preview(drawing:parsed,baseline:export.manifest,current:p)
        XCTAssertEqual(try SurveyDXFReconciliationEngine().apply(result,to:p),p)
        XCTAssertEqual(p.rooms[0].components[0].elevationMM,250)
        if let dir=ProcessInfo.processInfo.environment["PLANOPSIS_APARTMENT_DIR"] {
            let root=URL(fileURLWithPath:dir)
            let store=SurveyAttachmentStore(root:root.appendingPathComponent("assets-source"))
            _ = try SurveyDeliveryWriter().write(project:p,attachmentStore:store,destination:root.appendingPathComponent("Apartment"))
        }
    }
}
