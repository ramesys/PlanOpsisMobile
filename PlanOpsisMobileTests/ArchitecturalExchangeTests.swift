import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class ArchitecturalExchangeTests: XCTestCase {
    private func openWall(doorOperation: PlanOpsisDoor.Operation = .doubleHinged, swing: PlanOpsisDoor.Swing = .leftIn) -> PlanOpsisProject {
        let wall = PlanOpsisWall(start: Point2D(x: -2300, y: -1400), length: 4000, angleRadians: .pi / 6, height: 2800, thickness: 200)
        let door = PlanOpsisOpening.door(PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: wall.id, offsetAlongWall: 2000, width: 1200, height: 2100, sillHeight: 0), swing: swing, operation: doorOperation))
        return PlanOpsisProject(rooms: [PlanOpsisRoom(walls: [wall], openings: [door])])
    }

    func testFallbackDoubleDoorHasTwoQuarterArcsAtLeafWidth() {
        let project = openWall()
        let id = project.rooms[0].openings[0].id
        let arcs = DXFExchangeEngine().preview(for: project).primitives.filter { $0.objectIDs.contains(id) && $0.kind == .arc }
        XCTAssertEqual(arcs.count, 2)
        for arc in arcs { XCTAssertEqual(arc.radius!, 600, accuracy: 1e-8) }
    }

    func testPocketDirectionRespondsToSemanticHanding() {
        let left = openWall(doorOperation: .pocket, swing: .leftIn)
        var right = left
        right.rooms[0].openings[0].doorSwing = .rightIn
        let a = DXFExchangeEngine().preview(for: left).primitives
        let b = DXFExchangeEngine().preview(for: right).primitives
        XCTAssertNotEqual(a, b)
    }

    func testDXFRejectsOrphanAndInvalidComponentDimensions() {
        var project = openWall()
        project.rooms[0].openings[0].parameters.hostWallID = UUID()
        XCTAssertFalse(DXFExchangeEngine().exportValidated(project: project).canWrite)
        project = openWall()
        var component = PlanOpsisComponent(kind: .chair, position: .zero)
        component.height = .infinity
        project.rooms[0].components = [component]
        XCTAssertFalse(DXFExchangeEngine().exportValidated(project: project).canWrite)
    }

    func testIFCRejectsNegativeComponentDimensionsInsteadOfClamping() {
        var project = openWall()
        var component = PlanOpsisComponent(kind: .wc, position: .zero)
        component.width = -380
        project.rooms[0].components = [component]
        XCTAssertFalse(IFC4ExchangeEngine().exportValidated(project: project).canWrite)
    }

    func testPreV12IFCRejectsNonFiniteComponentElevation() {
        var project = openWall()
        var component = PlanOpsisComponent(kind: .beam, position: .zero, elevationMM: 2_400)
        component.elevationMM = .nan
        project.rooms[0].components = [component]
        XCTAssertFalse(IFC4ExchangeEngine().exportValidated(project: project).canWrite)
        XCTAssertFalse(DXFExchangeEngine().exportValidated(project: project).canWrite)
    }
}

extension ArchitecturalExchangeTests {
    func testSymbolsUseWorldDimensionsAcrossAllRequestedRotations() throws {
        let angles = [0.0,30,45,90,135,180,270]
        for kind in PlanOpsisComponent.Kind.allCases {
            for degrees in angles {
                let c = PlanOpsisComponent(kind:kind,position:Point2D(x:-2300,y:-1700),width:800,depth:1200,rotationRadians:degrees * .pi/180)
                let symbol = ArchitecturalSymbolLibrary.component(c)
                XCTAssertFalse(symbol.primitives.isEmpty)
                XCTAssertEqual(symbol,ArchitecturalSymbolLibrary.component(c))
                let bounds = try XCTUnwrap(symbol.bounds)
                let points = symbol.primitives.flatMap { $0.geometry.boundsPoints }
                for p in points {
                    XCTAssertTrue(bounds.contains(p,tolerance:1e-8))
                    let delta = p-c.position
                    XCTAssertLessThanOrEqual(abs(delta.dot(c.direction)),400.000001)
                    XCTAssertLessThanOrEqual(abs(delta.dot(c.normal)),600.000001)
                }
                // A true rectangle's rotated envelope has a known analytic extent.
                if kind == .table || kind == .column || kind == .bed || kind == .sofa {
                    XCTAssertEqual(bounds.width,800*abs(cos(c.rotationRadians))+1200*abs(sin(c.rotationRadians)),accuracy:1e-6)
                    XCTAssertEqual(bounds.depth,800*abs(sin(c.rotationRadians))+1200*abs(cos(c.rotationRadians)),accuracy:1e-6)
                }
            }
        }
    }

