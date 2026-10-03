import XCTest
@testable import PlanOpsisCore

/// v12.7 reading an architect's IFC: walls, doors, windows and named spaces.
final class PlanOpsisV127IFCImportTests: XCTestCase {
    /// A wall in metres, placed at (10, 20) m turned to run north, clipped by a roof plane; a window
    /// in an opening; a space named with an IFC string escape.
    static let handWritten = """
    ISO-10303-21;
    HEADER;
    FILE_DESCRIPTION(('ViewDefinition [ReferenceView]'),'2;1');
    FILE_NAME('model.ifc','2026-10-03T12:00:00',('Architect'),('Office'),'Exporter; v1','Tool','');
    FILE_SCHEMA(('IFC4'));
    ENDSEC;
    DATA;
    #1=IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.);
    #2=IFCCARTESIANPOINT((0.,0.,0.));
    #3=IFCDIRECTION((0.,0.,1.));
    #4=IFCDIRECTION((0.,1.,0.));
    #5=IFCAXIS2PLACEMENT3D(#2,$,$);
    #6=IFCLOCALPLACEMENT($,#5);
    #7=IFCCARTESIANPOINT((10.,20.,0.));
    #8=IFCAXIS2PLACEMENT3D(#7,#3,#4);
    #9=IFCLOCALPLACEMENT(#6,#8);
    #10=IFCCARTESIANPOINT((2.,0.));
    #11=IFCAXIS2PLACEMENT2D(#10,$);
    #12=IFCRECTANGLEPROFILEDEF(.AREA.,$,#11,4.,0.3);
    #13=IFCEXTRUDEDAREASOLID(#12,#5,#3,2.7);
    #14=IFCPLANE(#5);
    #15=IFCBOOLEANCLIPPINGRESULT(.DIFFERENCE.,#13,#14);
    #16=IFCSHAPEREPRESENTATION($,'Body','Clipping',(#15));
    #17=IFCPRODUCTDEFINITIONSHAPE($,$,(#16));
    /* a comment; with a semicolon */
    #18=IFCWALLSTANDARDCASE('2O2Fr$t4X7Zf8NOew3FLOH',$,'Wall; north',$,$,#9,#17,$,.STANDARD.);
    #20=IFCCARTESIANPOINT((1.,-0.2,0.9));
    #21=IFCAXIS2PLACEMENT3D(#20,$,$);
    #22=IFCLOCALPLACEMENT(#9,#21);
    #23=IFCCARTESIANPOINT((0.6,0.35));
    #24=IFCAXIS2PLACEMENT2D(#23,$);
    #25=IFCRECTANGLEPROFILEDEF(.AREA.,$,#24,1.2,0.7);
    #26=IFCEXTRUDEDAREASOLID(#25,#5,#3,1.5);
    #27=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#26));
    #28=IFCPRODUCTDEFINITIONSHAPE($,$,(#27));
    #30=IFCOPENINGELEMENT('o',$,'Opening',$,$,#22,#28,$,.OPENING.);
    #31=IFCRELVOIDSELEMENT('v',$,$,$,#18,#30);
    #40=IFCWINDOW('w',$,'Window',$,$,#22,$,$,1.5,1.2,.WINDOW.,.SINGLE_PANEL.,$);
    #41=IFCRELFILLSELEMENT('f',$,$,$,#30,#40);
    #50=IFCCARTESIANPOINT((7.,20.));
    #51=IFCCARTESIANPOINT((9.8,20.));
    #52=IFCCARTESIANPOINT((9.8,24.));
    #53=IFCCARTESIANPOINT((7.,24.));
    #54=IFCPOLYLINE((#50,#51,#52,#53,#50));
    #55=IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,#54);
    #56=IFCEXTRUDEDAREASOLID(#55,#5,#3,2.5);
    #57=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#56));
    #58=IFCPRODUCTDEFINITIONSHAPE($,$,(#57));
    #59=IFCSPACE('s',$,'101',$,$,#6,#58,'K\\X2\\00FC\\X0\\che',.ELEMENT.,.SPACE.,$);
    ENDSEC;
    END-ISO-10303-21;
    """

    func testHandWrittenModelInMetres() throws {
        let model = try IFCModelReader().read(data: Data(Self.handWritten.utf8))
        XCTAssertEqual(model.walls.count, 1)
        let wall = model.walls[0]
        let ends = [wall.start, wall.end].sorted { $0.y < $1.y }
        XCTAssertEqual(ends[0].x, 10_000, accuracy: 1e-6)
        XCTAssertEqual(ends[0].y, 20_000, accuracy: 1e-6)
        XCTAssertEqual(ends[1].y, 24_000, accuracy: 1e-6)
        XCTAssertEqual(wall.thickness, 300, accuracy: 1e-6)
        XCTAssertEqual(model.wallHeights[0], 2_700, accuracy: 1e-6)

        XCTAssertEqual(model.openings.count, 1)
        let window = model.openings[0]
        XCTAssertEqual(window.kind, .window)
        XCTAssertEqual(window.width, 1_200, accuracy: 1e-6)
        let centre = wall.start + wall.direction * window.offset
        XCTAssertEqual(centre.y, 21_600, accuracy: 1e-6, "1.0 m to 2.2 m along the wall")
        XCTAssertEqual(model.openingHeights[0].sill, 900, accuracy: 1e-6)
        XCTAssertEqual(model.openingHeights[0].height, 1_500, accuracy: 1e-6)

        XCTAssertEqual(model.spaces.map(\.name), ["Küche"])
        XCTAssertEqual(PlanPolygon.area(model.spaces[0].outline), 2_800 * 4_000, accuracy: 1)

        let room = model.makeRoom()
        XCTAssertEqual(room.walls[0].height, 2_700, accuracy: 1e-6)
        XCTAssertEqual(room.openings[0].parameters.sillHeight, 900, accuracy: 1e-6)
        XCTAssertEqual(room.openings[0].parameters.height, 1_500, accuracy: 1e-6)
    }

