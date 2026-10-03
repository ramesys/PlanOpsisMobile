import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class PlanOpsisV125QuantityTests: XCTestCase {
    private func texts(_ sheet: DrawingSheet) -> [String] {
        sheet.primitives.compactMap { p -> String? in if case let .text(t, _, _, _, _, _) = p.shape { return t }; return nil }
    }

    func testRoomWallOpeningAndWallQuantities() throws {
        let project = GoldenExchangeTests.project()
        let schedules = ProjectSchedules(project: project)
        let q = ProjectQuantities(project: project, schedules: schedules)
        let room = try XCTUnwrap(q.rooms.first)
        XCTAssertEqual(room.floorArea, 11_760 * 8_260, accuracy: 1)
        XCTAssertEqual(room.ceilingArea, room.floorArea)
        // Perimeter faces 2 × (11.76 + 8.26) m plus the stem wall's room face (2.88 m), all 2.8 m high.
        XCTAssertEqual(room.grossWallArea, (2 * (11_760 + 8_260) + 2_880) * 2_800, accuracy: 1)
        let openings: Double = [900.0 * 2_100, 1_400.0 * 2_100, 1_600.0 * 1_200, 1_800.0 * 1_400].reduce(0, +)
        XCTAssertEqual(room.openingArea, openings, accuracy: 1e-6)
        XCTAssertEqual(room.netWallArea, room.grossWallArea - room.openingArea, accuracy: 1e-6)
        XCTAssertEqual(room.skirtingLength, 2 * (11_760 + 8_260) - 900 - 1_400, accuracy: 1)
        XCTAssertEqual(room.volume, room.floorArea * 2_800, accuracy: 1)

        let door = try XCTUnwrap(q.openings.first { $0.mark == "D01" })
        XCTAssertEqual(door.lintelLength, 1_200)
        XCTAssertEqual(door.revealArea, (2 * 2_100 + 900) * 240, accuracy: 1e-6, "doors have no sill reveal")
        // W01 is the north window: walls are numbered clockwise from the north-west.
        let window = try XCTUnwrap(q.openings.first { $0.mark == "W01" })
        XCTAssertEqual(window.revealArea, 2 * (1_400 + 1_800) * 240, accuracy: 1e-6)
        XCTAssertEqual(q.openings.map(\.mark), ["D01", "D02", "W01", "W02"])

        let types = q.wallTypes
        XCTAssertEqual(types.map(\.thickness), [240, 160])
        XCTAssertEqual(types[0].length, 2 * (12_000 + 8_500), accuracy: 1e-6)
        let stem = types[1]
        XCTAssertEqual(stem.netVolume, (3_000 * 2_800 - 1_400 * 2_100) * 160, accuracy: 1)
        XCTAssertEqual(q.tables.map(\.title), ["Room quantities", "Opening quantities", "Wall quantities"], "no finishes table until finishes are set")
    }

    func testFinishTotalsGroupByMaterial() throws {
        var project = PlanOpsisV121Tests.rectangleRoom(width: 4_000, depth: 3_000, thickness: 100)
        let second = PlanOpsisV121Tests.rectangleRoom(width: 3_000, depth: 3_000, thickness: 100).rooms[0]
        project.rooms.append(second)
        project.documentationSettings.finishes = [
            project.rooms[0].id: RoomFinishes(floor: "Oak", walls: "Paint", ceiling: "Paint"),
            project.rooms[1].id: RoomFinishes(floor: "Tiles", walls: "Paint ", skirting: "Tile"),
        ]
        let q = ProjectQuantities(project: project, schedules: ProjectSchedules(project: project))
        let totals = Dictionary(uniqueKeysWithValues: q.finishTotals.map { ($0.finish, $0) })
        // Rows follow plan order, so look rooms up by ID.
        let rows = project.rooms.map { room in q.rooms.first { $0.roomID == room.id }! }
        XCTAssertEqual(Set(totals.keys), ["Oak", "Paint", "Tiles", "Tile"])
        XCTAssertEqual(totals["Oak"]!.floorArea, 3_900 * 2_900, accuracy: 1)
        XCTAssertEqual(totals["Paint"]!.wallArea, rows[0].netWallArea + rows[1].netWallArea, accuracy: 1e-6, "trimmed names group together")
        XCTAssertEqual(totals["Paint"]!.ceilingArea, rows[0].ceilingArea, accuracy: 1e-6)
        XCTAssertEqual(totals["Tile"]!.skirtingLength, rows[1].skirtingLength, accuracy: 1e-6)
        XCTAssertTrue(q.tables.map(\.title).contains("Finish totals"))
        XCTAssertEqual(q.tables.first?.rows.last?[1], "Total", "several rooms get a total row")
        let csv = ProjectSchedules.csv(q.tables)
        XCTAssertTrue(csv.contains("Finish totals\r\nFinish,Floor m²,Walls m²,Ceiling m²,Skirting m\r\n"))
    }

    func testAreaAndCeilingPlansAndQuantitySheets() throws {
        var project = GoldenExchangeTests.project()
        project.documentationSettings.finishes[project.rooms[0].id] = RoomFinishes(ceiling: "Acoustic tiles")
        let set = DrawingSetComposer().compose(project: project)
        XCTAssertEqual(Array(set.sheets.map(\.title).prefix(4)), ["Floor plan", "Area plan", "Reflected ceiling plan", "Schedules and quantities"])
        let area = try XCTUnwrap(set.sheets.first { $0.title == "Area plan" })
        XCTAssertTrue(area.primitives.contains { $0.fillColor != nil })
        XCTAssertTrue(texts(area).contains("Total net floor area"))
        XCTAssertEqual(texts(area).filter { $0 == "97.14 m²" }.count, 3, "room label, legend line and total")
        let ceiling = try XCTUnwrap(set.sheets.first { $0.title == "Reflected ceiling plan" })
        XCTAssertTrue(texts(ceiling).contains("CH +2.80"))
        XCTAssertTrue(texts(ceiling).contains("Acoustic tiles"))
        XCTAssertFalse(texts(ceiling).contains("D01"), "the ceiling plan carries no door tags")
        XCTAssertTrue(set.tables.map(\.title).contains("Room quantities"))
        for sheet in set.sheets {
            for p in sheet.primitives.flatMap(\.points) {
                XCTAssertTrue(p.x >= -0.01 && p.x <= sheet.width + 0.01 && p.y >= -0.01 && p.y <= sheet.height + 0.01, "\(sheet.title): \(p)")
            }
        }
        project.documentationSettings.includeAreaPlan = false
        project.documentationSettings.includeCeilingPlan = false
        project.documentationSettings.includeQuantities = false
        let lean = DrawingSetComposer().compose(project: project)
        XCTAssertFalse(lean.sheets.contains { $0.title == "Area plan" || $0.title == "Reflected ceiling plan" })
        XCTAssertTrue(lean.sheets.contains { $0.title == "Schedules" })
    }

    func testIFCCarriesBaseQuantities() throws {
        let export = IFC4ExchangeEngine().exportValidated(project: GoldenExchangeTests.project())
        XCTAssertTrue(export.canWrite, export.issues.map(\.message).joined(separator: "; "))
        let text = export.text
        for name in ["Qto_SpaceBaseQuantities", "Qto_WallBaseQuantities", "Qto_DoorBaseQuantities", "Qto_WindowBaseQuantities"] {
            XCTAssertTrue(text.contains("'\(name)'"), name)
        }
        XCTAssertTrue(text.contains("IFCQUANTITYAREA('NetFloorArea',$,$,97.137"), "floor area in m²")
        XCTAssertTrue(text.contains("IFCQUANTITYLENGTH('Length',$,$,12000"), "wall length in mm")
        XCTAssertTrue(text.contains("IFCQUANTITYVOLUME('NetVolume'"))
        XCTAssertEqual(text.components(separatedBy: "'Qto_WallBaseQuantities'").count - 1, 5)
    }

    func testOlderDocumentationSettingsDecodeWithDefaults() throws {
        let json = #"{"paper":"a2","sections":[],"revision":"C"}"#
        let settings = try JSONDecoder().decode(DocumentationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.paper, .a2)
        XCTAssertEqual(settings.revision, "C")
        XCTAssertTrue(settings.includeQuantities && settings.includeAreaPlan && settings.includeCeilingPlan)
        XCTAssertTrue(settings.finishes.isEmpty)
        var changed = settings
        changed.finishes[UUID()] = RoomFinishes(floor: "Oak")
        XCTAssertEqual(try JSONDecoder().decode(DocumentationSettings.self, from: JSONEncoder().encode(changed)), changed)
    }
}
