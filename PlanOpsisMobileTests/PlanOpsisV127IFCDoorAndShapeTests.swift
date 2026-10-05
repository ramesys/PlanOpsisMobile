import XCTest
@testable import PlanOpsisCore

/// v12.7 IFC fidelity: door hand, side and type both ways, and walls that are not straight boxes.
final class PlanOpsisV127IFCDoorAndShapeTests: XCTestCase {
    /// A 6 × 4 m room (axes counter-clockwise from the south-west) with one door per wall and a
    /// fifth on the south wall, each with its own hand, side and type.
    static func doorProject() -> (PlanOpsisProject, [UUID: PlanOpsisDoor]) {
        let corners = [Point2D(x: 0, y: 0), Point2D(x: 6_000, y: 0), Point2D(x: 6_000, y: 4_000), Point2D(x: 0, y: 4_000)]
        let walls = corners.indices.map { i -> PlanOpsisWall in
            let a = corners[i], v = corners[(i + 1) % 4] - a
            return PlanOpsisWall(start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: 2_700, thickness: 200)
        }
        func door(_ wall: Int, _ offset: Double, _ swing: PlanOpsisDoor.Swing, _ operation: PlanOpsisDoor.Operation, width: Double = 900) -> PlanOpsisDoor {
            PlanOpsisDoor(parameters: HostedOpeningParameters(hostWallID: walls[wall].id, offsetAlongWall: offset, width: width, height: 2_100, sillHeight: 0),
                          swing: swing, operation: operation)
        }
        let doors = [
            door(0, 1_500, .leftIn, .singleHinged), door(0, 4_200, .rightIn, .singleHinged),
            door(1, 2_000, .rightOut, .singleHinged), door(2, 3_000, .leftOut, .sliding, width: 1_200),
            door(3, 1_200, .unspecified, .pocket), door(3, 3_000, .rightIn, .doubleHinged, width: 1_400),
        ]
        let room = PlanOpsisRoom(walls: walls, openings: doors.map { .door($0) })
        return (PlanOpsisProject(rooms: [room]), Dictionary(uniqueKeysWithValues: doors.map { ($0.parameters.id, $0) }))
    }

    func testDoorHandSideAndTypeSurviveAnIFCRoundTrip() throws {
        let (project, doors) = Self.doorProject()
        let text = IFC4ExchangeEngine().export(project: project)
        // Hands are read facing the way the door opens: right-hinged inward is RIGHT, right-hinged
        // outward is LEFT.
        XCTAssertTrue(text.contains(".SINGLE_SWING_LEFT."))
        XCTAssertTrue(text.contains(".SINGLE_SWING_RIGHT."))
        XCTAssertTrue(text.contains(".SLIDING_TO_"))
        XCTAssertTrue(text.contains(".USERDEFINED.,'POCKET'"))

        let model = try IFCModelReader().read(data: Data(text.utf8))
        let split = RoomLoopDetector().split(model.makeRoom())
        let room = try XCTUnwrap(split.rooms.first?.room)
        XCTAssertEqual(split.rooms.count, 1)
        XCTAssertEqual(room.openings.count, doors.count)
        let source = project.rooms[0]
        for (id, original) in doors {
            let host = source.walls.first { $0.id == original.parameters.hostWallID }!
            let centre = host.start + host.direction * original.parameters.offsetAlongWall
            let read = try XCTUnwrap(room.openings.first { opening in
                let wall = room.walls.first { $0.id == opening.parameters.hostWallID }!
                return (wall.start + wall.direction * opening.parameters.offsetAlongWall - centre).length < 2
            }, "door \(id) at \(centre)")
            guard case let .door(door) = read else { return XCTFail("not a door at \(centre)") }
            XCTAssertEqual(door.operation, original.operation, "type at \(centre)")
            if original.operation == .singleHinged {
                // Walls may read back running the other way; hand and side are re-read for the room.
                XCTAssertEqual(door.swing, Self.expectedSwing(original.swing, original: host, read: room.walls.first { $0.id == read.parameters.hostWallID }!),
                               "swing at \(centre)")
            }
        }
    }

