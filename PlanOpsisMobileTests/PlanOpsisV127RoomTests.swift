import XCTest
@testable import PlanOpsisCore

/// v12.7 rooms from closed wall loops, and door hand, side and type read from drawings.
final class PlanOpsisV127RoomTests: XCTestCase {
    static func wall(_ a: Point2D, _ b: Point2D, thickness: Double = 200, id: UUID = UUID()) -> PlanOpsisWall {
        let v = b - a
        return PlanOpsisWall(id: id, start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: 2_700, thickness: thickness)
    }

    /// 8 × 5 m outline (axes) with a partition at x = 4000 from the south to the north wall.
    static func twoRoomOutline() -> PlanOpsisRoom {
        let corners = [Point2D(x: 0, y: 0), Point2D(x: 8_000, y: 0), Point2D(x: 8_000, y: 5_000), Point2D(x: 0, y: 5_000)]
        var walls = corners.indices.map { wall(corners[$0], corners[($0 + 1) % 4]) }
        walls.append(wall(Point2D(x: 4_000, y: 0), Point2D(x: 4_000, y: 5_000), thickness: 100))
        return PlanOpsisRoom(walls: walls)
    }

    func testTracedDrawingSplitsIntoNamedRoomsWithTheirOpenings() throws {
        var document = PlanOpsisV126UnderlayTests.architectDrawing()
        for (text, at, height) in [("Living", Point2D(x: 2_000, y: 2_500), 300.0), ("18.72 m²", Point2D(x: 2_000, y: 2_000), 400),
                                   ("Bedroom", Point2D(x: 6_000, y: 2_500), 300), ("Outside", Point2D(x: 9_000, y: 2_500), 300)] {
            document.entities.append(CADEntity(type: "TEXT", layer: "IfcAnnotation", geometry: .text(CADText(position: at, height: height, string: text))))
        }
        let scene = CADScene(document: document)
        let traced = UnderlayWallTracer(scene: scene, layers: UnderlayWallTracer.isWallLayer).traceAll()
        let split = RoomLoopDetector().split(traced.makeRoom())
        XCTAssertEqual(split.rooms.count, 2)
        XCTAssertNil(split.unenclosed, "every wall bounds a room")

        let areas = split.rooms.map { PlanPolygon.area($0.loop) }
        for area in areas { XCTAssertEqual(area, 3_900 * 4_800, accuracy: 1) }

        let texts = scene.texts()
        let names = RoomLoopDetector.names(for: split.rooms.map(\.loop), texts: texts)
        let west = try XCTUnwrap(split.rooms.firstIndex { PlanPolygon.contains(Point2D(x: 2_000, y: 2_500), in: $0.loop) })
        let east = 1 - west
        XCTAssertEqual(names[west], "Living", "words beat the larger area label")
        XCTAssertEqual(names[east], "Bedroom")

        let westRoom = split.rooms[west].room, eastRoom = split.rooms[east].room
        XCTAssertEqual(westRoom.openings.map(\.kind), [.door])
        XCTAssertEqual(eastRoom.openings.map(\.kind), [.window])
        XCTAssertEqual(westRoom.walls.filter { abs($0.thickness - 100) < 1 }.count, 1, "the partition bounds both rooms")
        XCTAssertEqual(eastRoom.walls.filter { abs($0.thickness - 100) < 1 }.count, 1)
        XCTAssertNotEqual(westRoom.walls.first { abs($0.thickness - 100) < 1 }?.id, eastRoom.walls.first { abs($0.thickness - 100) < 1 }?.id)

        // The drawn swing opens north into the living room and is hinged on the west jamb.
        let door = try XCTUnwrap(westRoom.openings.first?.doorSwing)
        let host = try XCTUnwrap(westRoom.walls.first { $0.id == westRoom.openings[0].parameters.hostWallID })
        XCTAssertEqual(door, host.direction.x > 0 ? .leftIn : .rightIn)

        // Each room's walls close: the room has a proper clear floor.
        let project = PlanOpsisProject(rooms: split.allRooms)
        let schedules = ProjectSchedules(project: project)
        XCTAssertEqual(schedules.rooms.count, 2)
        for row in schedules.rooms { XCTAssertEqual(row.area, (3_900 - 150) * (4_800 - 200), accuracy: 1) }
        XCTAssertEqual(schedules.doors.count, 1)
        XCTAssertEqual(schedules.windows.count, 1)
    }

