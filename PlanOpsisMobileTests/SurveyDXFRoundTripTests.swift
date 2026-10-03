import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif
final class SurveyDXFRoundTripTests:XCTestCase {
    func exported(_ p:PlanOpsisProject)->SurveyDXFExport { EditableDXFWriter().export(project:p,dimensions:SurveyDimensionBuilder().build(project:p),revisionID:UUID()) }
    func edit(_ text:String,id:UUID,code:Int,value:String) throws -> String {
        var doc=try SurveyDXFDocument(text)
        let i=try XCTUnwrap(doc.indices(in:"ENTITIES").first { doc.records[$0].tags.contains { $0.value.contains("PO12:") && $0.value.contains(id.uuidString) } })
        doc.records[i].set(code,value);return doc.text
    }
    func testLiveRhinoReturnedFixture() throws {
        guard let dir=ProcessInfo.processInfo.environment["PLANOPSIS_RHINO_RETURN_DIR"] else { throw XCTSkip("Requires retained native Rhino evidence") }
        let url=URL(fileURLWithPath:dir)
        let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:Data(contentsOf:url.appendingPathComponent("Survey.exchange.json")))
        let text=try String(contentsOf:url.appendingPathComponent("RhinoReturned.dxf"),encoding:.utf8)
        let drawing=EditableDXFReader().read(text)
        XCTAssertTrue(drawing.issues.isEmpty,drawing.issues.joined(separator:";"))
        let proposal=SurveyDXFReconciliationEngine().preview(drawing:drawing,baseline:manifest,current:manifest.baseline)
        XCTAssertTrue(proposal.canApply,proposal.issues.joined(separator:";"))
        XCTAssertEqual(proposal.proposedProject,manifest.baseline)
    }
    func testLiveRhinoEditedFixtureAppliesAndPersistsWithoutChangingIdentity() throws {
        guard let dir=ProcessInfo.processInfo.environment["PLANOPSIS_RHINO_RETURN_DIR"] else { throw XCTSkip("Requires retained native Rhino edit evidence") }
        let url=URL(fileURLWithPath:dir)
        let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:Data(contentsOf:url.appendingPathComponent("Survey.exchange.json")))
        let text=try String(contentsOf:url.appendingPathComponent("RhinoEdited.dxf"),encoding:.utf8)
        let engine=SurveyDXFReconciliationEngine()
        let proposal=engine.preview(drawing:EditableDXFReader().read(text),baseline:manifest,current:manifest.baseline)
        XCTAssertTrue(proposal.canApply,proposal.issues.joined(separator:";"))
        let changed=try engine.apply(proposal,to:manifest.baseline)
        XCTAssertEqual(changed.rooms[0].components[1].position.x,-1200,accuracy:0.001)
        XCTAssertEqual(changed.rooms[0].components[1].position.y,-900,accuracy:0.001)
        XCTAssertEqual(changed.rooms[0].components[1].rotationRadians,Double.pi/6,accuracy:0.000001)
        XCTAssertEqual(changed.rooms[0].walls[4].length,3100,accuracy:0.001)
        XCTAssertEqual(changed.rooms[0].openings[0].parameters.offsetAlongWall,1750,accuracy:0.001)
        XCTAssertEqual(changed.survey.dimensions.count,1)
        XCTAssertEqual(proposal.changes.count,4)
        let ifc=IFC4ExchangeEngine().exportValidated(project:changed)
        XCTAssertEqual(ifc.objectGlobalIDs,IFC4ExchangeEngine().exportValidated(project:manifest.baseline).objectGlobalIDs)
        let destination=url.appendingPathComponent("Accepted.planopsis.json")
        try ProjectStore(url:destination).save(changed)
        XCTAssertEqual(try ProjectStore(url:destination).load(),changed)
        try ifc.text.write(to:url.appendingPathComponent("Accepted.ifc"),atomically:true,encoding:.utf8)
    }
    func testUnchangedAndMovedFurniturePreserveProjectSurveyAndIFCIdentity() throws {
        var p=GoldenExchangeTests.project();p.survey.notes="Measured apartment"
        let export=exported(p),engine=SurveyDXFReconciliationEngine(),reader=EditableDXFReader()
        let unchanged=engine.preview(drawing:reader.read(export.text),baseline:export.manifest,current:p)
        XCTAssertEqual(try engine.apply(unchanged,to:p),p)
        let id=p.rooms[0].components[1].id
        let edited=try edit(export.text,id:id,code:10,value:"-1200")
        let proposal=engine.preview(drawing:reader.read(edited),baseline:export.manifest,current:p)
        XCTAssertTrue(proposal.canApply,proposal.issues.joined(separator:";"))
        let changed=try engine.apply(proposal,to:p)
        XCTAssertEqual(changed.id,p.id);XCTAssertEqual(changed.survey,p.survey)
        XCTAssertEqual(changed.rooms[0].components[1].position.x,-1200)
        XCTAssertEqual(IFC4ExchangeEngine().exportValidated(project:changed).objectGlobalIDs,IFC4ExchangeEngine().exportValidated(project:p).objectGlobalIDs)
        var concurrent=p;concurrent.rooms[0].components[1].position.x += 50
        XCTAssertFalse(engine.preview(drawing:reader.read(edited),baseline:export.manifest,current:concurrent).canApply)
        XCTAssertThrowsError(try engine.apply(proposal,to:concurrent))
    }
    func testChangedDimensionReferenceIsRejected() throws {
        let p=GoldenExchangeTests.project(),export=exported(p)
        let d=try XCTUnwrap(EditableDXFReader().read(export.text).dimensions.first)
        let edited=try edit(export.text,id:d.id,code:13,value:"12345")
        XCTAssertFalse(SurveyDXFReconciliationEngine().preview(drawing:EditableDXFReader().read(edited),baseline:export.manifest,current:p).canApply)
    }
    func testUnsupportedScalingLostMetadataAndOutlineEditsAreBlocked() throws {
        let p=GoldenExchangeTests.project(),export=exported(p),engine=SurveyDXFReconciliationEngine(),reader=EditableDXFReader()
        let scaled=try edit(export.text,id:p.rooms[0].components[0].id,code:41,value:"2")
        XCTAssertFalse(engine.preview(drawing:reader.read(scaled),baseline:export.manifest,current:p).canApply)
        let stripped=export.text.replacingOccurrences(of:"PO12:",with:"REMOVED:")
        XCTAssertFalse(engine.preview(drawing:reader.read(stripped),baseline:export.manifest,current:p).canApply)
        var doc=try SurveyDXFDocument(export.text)
        let i=try XCTUnwrap(doc.indices(in:"ENTITIES").first{doc.records[$0].string(8)=="IfcWall"})
        doc.records[i].set(10,"123456")
        XCTAssertFalse(engine.preview(drawing:reader.read(doc.text),baseline:export.manifest,current:p).canApply)
    }
    func testConflictingConnectedEndpointDestinationsAreRejected() throws {
        let p=GoldenExchangeTests.project(),export=exported(p)
        var doc=try SurveyDXFDocument(export.text)
        let ids=p.rooms[0].walls.prefix(2).map(\.id)
        for (offset,id) in ids.enumerated() {
            let i=try XCTUnwrap(doc.indices(in:"ENTITIES").first { doc.records[$0].tags.contains{$0.value.contains("PO12:wall:"+id.uuidString)} })
            let xs=doc.records[i].tags.indices.filter{doc.records[i].tags[$0].code==10}
            doc.records[i].tags[xs[offset==0 ? 1:0]].value=String(7100+offset*100)
        }
        let proposal=SurveyDXFReconciliationEngine().preview(drawing:EditableDXFReader().read(doc.text),baseline:export.manifest,current:p)
        XCTAssertFalse(proposal.canApply,"Conflicting destinations must not depend on control order")
    }
    func testCurvedAndExtrudedWallControlsAreRejected() throws {
        let p=GoldenExchangeTests.project(),export=exported(p)
        for (code,value) in [(42,"1"),(210,"1"),(230,"-1")] {
            let text=try edit(export.text,id:p.rooms[0].walls[0].id,code:code,value:value)
            XCTAssertFalse(SurveyDXFReconciliationEngine().preview(drawing:EditableDXFReader().read(text),baseline:export.manifest,current:p).canApply,"Unsupported group \(code)")
        }
    }
    func testChangedBlockBasePointIsRejected() throws {
        let p=GoldenExchangeTests.project(),export=exported(p)
        var doc=try SurveyDXFDocument(export.text)
        let i=try XCTUnwrap(doc.indices(in:"BLOCKS").first{doc.records[$0].type=="BLOCK" && doc.records[$0].string(2)?.hasPrefix("PO12_")==true})
        doc.records[i].set(10,"1000")
        XCTAssertFalse(SurveyDXFReconciliationEngine().preview(drawing:EditableDXFReader().read(doc.text),baseline:export.manifest,current:p).canApply)
    }

}