    /// The same physical swing described against a wall that may run the other way.
    static func expectedSwing(_ swing: PlanOpsisDoor.Swing, original: PlanOpsisWall, read: PlanOpsisWall) -> PlanOpsisDoor.Swing {
        guard original.direction.dot(read.direction) < 0 else { return swing }
        switch swing {
        case .leftIn: return .rightIn
        case .rightIn: return .leftIn
        case .leftOut: return .rightOut
        case .rightOut: return .leftOut
        case .unspecified: return .unspecified
        }
    }

    /// An L-shaped wall (one IFC element, 200 mm thick, legs 5 m east and 3 m north) with a window in
    /// the north leg, in millimetres.
    static let lShaped = """
    ISO-10303-21;
    HEADER;FILE_DESCRIPTION((''),'2;1');FILE_NAME('l.ifc','',(''),(''),'','','');FILE_SCHEMA(('IFC4'));ENDSEC;
    DATA;
    #1=IFCSIUNIT(*,.LENGTHUNIT.,.MILLI.,.METRE.);
    #2=IFCCARTESIANPOINT((0.,0.,0.));
    #3=IFCDIRECTION((0.,0.,1.));
    #5=IFCAXIS2PLACEMENT3D(#2,$,$);
    #6=IFCLOCALPLACEMENT($,#5);
    #10=IFCCARTESIANPOINT((0.,0.));
    #11=IFCCARTESIANPOINT((5000.,0.));
    #12=IFCCARTESIANPOINT((5000.,3000.));
    #13=IFCCARTESIANPOINT((4800.,3000.));
    #14=IFCCARTESIANPOINT((4800.,200.));
    #15=IFCCARTESIANPOINT((0.,200.));
    #16=IFCPOLYLINE((#10,#11,#12,#13,#14,#15,#10));
    #17=IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,#16);
    #18=IFCEXTRUDEDAREASOLID(#17,#5,#3,2600.);
    #19=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#18));
    #20=IFCPRODUCTDEFINITIONSHAPE($,$,(#19));
    #21=IFCWALL('a',$,'L wall',$,$,#6,#20,$,.NOTDEFINED.);
    #30=IFCCARTESIANPOINT((4750.,1000.,900.));
    #31=IFCAXIS2PLACEMENT3D(#30,$,$);
    #32=IFCLOCALPLACEMENT(#6,#31);
    #33=IFCCARTESIANPOINT((150.,600.));
    #34=IFCAXIS2PLACEMENT2D(#33,$);
    #35=IFCRECTANGLEPROFILEDEF(.AREA.,$,#34,300.,1200.);
    #36=IFCEXTRUDEDAREASOLID(#35,#5,#3,1200.);
    #37=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#36));
    #38=IFCPRODUCTDEFINITIONSHAPE($,$,(#37));
    #39=IFCOPENINGELEMENT('o',$,$,$,$,#32,#38,$,.OPENING.);
    #40=IFCRELVOIDSELEMENT('v',$,$,$,#21,#39);
    #41=IFCWINDOW('w',$,$,$,$,#32,$,$,1200.,1200.,.WINDOW.,.SINGLE_PANEL.,$);
    #42=IFCRELFILLSELEMENT('f',$,$,$,#39,#41);
    ENDSEC;
    END-ISO-10303-21;
    """