    func testSharedDoorOpensIntoOneRoomAndOutOfTheOther() throws {
        var room = Self.twoRoomOutline()
        let partition = room.walls[4]
        // The partition runs north; its left is west. "In" is the left until rooms are found.
        let doorID = UUID()
        room.openings = [.door(PlanOpsisDoor(parameters: HostedOpeningParameters(id: doorID, hostWallID: partition.id, offsetAlongWall: 2_500, width: 900, height: 2_100, sillHeight: 0), swing: .leftIn))]
        let split = RoomLoopDetector().split(room)
        XCTAssertEqual(split.rooms.count, 2)
        let west = try XCTUnwrap(split.rooms.first { PlanPolygon.contains(Point2D(x: 1_000, y: 1_000), in: $0.loop) }?.room)
        let east = try XCTUnwrap(split.rooms.first { PlanPolygon.contains(Point2D(x: 7_000, y: 1_000), in: $0.loop) }?.room)
        XCTAssertEqual(west.openings.first?.doorSwing, .leftIn)
        XCTAssertEqual(east.openings.first?.doorSwing, .leftOut)
        XCTAssertEqual(Set([west.openings[0].id, east.openings[0].id]).count, 2)
        XCTAssertTrue([west.openings[0].id, east.openings[0].id].contains(doorID), "one copy keeps the door's identity")
        XCTAssertEqual(west.openings[0].parameters.offsetAlongWall, 2_500, accuracy: 1e-9)

        // The south wall is cut at the partition; each room has its own half.
        let southPieces = split.allRooms.flatMap(\.walls).filter { abs($0.start.y) < 1 && abs($0.direction.y) < 1e-9 }
        XCTAssertEqual(southPieces.map(\.length).sorted(), [4_000, 4_000])
        XCTAssertEqual(ProjectSchedules(project: PlanOpsisProject(rooms: split.allRooms)).doors.count, 1, "both copies are one door")
    }

    func testStemsFreeWallsAndComponentsGoWhereTheyStand() throws {
        var room = PlanOpsisRoom(walls: [
            Self.wall(Point2D(x: 0, y: 0), Point2D(x: 5_000, y: 0)), Self.wall(Point2D(x: 5_000, y: 0), Point2D(x: 5_000, y: 4_000)),
            Self.wall(Point2D(x: 5_000, y: 4_000), Point2D(x: 0, y: 4_000)), Self.wall(Point2D(x: 0, y: 4_000), Point2D(x: 0, y: 0)),
            Self.wall(Point2D(x: 2_500, y: 0), Point2D(x: 2_500, y: 1_500), thickness: 100), // stem
            Self.wall(Point2D(x: 8_000, y: 0), Point2D(x: 8_000, y: 3_000), thickness: 100), // garden wall
        ])
        room.components = [PlanOpsisComponent(kind: .table, position: Point2D(x: 1_000, y: 2_000)),
                           PlanOpsisComponent(kind: .chair, position: Point2D(x: 9_000, y: 1_000))]
        let split = RoomLoopDetector().split(room)
        XCTAssertEqual(split.rooms.count, 1)
        let inside = split.rooms[0].room
        XCTAssertEqual(inside.id, room.id, "the first room keeps the original identity")
        XCTAssertEqual(inside.walls.count, 5, "the four outline walls (the south one whole, though the stem meets it) and the stem")
        XCTAssertEqual(inside.components.map(\.kind), [.table])
        let leftovers = try XCTUnwrap(split.unenclosed)
        XCTAssertEqual(leftovers.walls.count, 1)
        XCTAssertEqual(leftovers.components.map(\.kind), [.chair])
    }

    func testOpenWallsAreLeftAlone() {
        let room = PlanOpsisRoom(walls: [
            Self.wall(Point2D(x: 0, y: 0), Point2D(x: 4_000, y: 0)), Self.wall(Point2D(x: 4_000, y: 0), Point2D(x: 4_000, y: 3_000)),
            Self.wall(Point2D(x: 4_000, y: 3_000), Point2D(x: 0, y: 3_000)),
        ])
        let split = RoomLoopDetector().split(room)
        XCTAssertTrue(split.rooms.isEmpty)
        XCTAssertEqual(split.unenclosed?.id, room.id)
        XCTAssertEqual(split.unenclosed?.walls.count, 3)
    }

    func testCornersWithinToleranceCloseTheLoop() {
        // Ends 20 mm apart still meet; a 4 m × 3 m room.
        let room = PlanOpsisRoom(walls: [
            Self.wall(Point2D(x: 0, y: 0), Point2D(x: 4_000, y: 0)), Self.wall(Point2D(x: 4_000, y: 20), Point2D(x: 4_000, y: 3_000)),
            Self.wall(Point2D(x: 3_985, y: 3_000), Point2D(x: 0, y: 3_000)), Self.wall(Point2D(x: 0, y: 3_000), Point2D(x: 0, y: 10)),
        ])
        let split = RoomLoopDetector().split(room)
        XCTAssertEqual(split.rooms.count, 1)
        XCTAssertEqual(PlanPolygon.area(split.rooms[0].loop), 12_000_000, accuracy: 120_000)
    }

    // MARK: Door details