    func testRecognizableFurnitureAndSanitaryPartsStayParametric() {
        let parts: [PlanOpsisComponent.Kind:[String]] = [.chair:["seat","back:0","back:1"],.table:["outline"],.bed:["pillow:0","blanket"],.sofa:["back","arm-left","arm-right","seat"],.wc:["cistern","bowl","inner-bowl"],.sink:["bowl","drain-x","drain-y"],.column:["outline"]]
        for (kind, names) in parts {
            let symbol = ArchitecturalSymbolLibrary.component(PlanOpsisComponent(kind:kind,position:.zero))
            for name in names { XCTAssertTrue(symbol.primitives.contains { $0.id.hasSuffix(":"+name) },"\(kind): \(name)") }
        }
        let narrowBed = ArchitecturalSymbolLibrary.component(PlanOpsisComponent(kind:.bed,position:.zero,width:900))
        XCTAssertEqual(narrowBed.primitives.filter { $0.id.contains(":pillow:") }.count,1)
    }

    func testQuarterArcBoundsAreTightIncludingWrappedSweeps() throws {
        let g = ArchitecturalSymbol.Geometry.arc(center:Point2D(x:-100,y:-200),radius:500,start:3 * .pi/2,end:0)
        let b = try XCTUnwrap(FloorGeometry.enclosing(g.boundsPoints))
        XCTAssertEqual(b.min.x,-100,accuracy:1e-8); XCTAssertEqual(b.max.x,400,accuracy:1e-8)
        XCTAssertEqual(b.min.y,-700,accuracy:1e-8); XCTAssertEqual(b.max.y,-200,accuracy:1e-8)
    }

    func testAllDoorVariantsAndHandingsAtRotations() {
        for angle in [0.0,30,45,90,135,180,270] {
            for operation in PlanOpsisDoor.Operation.allCases {
                for swing in PlanOpsisDoor.Swing.allCases {
                    let symbol = ArchitecturalSymbolLibrary.opening(id:"test",kind:.door,center:Point2D(x:-1400,y:-3200),width:940,thickness:180,angle:angle * .pi/180,swing:swing,doorOperation:operation)
                    let arcs = symbol.primitives.compactMap { p -> Double? in
                        if case .arc(_,let radius,let start,let end) = p.geometry {
                            XCTAssertEqual(ArchitecturalSymbol.Geometry.positiveAngle(end-start),.pi/2,accuracy:1e-8)
                            return radius
                        }; return nil
                    }
                    let count = swing == .unspecified || operation == .pocket || operation == .sliding ? 0 : (operation == .doubleHinged ? 2 : 1)
                    XCTAssertEqual(arcs.count,count)
                    for r in arcs { XCTAssertEqual(r,operation == .doubleHinged ? 470 : 940,accuracy:1e-8) }
                    XCTAssertNotNil(symbol.bounds)
                }
            }
        }
    }