    func testLShapedWallBecomesTwoJoinedRuns() throws {
        let model = try IFCModelReader().read(data: Data(Self.lShaped.utf8))
        XCTAssertEqual(model.walls.count, 2)
        for wall in model.walls { XCTAssertEqual(wall.thickness, 200, accuracy: 1e-6) }
        let east = try XCTUnwrap(model.walls.first { abs($0.direction.y) < 1e-6 })
        let north = try XCTUnwrap(model.walls.first { abs($0.direction.x) < 1e-6 })
        XCTAssertEqual(east.length, 4_900, accuracy: 1e-6, "from the free end to the corner axis")
        XCTAssertEqual(north.length, 2_900, accuracy: 1e-6)
        let corner = Point2D(x: 4_900, y: 100)
        XCTAssertTrue([east.start, east.end].contains { ($0 - corner).length < 1e-6 })
        XCTAssertTrue([north.start, north.end].contains { ($0 - corner).length < 1e-6 })
        XCTAssertEqual(model.wallHeights, [2_600, 2_600])

        XCTAssertEqual(model.openings.count, 1)
        let window = model.openings[0]
        XCTAssertEqual(model.walls[window.wallIndex], north, "the window sits in the leg it cuts")
        let centre = north.start + north.direction * window.offset
        XCTAssertEqual(centre.y, 1_600, accuracy: 1e-6)
        XCTAssertEqual(model.openingHeights[0].sill, 900, accuracy: 1e-6)
    }

    func testThirdPartyDoorOrientationGivesTheSwing() throws {
        // A door in a wall running east whose +y points south (opening south) and is hinged on its
        // left looking south — the east jamb, the wall's end side.
        let text = """
        ISO-10303-21;
        HEADER;FILE_DESCRIPTION((''),'2;1');FILE_NAME('d.ifc','',(''),(''),'','','');FILE_SCHEMA(('IFC4'));ENDSEC;
        DATA;
        #1=IFCSIUNIT(*,.LENGTHUNIT.,.MILLI.,.METRE.);
        #2=IFCCARTESIANPOINT((0.,0.,0.));
        #3=IFCDIRECTION((0.,0.,1.));
        #4=IFCDIRECTION((-1.,0.,0.));
        #5=IFCAXIS2PLACEMENT3D(#2,$,$);
        #6=IFCLOCALPLACEMENT($,#5);
        #7=IFCCARTESIANPOINT((2500.,0.));
        #8=IFCAXIS2PLACEMENT2D(#7,$);
        #9=IFCRECTANGLEPROFILEDEF(.AREA.,$,#8,5000.,200.);
        #10=IFCEXTRUDEDAREASOLID(#9,#5,#3,2700.);
        #11=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#10));
        #12=IFCPRODUCTDEFINITIONSHAPE($,$,(#11));
        #13=IFCWALL('a',$,$,$,$,#6,#12,$,$);
        #20=IFCCARTESIANPOINT((2000.,0.,0.));
        #21=IFCAXIS2PLACEMENT3D(#20,#3,#4);
        #22=IFCLOCALPLACEMENT(#6,#21);
        #23=IFCCARTESIANPOINT((0.,0.));
        #24=IFCAXIS2PLACEMENT2D(#23,$);
        #25=IFCRECTANGLEPROFILEDEF(.AREA.,$,#24,900.,300.);
        #26=IFCEXTRUDEDAREASOLID(#25,#5,#3,2100.);
        #27=IFCSHAPEREPRESENTATION($,'Body','SweptSolid',(#26));
        #28=IFCPRODUCTDEFINITIONSHAPE($,$,(#27));
        #29=IFCOPENINGELEMENT('o',$,$,$,$,#22,#28,$,.OPENING.);
        #30=IFCRELVOIDSELEMENT('v',$,$,$,#13,#29);
        #31=IFCDOOR('d',$,$,$,$,#22,$,$,2100.,900.,.DOOR.,.SINGLE_SWING_LEFT.,$);
        #32=IFCRELFILLSELEMENT('f',$,$,$,#29,#31);
        ENDSEC;
        END-ISO-10303-21;
        """
        let model = try IFCModelReader().read(data: Data(text.utf8))
        let door = try XCTUnwrap(model.openings.first)
        let wall = model.walls[door.wallIndex]
        let eastward = wall.direction.x > 0
        XCTAssertEqual(door.opensToLeft, !eastward, "south is the right of a wall running east")
        XCTAssertEqual(door.hingeAtEnd, eastward, "the east jamb")
    }
}