    /// Faces of a 200 mm wall along y = 0…200 with a gap from x = 1000 to `1000 + gap`.
    static func gappedWall(gap: Double) -> [UnderlayWallTracer.Segment] {
        let end = 1_000 + gap
        return [
            .init(Point2D(x: 0, y: 0), Point2D(x: 1_000, y: 0)), .init(Point2D(x: end, y: 0), Point2D(x: end + 2_000, y: 0)),
            .init(Point2D(x: 0, y: 200), Point2D(x: 1_000, y: 200)), .init(Point2D(x: end, y: 200), Point2D(x: end + 2_000, y: 200)),
        ]
    }

    static func swing(hinge: Point2D, radius: Double, from start: Double, sweep: Double) -> UnderlayWallTracer.Symbol {
        let middle = start + sweep / 2
        return .init(kind: .doorSwing, bounds: CADRect(points: [hinge, hinge + Point2D(x: radius, y: radius), hinge - Point2D(x: radius, y: radius)])!,
                     center: hinge, radius: radius, arcMiddle: hinge + Point2D(x: cos(middle), y: sin(middle)) * radius)
    }

    func testSwingHandAndSideFromTheArc() throws {
        // Hinged on the east jamb, swinging south (to the right of a wall running east).
        let tracer = UnderlayWallTracer(segments: Self.gappedWall(gap: 900),
                                        symbols: [Self.swing(hinge: Point2D(x: 1_900, y: 0), radius: 900, from: .pi, sweep: .pi / 2)])
        let result = tracer.traceAll()
        let door = try XCTUnwrap(result.openings.first)
        let eastward = result.walls[door.wallIndex].direction.x > 0
        XCTAssertEqual(door.hingeAtEnd, eastward)
        XCTAssertEqual(door.opensToLeft, !eastward)
        XCTAssertEqual(door.swing, eastward ? .rightOut : .leftOut)
        XCTAssertFalse(door.isDouble)
    }

    func testTwoHalfLeavesMakeADoubleDoor() throws {
        let tracer = UnderlayWallTracer(segments: Self.gappedWall(gap: 1_600), symbols: [
            Self.swing(hinge: Point2D(x: 1_000, y: 200), radius: 800, from: 0, sweep: .pi / 2),
            Self.swing(hinge: Point2D(x: 2_600, y: 200), radius: 800, from: .pi / 2, sweep: .pi / 2),
        ])
        let door = try XCTUnwrap(tracer.traceAll().openings.first)
        XCTAssertTrue(door.isDouble)
        XCTAssertEqual(door.width, 1_600, accuracy: 1e-6)
        let room = UnderlayTraceResult(walls: tracer.traceAll().walls, openings: [door]).makeRoom()
        if case let .door(value) = room.openings[0] { XCTAssertEqual(value.operation, .doubleHinged) } else { XCTFail() }
    }

    func testDoorAndWindowBlocksWithoutArcsMarkGaps() throws {
        // A door block of plain lines, and a window block, each inserted in a gap.
        var document = CADDocument(units: .millimetres, layers: [CADLayer(name: "A-WALL")])
        document.blocks["DOOR-STD-900"] = CADBlock(name: "DOOR-STD-900", entities: [
            CADEntity(type: "LINE", geometry: .line(Point2D(x: 0, y: 0), Point2D(x: 0, y: 900))),
            CADEntity(type: "LINE", geometry: .line(Point2D(x: 0, y: 0), Point2D(x: 900, y: 0))),
        ])
        document.blocks["Fenster-1200"] = CADBlock(name: "Fenster-1200", entities: [
            CADEntity(type: "LINE", geometry: .line(Point2D(x: 0, y: 100), Point2D(x: 1_200, y: 100))),
        ])
        func line(_ a: Point2D, _ b: Point2D) { document.entities.append(CADEntity(type: "LINE", layer: "A-WALL", geometry: .line(a, b))) }
        // Faces along y = 0 and 200: door gap 1000…1900, window gap 3000…4200.
        for y in [0.0, 200] {
            line(Point2D(x: 0, y: y), Point2D(x: 1_000, y: y))
            line(Point2D(x: 1_900, y: y), Point2D(x: 3_000, y: y))
            line(Point2D(x: 4_200, y: y), Point2D(x: 6_000, y: y))
        }
        document.entities.append(CADEntity(type: "INSERT", layer: "0", geometry: .insert(CADInsert(blockName: "DOOR-STD-900", position: Point2D(x: 1_000, y: 200)))))
        document.entities.append(CADEntity(type: "INSERT", layer: "0", geometry: .insert(CADInsert(blockName: "Fenster-1200", position: Point2D(x: 3_000, y: 0)))))
        let result = UnderlayWallTracer(scene: CADScene(document: document), layers: UnderlayWallTracer.isWallLayer).traceAll()
        XCTAssertEqual(result.walls.count, 1)
        XCTAssertEqual(result.openings.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.door, .window])
        XCTAssertEqual(result.openings.first { $0.kind == .door }?.swing, .unspecified, "no arc, no invented hand")
    }
}