    func testWindowVariantsHaveOneMullionAndSeparateCasements() {
        for operation in PlanOpsisWindow.Operation.allCases {
            let symbol = ArchitecturalSymbolLibrary.opening(id:"window",kind:.window,center:Point2D(x:-500,y:200),width:1400,thickness:240,angle:.pi/4,windowOperation:operation)
            XCTAssertEqual(symbol.primitives.filter { $0.id.hasPrefix("jamb-") }.count,2)
            XCTAssertEqual(symbol.primitives.filter { $0.id.hasPrefix("window-rail-") }.count,2)
            XCTAssertEqual(symbol.primitives.filter { $0.id.hasPrefix("window-mullion") }.count,operation == .doubleCasement ? 1 : 0)
            XCTAssertEqual(symbol.primitives.filter { $0.id.hasPrefix("window-leaf") }.count,operation == .doubleCasement ? 2 : (operation == .singleCasement ? 1 : 0))
        }
    }

    func testDXFCleanupDoesNotEraseCoincidentDifferentObjects() {
        let id=UUID(), other=UUID()
        let a=DXFPrimitive(id:"a",kind:.line,layer:"A-FURN",points:[.zero,Point2D(x:100,y:0)],ifcClass:.furnishing,objectIDs:[id])
        var b=a; b.id="b"; b.points.reverse()
        var c=a; c.id="c"; c.objectIDs=[other]
        var tiny=a; tiny.id="tiny"; tiny.points=[.zero,.zero]
        let result=DXFDrawingValidator.clean([a,b,c,tiny])
        XCTAssertEqual(result.primitives.map(\.id),["a","c"])
        XCTAssertEqual(result.issues.count,2)
    }

    func testDXFValidationRejectsBadArcPolylineLayerAndNonfinite() {
        let input = [DXFPrimitive(id:"arc",kind:.arc,layer:"A-DOOR",center:.zero,radius:-1,startAngleDegrees:0,endAngleDegrees:90),
                     DXFPrimitive(id:"poly",kind:.polyline,layer:"A-FURN",points:[.zero],closed:true),
                     DXFPrimitive(id:"layer",kind:.line,layer:"UNKNOWN",points:[.zero,Point2D(x:1,y:0)]),
                     DXFPrimitive(id:"nan",kind:.line,layer:"A-FURN",points:[.zero,Point2D(x:.nan,y:0)])]
        let result=DXFDrawingValidator.clean(input)
        XCTAssertTrue(result.primitives.isEmpty)
        XCTAssertEqual(result.issues.filter { $0.severity == .error }.count,4)
    }

    func testBothExportersRejectClippedOpeningsAndDuplicateIdentity() {
        var project=openWall()
        project.rooms[0].openings[0].parameters.width=10000
        XCTAssertFalse(DXFExchangeEngine().exportValidated(project:project).canWrite)
        XCTAssertFalse(IFC4ExchangeEngine().exportValidated(project:project).canWrite)
        project=openWall();project.rooms[0].components=[PlanOpsisComponent(id:project.rooms[0].walls[0].id,kind:.chair,position:.zero)]
        XCTAssertFalse(DXFExchangeEngine().exportValidated(project:project).canWrite)
        XCTAssertFalse(IFC4ExchangeEngine().exportValidated(project:project).canWrite)
    }

    func testOpenRoomDoesNotInventIFCSpaceBody() {
        let result=IFC4ExchangeEngine().exportValidated(project:openWall())
        XCTAssertTrue(result.canWrite)
        XCTAssertTrue(result.issues.contains { $0.message.contains("no proven closed boundary") })
        let space=result.text.components(separatedBy:"\r\n").first { $0.contains("=IFCSPACE(") }!
        XCTAssertTrue(space.contains(",$,$,.ELEMENT.,.SPACE."))
    }
}

extension ArchitecturalExchangeTests {
    func testFreeWallEndsHaveCapsAndTJunctionFacesDoNotCross() {
        let trunk=PlanOpsisWall(start:Point2D(x:-2000,y:0),length:4000,angleRadians:0,height:2800,thickness:200)
        let branch=PlanOpsisWall(start:.zero,length:2000,angleRadians:.pi/2,height:2800,thickness:200)
        let project=PlanOpsisProject(rooms:[PlanOpsisRoom(walls:[trunk,branch])])
        let lines=DXFExchangeEngine().preview(for:project).primitives.filter { $0.ifcClass == .wall }
        XCTAssertTrue(lines.contains { $0.id.contains("cap") })
        // No horizontal trunk face may cross the middle of the T branch at y=100.
        XCTAssertFalse(lines.contains { p in
            guard p.points.count == 2 else { return false }
            return abs(p.points[0].y-100)<1e-6 && abs(p.points[1].y-100)<1e-6 && min(p.points[0].x,p.points[1].x) < -1 && max(p.points[0].x,p.points[1].x) > 1
        })
    }