    func testOwnIFCExportReadsBackAsTheSameWallsAndOpenings() throws {
        var project = GoldenExchangeTests.project()
        project.survey.roomNames[project.rooms[0].id] = "Living"
        let text = IFC4ExchangeEngine().export(project: project)
        let model = try IFCModelReader().read(data: Data(text.utf8))
        let source = project.rooms[0]
        XCTAssertEqual(model.walls.count, source.walls.count)
        for wall in source.walls {
            let match = model.walls.first { read in
                let same = (read.start - wall.start).length < 1 && (read.end - wall.end).length < 1
                let reversed = (read.start - wall.end).length < 1 && (read.end - wall.start).length < 1
                return same || reversed
            }
            XCTAssertNotNil(match, "wall from \(wall.start) to \(wall.end)")
            XCTAssertEqual(match?.thickness ?? 0, wall.thickness, accuracy: 0.5)
        }
        XCTAssertEqual(model.openings.filter { $0.kind == .door }.count, 2)
        XCTAssertEqual(model.openings.filter { $0.kind == .window }.count, 2)
        for opening in source.openings {
            let host = source.walls.first { $0.id == opening.parameters.hostWallID }!
            let centre = host.start + host.direction * opening.parameters.offsetAlongWall
            let read = model.openings.first { o in
                let w = model.walls[o.wallIndex]
                return (w.start + w.direction * o.offset - centre).length < 2
            }
            XCTAssertNotNil(read, "opening at \(centre)")
            XCTAssertEqual(read?.width ?? 0, opening.parameters.width, accuracy: 1)
            XCTAssertEqual(read?.kind, opening.kind)
        }
        XCTAssertEqual(model.spaces.first?.name, "Living", "LongName before the room number")

        let room = model.makeRoom()
        let split = RoomLoopDetector().split(room)
        XCTAssertEqual(split.rooms.count, 1)
        XCTAssertEqual(model.spaceNames(for: split.rooms.map(\.loop)), ["Living"])
        // Door operation types carry over where the file states them.
        XCTAssertEqual(IFCModelReader.doorOperation("SLIDING_TO_LEFT"), .sliding)
        XCTAssertEqual(IFCModelReader.doorOperation("DOUBLE_DOOR_SINGLE_SWING"), .doubleHinged)
        XCTAssertEqual(IFCModelReader.doorOperation("SINGLE_SWING_RIGHT"), .singleHinged)
        XCTAssertNil(IFCModelReader.doorOperation("NOTDEFINED"))
    }

    func testIFCOpensInTheViewerAndTracesLikeADrawing() throws {
        let drawing = try CADViewerDocument.open(data: Data(Self.handWritten.utf8), fileName: "model.ifc")
        XCTAssertTrue(drawing.document.layers.contains { $0.name == "IfcWall" })
        let scene = CADScene(document: drawing.document)
        XCTAssertEqual(scene.texts().map(\.string), ["Küche"])
        let traced = UnderlayWallTracer(scene: scene, layers: UnderlayWallTracer.isWallLayer).traceAll()
        XCTAssertEqual(traced.walls.count, 1)
        XCTAssertEqual(traced.walls[0].thickness, 300, accuracy: 0.5)
        XCTAssertEqual(traced.openings.map(\.kind), [.window])
        XCTAssertThrowsError(try IFCModelReader().read(data: Data("0\nSECTION\n".utf8))) { error in
            XCTAssertEqual(error as? IFCReadError, .notIFC)
        }
    }

    func testPlacementAndScaleMoveTheModelOntoThePlan() throws {
        let model = try IFCModelReader().read(data: Data(Self.handWritten.utf8))
        let placement = UnderlayPlacement(offset: Point2D(x: -10_000, y: -20_000)).rotated(byDegrees: -90, about: .zero)
        let moved = model.transformed(by: placement.transform(unitScale: 1))
        let ends = [moved.walls[0].start, moved.walls[0].end]
        XCTAssertTrue(ends.contains { $0.length < 1e-6 }, "the wall's south end lands on the origin: \(ends)")
        XCTAssertTrue(ends.contains { abs($0.x - 4_000) < 1e-6 && abs($0.y) < 1e-6 }, "and it runs east: \(ends)")
        XCTAssertEqual(moved.walls[0].thickness, 300, accuracy: 1e-9)
    }

    func testMinimumRectangleOfATurnedBox() throws {
        let u = Point2D(x: cos(0.3), y: sin(0.3)), n = Point2D(x: -u.y, y: u.x)
        let corners = [Point2D.zero, u * 5_000, u * 5_000 + n * 250, n * 250].map { $0 + Point2D(x: 100, y: 200) }
        let rect = try XCTUnwrap(IFCModelReader.minimumRectangle(corners + [corners[0] + u * 2_000]))
        // Hull points are snapped to a micrometre, so the fit is within a hair of exact.
        XCTAssertEqual(rect.length, 5_000, accuracy: 0.01)
        XCTAssertEqual(rect.thickness, 250, accuracy: 0.01)
    }
}
