import XCTest
@testable import PlanOpsisCore

/// v12.6 orientation-based numbering: rooms, walls and openings are numbered from the plan, not
/// from capture order, and IFC, schedules and drawings agree.
final class PlanOpsisV126OrderingTests: XCTestCase {
    /// A rectangular room; `clockwise` draws the walls clockwise (N, E, S, W start corners), otherwise
    /// counter-clockwise from the south-west. `rotateBy` changes which wall is stored first.
    static func room(x: Double, y: Double, width: Double, depth: Double, clockwise: Bool = false, rotateBy: Int = 0, id: UUID = UUID()) -> PlanOpsisRoom {
        var corners = [Point2D(x: x, y: y), Point2D(x: x + width, y: y), Point2D(x: x + width, y: y + depth), Point2D(x: x, y: y + depth)]
        if clockwise { corners.reverse() }
        var walls = corners.indices.map { i -> PlanOpsisWall in
            let a = corners[i], v = corners[(i + 1) % 4] - a
            return PlanOpsisWall(start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: 2_700, thickness: 120)
        }
        let shift = rotateBy % walls.count
        walls = Array(walls[shift...] + walls[..<shift])
        return PlanOpsisRoom(id: id, walls: walls)
    }

    /// The wall whose midpoint is nearest a point.
    static func wall(near point: Point2D, in room: PlanOpsisRoom) -> PlanOpsisWall {
        room.walls.min { ($0.center - point).length < ($1.center - point).length }!
    }

    /// Adds a window at an absolute plan position on the wall nearest to it.
    static func addWindow(at point: Point2D, to room: inout PlanOpsisRoom) -> UUID {
        let wall = wall(near: point, in: room)
        let offset = (point - wall.start).dot(wall.direction)
        let id = UUID()
        room.openings.append(.window(PlanOpsisWindow(parameters: HostedOpeningParameters(id: id, hostWallID: wall.id, offsetAlongWall: offset, width: 600, height: 1_200, sillHeight: 900))))
        return id
    }

    func testRoomsAreNumberedNorthWestFirstWhateverTheCaptureOrder() {
        let nw = Self.room(x: 0, y: 4_000, width: 4_000, depth: 3_000)
        let ne = Self.room(x: 4_000, y: 4_200, width: 5_000, depth: 2_600) // slightly offset, same row
        let sw = Self.room(x: 0, y: 0, width: 4_000, depth: 4_000)
        let se = Self.room(x: 4_000, y: 0, width: 5_000, depth: 4_000)
        for captured in [[se, nw, sw, ne], [ne, sw, se, nw], [sw, se, ne, nw]] {
            let ordering = PlanOrdering(project: PlanOpsisProject(rooms: captured))
            XCTAssertEqual(ordering.rooms.map(\.id), [nw.id, ne.id, sw.id, se.id])
            XCTAssertEqual(ordering.roomLabel(se.id), "Room 4")
        }
    }

    func testWallsRunClockwiseFromTheNorthWhateverTheirStoredOrderOrDirection() {
        let north = Point2D(x: 2_000, y: 3_000), east = Point2D(x: 4_000, y: 1_500)
        let south = Point2D(x: 2_000, y: 0), west = Point2D(x: 0, y: 1_500)
        for clockwise in [false, true] {
            for rotation in 0..<4 {
                let room = Self.room(x: 0, y: 0, width: 4_000, depth: 3_000, clockwise: clockwise, rotateBy: rotation)
                let ordering = PlanOrdering(project: PlanOpsisProject(rooms: [room]))
                let expected = [north, east, south, west].map { Self.wall(near: $0, in: room).id }
                XCTAssertEqual(ordering.orderedWalls(of: room).map(\.id), expected, "clockwise \(clockwise), rotation \(rotation)")
                XCTAssertEqual(ordering.wallName(expected[0]), "Wall 01")
                XCTAssertEqual(ordering.wallName(expected[3]), "Wall 04")
            }
        }
    }

    func testWallNumbersContinueAcrossRoomsInRoomOrder() {
        let west = Self.room(x: 0, y: 0, width: 3_000, depth: 3_000)
        let east = Self.room(x: 3_000, y: 0, width: 3_000, depth: 3_000)
        let ordering = PlanOrdering(project: PlanOpsisProject(rooms: [east, west]))
        XCTAssertEqual(ordering.wallName(Self.wall(near: Point2D(x: 1_500, y: 3_000), in: west).id), "Wall 01")
        XCTAssertEqual(ordering.wallName(Self.wall(near: Point2D(x: 4_500, y: 3_000), in: east).id), "Wall 05")
    }