    func testComponentOnlyDXFRoundTripRetainsUUIDAndParameters() throws {
        let component=PlanOpsisComponent(kind:.sink,position:Point2D(x:-3300,y:1200),rotationRadians:.pi/4)
        let project=PlanOpsisProject(rooms:[PlanOpsisRoom(components:[component])])
        let result=try XCTUnwrap(DXFExchangeEngine().import(DXFExchangeEngine().export(project:project)).project)
        let read=try XCTUnwrap(result.rooms.first?.components.first)
        XCTAssertEqual(read.id,component.id); XCTAssertEqual(read.width,component.width)
        XCTAssertEqual(read.rotationRadians,component.rotationRadians,accuracy:1e-6)
    }
}

extension ArchitecturalExchangeTests {
    func testDXFUnicodeEscapingAndImportKeepTextAwayFromOrigin() throws {
        let label="Δωμάτιο · café 🚪 \\U+1234"
        let encoded=DXFTextCodec.encode(label)
        XCTAssertTrue(encoded.utf8.allSatisfy { $0 < 128 })
        XCTAssertEqual(DXFTextCodec.decode(encoded),label)
        let text="0\nSECTION\n2\nENTITIES\n0\nTEXT\n8\nA-ANNO\n10\n-1200\n20\n2300\n40\n150\n50\n45\n1\n\(encoded)\n0\nENDSEC\n0\nEOF\n"
        let primitive=try XCTUnwrap(DXFExchangeEngine().import(text).preview.primitives.first)
        XCTAssertEqual(primitive.text,label)
        XCTAssertEqual(primitive.points,[Point2D(x:-1200,y:2300)])
        XCTAssertEqual(primitive.rotationDegrees,45)
    }
}

extension ArchitecturalExchangeTests {
    func testOpeningDimensionsUseWorldEndpointsAndNativeWidthAtEveryRotation() throws {
        for degrees in [0.0,30,45,90,135,180,270] {
            var project=openWall()
            project.rooms[0].walls[0].angleRadians=degrees * .pi/180
            let wall=project.rooms[0].walls[0]
            let primitives=DXFExchangeEngine(includeOpeningDimensions:true).preview(for:project).primitives
            let line=try XCTUnwrap(primitives.first { $0.id.hasPrefix("dim-line:opening:") })
            let text=try XCTUnwrap(primitives.first { $0.id.hasPrefix("dim-text:opening:") })
            XCTAssertEqual((line.points[1]-line.points[0]).length,1200,accuracy:1e-6)
            XCTAssertEqual(abs((line.points[1]-line.points[0]).normalized.dot(wall.direction)),1,accuracy:1e-6)
            XCTAssertEqual(text.text,"1200")
            XCTAssertGreaterThan((text.points[0]-line.points[0]).length,100)
            XCTAssertTrue(DXFExchangeEngine(includeOpeningDimensions:true).exportValidated(project:project).canWrite)
        }
    }
}

