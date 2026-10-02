import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class GoldenExchangeTests: XCTestCase {
    static func id(_ value: Int) -> UUID { UUID(uuidString:String(format:"10000000-0000-4000-8000-%012d",value))! }
    static func project() -> PlanOpsisProject {
        let points=[Point2D(x:-5000,y:-3000),Point2D(x:7000,y:-3000),Point2D(x:7000,y:5500),Point2D(x:-5000,y:5500)]
        var walls=points.indices.map { i -> PlanOpsisWall in
            let v=points[(i+1)%4]-points[i]
            return PlanOpsisWall(id:id(10+i),start:points[i],length:v.length,angleRadians:atan2(v.y,v.x),height:2800,thickness:240)
        }
        walls.append(PlanOpsisWall(id:id(14),start:Point2D(x:2000,y:-3000),length:3000,angleRadians:.pi/2,height:2800,thickness:160))
        func params(_ n:Int,_ host:Int,_ offset:Double,_ width:Double,_ height:Double,_ sill:Double) -> HostedOpeningParameters {
            HostedOpeningParameters(id:id(n),hostWallID:id(host),offsetAlongWall:offset,width:width,height:height,sillHeight:sill)
        }
        let openings:[PlanOpsisOpening]=[
            .door(PlanOpsisDoor(parameters:params(20,10,1600,900,2100,0),swing:.leftIn)),
            .door(PlanOpsisDoor(parameters:params(21,14,1600,1400,2100,0),operation:.sliding)),
            .window(PlanOpsisWindow(parameters:params(22,11,2400,1600,1200,900),operation:.fixed)),
            .window(PlanOpsisWindow(parameters:params(23,12,3200,1800,1400,800),operation:.doubleCasement))
        ]
        let components=[
            PlanOpsisComponent(id:id(30),kind:.column,position:Point2D(x:-4200,y:-1200),width:350,depth:350),
            PlanOpsisComponent(id:id(31),kind:.chair,position:Point2D(x:-1500,y:-1100)),
            PlanOpsisComponent(id:id(32),kind:.table,position:Point2D(x:-1500,y:-200),width:1400,depth:800),
            PlanOpsisComponent(id:id(33),kind:.bed,position:Point2D(x:-3400,y:3400)),
            PlanOpsisComponent(id:id(34),kind:.sofa,position:Point2D(x:400,y:4000),width:2100),
            PlanOpsisComponent(id:id(35),kind:.wc,position:Point2D(x:5100,y:1800),rotationRadians:.pi/2),
            PlanOpsisComponent(id:id(36),kind:.sink,position:Point2D(x:5700,y:3100),rotationRadians:.pi/2),
            PlanOpsisComponent(id:id(37),kind:.chair,position:Point2D(x:3400,y:400),width:550,depth:500,rotationRadians:.pi/4)
        ]
        return PlanOpsisProject(id:id(1),rooms:[PlanOpsisRoom(id:id(2),walls:walls,openings:openings,components:components)])
    }

    func testGoldenProjectKeepsPerimeterInteriorWallAndCrossFormatIdentity() throws {
        let project=Self.project(), engine=DXFExchangeEngine()
        let dxf=engine.exportValidated(project:project,representation:.semanticObservations)
        let ifc=IFC4ExchangeEngine().exportValidated(project:project)
        XCTAssertTrue(dxf.canWrite,"\(dxf.issues)");XCTAssertTrue(ifc.canWrite,"\(ifc.issues)")
        let preview=engine.preview(for:project,representation:.semanticObservations)
        let room=project.rooms[0]
        XCTAssertEqual(room.walls.count,5)
        for wall in room.walls { XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .wall && $0.objectIDs.contains(wall.id) }) }
        XCTAssertTrue(preview.primitives.contains { $0.id.hasPrefix("room-name:") })
        XCTAssertEqual(preview.primitives.filter { $0.id.hasPrefix("dim-text:") }.count,5)
        let ids=[room.id]+room.walls.map(\.id)+room.openings.map(\.id)+room.components.map(\.id)
        for id in ids {
            let gid=try XCTUnwrap(ifc.objectGlobalIDs[id])
            XCTAssertTrue(dxf.text.contains("OBJECT:\(id.uuidString)"))
            XCTAssertTrue(dxf.text.contains("IFC_GUID:\(gid)"))
        }
        let roundTrip=try XCTUnwrap(engine.import(dxf.text).project)
        XCTAssertEqual(Set(roundTrip.rooms.flatMap(\.components).map(\.id)),Set(room.components.map(\.id)))
        XCTAssertEqual(ifc.text,IFC4ExchangeEngine().export(project:project))
        XCTAssertTrue(ifc.text.contains("$,.ADDED.,0,$,$,0)"))
        guard let directory=ProcessInfo.processInfo.environment["PLANOPSIS_GOLDEN_DIR"] else { return }
        let url=URL(fileURLWithPath:directory,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(project).write(to:url.appendingPathComponent("PlanOpsis_DXF_GoldenPlan.planopsis.json"))
        try dxf.text.write(to:url.appendingPathComponent("PlanOpsis_DXF_GoldenPlan.dxf"),atomically:true,encoding:.utf8)
        try ifc.text.write(to:url.appendingPathComponent("PlanOpsis_IFC4_GoldenModel.ifc"),atomically:true,encoding:.utf8)
        try encoder.encode(preview).write(to:url.appendingPathComponent("GoldenPlan.primitives.json"))
        var matrix:[[String:Any]]=[]
        for id in ids {
            let primitives=preview.primitives.filter { $0.objectIDs.contains(id) }
            let first=try XCTUnwrap(primitives.first)
            matrix.append(["uuid":id.uuidString,"semantic_type":first.semanticType ?? first.ifcClass!.rawValue,
                           "dxf_layers":Array(Set(primitives.map(\.layer))).sorted(),"dxf_symbol":primitives.map(\.id),
                           "dxf_ifc_guid":PlanOpsisExchangeIdentity.ifcGlobalID(for:id),"ifc_class":first.ifcClass!.rawValue,"ifc_global_id":ifc.objectGlobalIDs[id]!])
        }
        try JSONSerialization.data(withJSONObject:matrix,options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathComponent("DXF_IFC_identity_matrix.json"))
        var symbolBounds:[String:FloorGeometry]=[:]
        for c in room.components { symbolBounds[c.id.uuidString]=ArchitecturalSymbolLibrary.component(c).bounds }
        let geometry=ParametricGeometryEngine().generate(from:project).semanticDisplaySnapshot()
        for o in geometry.hostedOpenings { if let id=o.primarySelectionID { symbolBounds[id.uuidString]=ArchitecturalSymbolLibrary.opening(o,roomFloors:geometry.roomFloors).bounds } }
        try encoder.encode(symbolBounds).write(to:url.appendingPathComponent("GoldenPlan.symbol-bounds.json"))
    }

    func testGoldenTranslationAndRotationPreserveIFCIDsAndDXFMeasurements() throws {
        let original=Self.project()
        var moved=original
        let angle=Double.pi/6,delta=Point2D(x:-14000,y:8700)
        func transform(_ p:Point2D)->Point2D { Point2D(x:p.x*cos(angle)-p.y*sin(angle),y:p.x*sin(angle)+p.y*cos(angle))+delta }
        for i in moved.rooms[0].walls.indices { moved.rooms[0].walls[i].start=transform(moved.rooms[0].walls[i].start);moved.rooms[0].walls[i].angleRadians += angle }
        for i in moved.rooms[0].components.indices { moved.rooms[0].components[i].position=transform(moved.rooms[0].components[i].position);moved.rooms[0].components[i].rotationRadians += angle }
        let a=IFC4ExchangeEngine().exportValidated(project:original),b=IFC4ExchangeEngine().exportValidated(project:moved)
        XCTAssertTrue(b.canWrite);XCTAssertEqual(a.objectGlobalIDs,b.objectGlobalIDs)
        let engine=DXFExchangeEngine()
        let labels=engine.preview(for:original).primitives.filter { $0.id.hasPrefix("dim-text:") }
        let movedLabels=engine.preview(for:moved).primitives.filter { $0.id.hasPrefix("dim-text:") }
        XCTAssertEqual(labels.count,movedLabels.count)
        for label in labels {
            let other=try XCTUnwrap(movedLabels.first { $0.id == label.id })
            XCTAssertEqual(label.text,other.text)
            let expected=transform(label.points[0])
            XCTAssertEqual(other.points[0].x,expected.x,accuracy:1e-6);XCTAssertEqual(other.points[0].y,expected.y,accuracy:1e-6)
        }
        if let directory=ProcessInfo.processInfo.environment["PLANOPSIS_GOLDEN_DIR"] {
            let url=URL(fileURLWithPath:directory,isDirectory:true)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            try b.text.write(to:url.appendingPathComponent("GoldenModel.transformed.ifc"),atomically:true,encoding:.utf8)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
            try encoder.encode(moved).write(to:url.appendingPathComponent("GoldenModel.transformed.json"))
        }
    }
}