    func testMarksFollowWallsClockwiseAndRunClockwiseAlongEachWall() {
        for clockwise in [false, true] {
            for rotation in [0, 2] {
                var room = Self.room(x: 0, y: 0, width: 6_000, depth: 4_000, clockwise: clockwise, rotateBy: rotation)
                // Added in scrambled order: south, east, north-east part, north-west part.
                let southWindow = Self.addWindow(at: Point2D(x: 3_000, y: 0), to: &room)
                let eastWindow = Self.addWindow(at: Point2D(x: 6_000, y: 2_000), to: &room)
                let northEast = Self.addWindow(at: Point2D(x: 4_500, y: 4_000), to: &room)
                let northWest = Self.addWindow(at: Point2D(x: 1_500, y: 4_000), to: &room)
                let schedules = ProjectSchedules(project: PlanOpsisProject(rooms: [room]))
                XCTAssertEqual([northWest, northEast, eastWindow, southWindow].map { schedules.marks[$0] }, ["W01", "W02", "W03", "W04"],
                               "clockwise \(clockwise), rotation \(rotation)")
            }
        }
    }

    func testScheduleRoomNumbersAndDefaultNamesFollowPlanOrder() {
        let south = Self.room(x: 0, y: 0, width: 4_000, depth: 3_000)
        let north = Self.room(x: 0, y: 3_000, width: 4_000, depth: 3_000)
        let schedules = ProjectSchedules(project: PlanOpsisProject(rooms: [south, north]))
        XCTAssertEqual(schedules.rooms.map(\.roomID), [north.id, south.id])
        XCTAssertEqual(schedules.rooms.map(\.number), ["1", "2"])
        XCTAssertEqual(schedules.rooms.map(\.name), ["Room 1", "Room 2"])
    }

    func testIFCNamesAndWritesElementsInPlanOrder() throws {
        let southRoom = Self.room(x: 0, y: 0, width: 6_000, depth: 4_000, clockwise: true, rotateBy: 3)
        var northRoom = Self.room(x: 0, y: 4_000, width: 6_000, depth: 3_000, rotateBy: 1)
        let second = Self.addWindow(at: Point2D(x: 4_500, y: 7_000), to: &northRoom)
        let first = Self.addWindow(at: Point2D(x: 1_500, y: 7_000), to: &northRoom)
        let project = PlanOpsisProject(rooms: [southRoom, northRoom])
        let result = IFC4ExchangeEngine().exportValidated(project: project)
        XCTAssertTrue(result.canWrite, "\(result.issues)")
        let lines = result.text.split(whereSeparator: \.isNewline).map(String.init)
        func line(of id: UUID) throws -> (index: Int, text: String) {
            let guid = try XCTUnwrap(result.objectGlobalIDs[id])
            let index = try XCTUnwrap(lines.firstIndex { $0.contains("('\(guid)'") && !$0.contains("IFCREL") })
            return (index, lines[index])
        }

        let northSpace = try line(of: northRoom.id), southSpace = try line(of: southRoom.id)
        XCTAssertTrue(northSpace.text.contains("'Room 1'"), northSpace.text)
        XCTAssertTrue(southSpace.text.contains("'Room 2'"), southSpace.text)
        XCTAssertLessThan(northSpace.index, southSpace.index)

        // Walls: north room first, clockwise from its north wall; written in that order.
        let ordering = PlanOrdering(project: project)
        let wallIDs = ordering.rooms.flatMap { ordering.orderedWalls(of: $0) }.map(\.id)
        XCTAssertEqual(wallIDs.first, Self.wall(near: Point2D(x: 3_000, y: 7_000), in: northRoom).id)
        var previous = -1
        for (n, id) in wallIDs.enumerated() {
            let wall = try line(of: id)
            XCTAssertTrue(wall.text.contains("IFCWALL(") && wall.text.contains(String(format: "'Wall %02d'", n + 1)), wall.text)
            XCTAssertGreaterThan(wall.index, previous)
            previous = wall.index
        }

        let w1 = try line(of: first), w2 = try line(of: second)
        XCTAssertTrue(w1.text.contains("IFCWINDOW(") && w1.text.contains("'W01'"), w1.text)
        XCTAssertTrue(w2.text.contains("'W02'"), w2.text)
        XCTAssertLessThan(w1.index, w2.index)
        XCTAssertTrue(result.text.contains("'W01 opening'"))
    }

    func testOrderIsStableAgainstCaptureOrderForTheGoldenProject() {
        var project = GoldenExchangeTests.project()
        let marks = ProjectSchedules(project: project).marks
        let ifcNames = Self.names(in: IFC4ExchangeEngine().export(project: project))
        project.rooms[0].walls.reverse()
        project.rooms[0].openings.reverse()
        XCTAssertEqual(ProjectSchedules(project: project).marks, marks)
        XCTAssertEqual(Self.names(in: IFC4ExchangeEngine().export(project: project)), ifcNames)
    }

    /// Product names in file order.
    static func names(in ifc: String) -> [String] {
        ifc.split(whereSeparator: \.isNewline).map(String.init).compactMap { line -> String? in
            guard ["IFCWALL(", "IFCDOOR(", "IFCWINDOW(", "IFCSPACE(", "IFCOPENINGELEMENT("].contains(where: { line.contains($0) }) else { return nil }
            let parts = line.components(separatedBy: ",")
            return parts.count > 2 ? parts[2] : nil
        }
    }
}