extension ArchitecturalExchangeTests {
    func testMirroredDoorsReflectActualGeometryInOpenAndClosedRooms() throws {
        for closed in [false, true] {
            for operation in [PlanOpsisDoor.Operation.singleHinged, .doubleHinged, .pocket] {
                for axis in [PlanMirrorAxis.horizontal, .vertical] {
                    let a=PlanOpsisWall(start:.zero,length:4000,angleRadians:0,height:2800,thickness:200)
                    let walls = closed ? [a,
                        PlanOpsisWall(start:Point2D(x:4000,y:0),length:3000,angleRadians:.pi/2,height:2800,thickness:200),
                        PlanOpsisWall(start:Point2D(x:4000,y:3000),length:4000,angleRadians:.pi,height:2800,thickness:200),
                        PlanOpsisWall(start:Point2D(x:0,y:3000),length:3000,angleRadians:3 * .pi/2,height:2800,thickness:200)] : [a]
                    let door=PlanOpsisOpening.door(PlanOpsisDoor(parameters:HostedOpeningParameters(hostWallID:a.id,offsetAlongWall:1000,width:900,height:2100,sillHeight:0),swing:.leftIn,operation:operation))
                    let project=PlanOpsisProject(rooms:[PlanOpsisRoom(walls:walls,openings:[door])])
                    let mirrored=try XCTUnwrap(SemanticObjectEditingEngine().mirrorArchitecturalSelection(entityIDs:Set(walls.map(\.id)),axis:axis,in:project)).project
                    let original=DXFExchangeEngine().preview(for:project).primitives.filter { $0.objectIDs.contains(door.id) }
                    let result=DXFExchangeEngine().preview(for:mirrored).primitives.filter { $0.objectIDs.contains(door.id) }.flatMap(\.boundsPoints)
                    for point in original.flatMap(\.boundsPoints) {
                        let reflected = axis == .vertical ? Point2D(x:4000-point.x,y:point.y) : Point2D(x:point.x,y:(closed ? 3000 : 0)-point.y)
                        XCTAssertTrue(result.contains { ($0-reflected).length < 1e-5 }, "\(closed) \(operation) \(axis): \(reflected)")
                    }
                }
            }
        }
    }

    func testSnappedLJunctionOutlineHasNoDisconnectedEndpoints() {
        for rotation in [0.0, Double.pi/6, Double.pi/4] {
            func rotated(_ p:Point2D) -> Point2D { Point2D(x:p.x*cos(rotation)-p.y*sin(rotation)-2000,y:p.x*sin(rotation)+p.y*cos(rotation)-1000) }
            let a=PlanOpsisWall(start:rotated(.zero),length:4000,angleRadians:rotation,height:2800,thickness:200)
            let b=PlanOpsisWall(start:rotated(Point2D(x:4000,y:50)),length:3000,angleRadians:rotation + .pi/2,height:2800,thickness:200)
            let lines=DXFExchangeEngine().preview(for:PlanOpsisProject(rooms:[PlanOpsisRoom(walls:[a,b])])).primitives.filter { $0.ifcClass == .wall && $0.kind == .line }
            let endpoints=lines.flatMap(\.points)
            XCTAssertGreaterThanOrEqual(lines.count,6)
            for p in endpoints { XCTAssertEqual(endpoints.filter { ($0-p).length < 1e-5 }.count,2,"Disconnected outline at \(p)") }
        }
    }
}

extension ArchitecturalExchangeTests {
    func testRoomFocusExcludesHiddenAnnotationsAndTheirExtents() {
        var project=GoldenExchangeTests.project()
        let wall=PlanOpsisWall(start:Point2D(x:50000,y:40000),length:6000,angleRadians:0,height:2800,thickness:200)
        let hidden=PlanOpsisRoom(walls:[wall])
        project.rooms.append(hidden)
        let engine=DXFExchangeEngine(includeOpeningDimensions:true)
        let all=engine.annotations(for:project)
        let focused=engine.annotations(for:project,focusedRoomID:project.rooms[0].id)
        XCTAssertTrue(all.flatMap(\.boundsPoints).contains { $0.x > 40000 })
        XCTAssertFalse(focused.isEmpty)
        XCTAssertTrue(focused.flatMap(\.boundsPoints).allSatisfy { $0.x < 10000 })
        XCTAssertEqual(focused.filter { $0.id.hasPrefix("dim-text:") }.count,9)
        XCTAssertTrue(engine.annotations(for:project,focusedRoomID:UUID()).isEmpty)
    }
}
