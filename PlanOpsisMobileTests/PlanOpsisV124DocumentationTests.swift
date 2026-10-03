import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class PlanOpsisV124DocumentationTests: XCTestCase {
    private func geometry(_ project: PlanOpsisProject) -> (ArchitecturalGeometrySnapshot, DisplayGeometrySnapshot) {
        let semantic = ParametricGeometryEngine().generate(from: project)
        return (semantic, PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic))
    }

    // MARK: Schedules and marks

    func testMarksAreDeterministicAndSchedulesCarryOpeningData() throws {
        var project = GoldenExchangeTests.project()
        project.survey.roomNames[project.rooms[0].id] = "Living, dining"
        let schedules = ProjectSchedules(project: project)
        let room = project.rooms[0]
        func mark(_ n: Int) -> String? { schedules.marks[room.openings[n].id] }
        XCTAssertEqual(mark(0), "D01")
        XCTAssertEqual(mark(2), "W01")
        XCTAssertEqual(mark(3), "W02")
        XCTAssertEqual(mark(1), "D02", "the stem wall comes after the perimeter walls")
        XCTAssertEqual(schedules.doors.map(\.mark), ["D01", "D02"])
        XCTAssertEqual(schedules.doors[1].operation, "Sliding")
        XCTAssertEqual(schedules.doors[0].swing, "Left in")
        XCTAssertEqual(schedules.windows[0].head, 2_100, accuracy: 1e-9)
        XCTAssertEqual(schedules.windows[1].operation, "Double casement")
        let row = try XCTUnwrap(schedules.rooms.first)
        XCTAssertEqual(row.name, "Living, dining")
        XCTAssertEqual(row.area, 11_760 * 8_260, accuracy: 1)
        XCTAssertEqual(row.perimeter, 2 * (11_760 + 8_260), accuracy: 1)
        XCTAssertEqual(row.height, 2_800)
        XCTAssertEqual(row.doorCount, 2)
        XCTAssertEqual(row.glazingArea, 1_600 * 1_200 + 1_800 * 1_400, accuracy: 1e-6)
        XCTAssertEqual(ProjectSchedules(project: project).marks, schedules.marks, "same model, same marks")

        let csv = schedules.csv()
        XCTAssertTrue(csv.hasPrefix("Room schedule\r\nNo.,Name,Area m²"))
        XCTAssertTrue(csv.contains("1,\"Living, dining\",97.14,"), csv)
        XCTAssertTrue(csv.contains("\r\n\r\nDoor schedule\r\nMark,Room,"))
        XCTAssertTrue(csv.contains("D02,\"Living, dining\",1400,2100,160,Sliding,"))
        XCTAssertEqual(schedules.tables.map(\.title), ["Room schedule", "Door schedule", "Window schedule"])
        XCTAssertEqual(ProjectSchedules.title("doubleCasement"), "Double casement")
    }

    func testSharedDoorBetweenTwoRoomsHasOneMark() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let (semantic, physical) = geometry(project)
        let schedules = ProjectSchedules(project: project, semanticGeometry: semantic, physicalGeometry: physical)
        let marked = project.rooms.flatMap(\.openings).compactMap { schedules.marks[$0.id] }
        XCTAssertEqual(marked.count, project.rooms.flatMap(\.openings).count, "every opening has a mark")
        let entries = schedules.doors.count + schedules.windows.count + schedules.openings.count
        XCTAssertEqual(Set(marked).count, entries)
        // Openings captured from both sides are one entry with both rooms.
        for row in schedules.doors where row.openingIDs.count > 1 { XCTAssertEqual(row.rooms.count, 2) }
    }

    func testTagsJoinThePlanAnnotationsAndTheDXF() throws {
        let project = GoldenExchangeTests.project()
        let derivation = ProjectDerivation(project: project, settings: .init(includeTags: true))
        let tags = derivation.annotations.filter { $0.layer == ArchitecturalDraftingConvention.Layer.tags.rawValue }
        XCTAssertEqual(Set(tags.compactMap(\.text)), ["D01", "D02", "W01", "W02"])
        XCTAssertEqual(tags.filter { $0.kind == .arc }.count, 4, "doors are circled (two half arcs each)")
        XCTAssertEqual(tags.filter { $0.kind == .polyline }.count, 2, "windows are boxed")
        // Tags sit inside the room.
        for tag in tags where tag.kind == .text {
            let p = try XCTUnwrap(tag.points.first)
            XCTAssertTrue(p.x > -5_000 && p.x < 7_000 && p.y > -3_000 && p.y < 5_500, "\(p)")
        }
        XCTAssertTrue(ProjectDerivation(project: project).annotations.allSatisfy { $0.layer != ArchitecturalDraftingConvention.Layer.tags.rawValue })
        let dxf = DXFExchangeEngine(includeTags: true).exportValidated(project: project, representation: .semanticObservations)
        XCTAssertTrue(dxf.canWrite, dxf.issues.map(\.message).joined())
        XCTAssertTrue(dxf.text.contains("IfcAnnotation-Tags"))
    }

    func testRoomNamesReplaceRoomNumbersOnTheDrawing() {
        var project = GoldenExchangeTests.project()
        project.survey.roomNames[project.rooms[0].id] = "Kitchen"
        let preview = DXFExchangeEngine().preview(for: project, representation: .semanticObservations)
        XCTAssertTrue(preview.primitives.contains { $0.id.hasPrefix("room-name:") && $0.text == "Kitchen" })
    }

    // MARK: Sections and elevations

    func testSectionCutsWallsAndShowsWallsBeyond() throws {
        let project = GoldenExchangeTests.project()
        let (_, physical) = geometry(project)
        // Horizontal cut through the room at y = 0, looking north (+Y): it crosses the left and right
        // walls and the stem wall; the north wall with its window is beyond.
        let line = SectionLine(label: "A", start: Point2D(x: -6_000, y: 0), end: Point2D(x: 8_000, y: 0), looksLeft: true)
        let view = ArchitecturalSectionEngine().section(line, project: project, physical: physical, scale: 50)
        XCTAssertEqual(view.title, "Section A–A")
        let cuts = view.primitives.filter { $0.fill == 0.25 }
        XCTAssertGreaterThanOrEqual(cuts.count, 3)
        let cutXs = cuts.flatMap(\.points).map(\.x)
        XCTAssertEqual(cutXs.min() ?? 0, 1_000 - 120, accuracy: 1, "left wall cut 240 mm thick, starting 1 m along the line")
        XCTAssertEqual(cutXs.max() ?? 0, 13_000 + 120, accuracy: 1)
        XCTAssertEqual(cuts.flatMap(\.points).map(\.y).max() ?? 0, 2_800, accuracy: 1e-6)
        let beyond = view.primitives.filter { $0.fill == 1 }
        XCTAssertFalse(beyond.isEmpty)
        // The north window (sill 800, head 2200) leaves a gap between wall pieces beyond.
        let tops = Set(beyond.flatMap(\.points).map { ($0.y * 10).rounded() / 10 })
        XCTAssertTrue(tops.contains(800) && tops.contains(2_200), "\(tops.sorted())")
        XCTAssertTrue(view.primitives.contains { if case let .text(t, _, _, _, _, _) = $0.shape { return t == "+2.80" }; return false })
    }

    func testInteriorElevationsOnePerWallWithOpeningDimensions() throws {
        let project = GoldenExchangeTests.project()
        let (_, physical) = geometry(project)
        let schedules = ProjectSchedules(project: project)
        let room = project.rooms[0]
        let views = ArchitecturalSectionEngine().interiorElevations(room: room, roomName: "Room 1", project: project, physical: physical, schedules: schedules, scale: 50)
        XCTAssertEqual(views.count, room.walls.count)
        let south = try XCTUnwrap(views.first)
        XCTAssertTrue(south.title.hasPrefix("Room 1 · Elevation 1 (S)"), south.title)
        let texts = south.primitives.compactMap { p -> String? in if case let .text(t, _, _, _, _, _) = p.shape { return t }; return nil }
        XCTAssertTrue(texts.contains("D01"))
        XCTAssertTrue(texts.contains("2100"), "door head height is dimensioned: \(texts)")
        XCTAssertTrue(texts.contains("11760"), "clear face length is dimensioned: \(texts)")
        XCTAssertTrue(south.primitives.contains { $0.fill == 0.25 }, "the side walls are cut at the corners")
        XCTAssertEqual(ArchitecturalSectionEngine.compass(Point2D(x: 0, y: -1)), "S")
        XCTAssertEqual(ArchitecturalSectionEngine.compass(Point2D(x: 1, y: 1)), "NE")
    }

    // MARK: Sheets

    func testDrawingSetLaysOutPlanSchedulesElevationsAndSections() throws {
        var project = GoldenExchangeTests.project()
        project.name = "Golden flat"
        var settings = DocumentationSettings(paper: .a3, author: "RS", siteAddress: "1 Test Street", revision: "B")
        settings.sections = [SectionLine(label: "A", start: Point2D(x: -6_000, y: 0), end: Point2D(x: 8_000, y: 0))]
        project.documentation = settings
        let set = DrawingSetComposer().compose(project: project, date: Date(timeIntervalSince1970: 0))
        let titles = set.sheets.map(\.title)
        XCTAssertEqual(titles.first, "Floor plan")
        XCTAssertTrue(titles.contains("Schedules"))
        XCTAssertTrue(titles.contains("Interior elevations"))
        XCTAssertTrue(titles.contains("Sections"))
        // 12.24 × 8.74 m fits A3 (400 × ~230 mm drawing area) at 1:50.
        XCTAssertEqual(set.planScale, 50)
        XCTAssertTrue(set.notes.isEmpty, "\(set.notes)")
        for sheet in set.sheets {
            let texts = sheet.primitives.compactMap { p -> String? in if case let .text(t, _, _, _, _, _) = p.shape { return t }; return nil }
            XCTAssertTrue(texts.contains("Golden flat"))
            XCTAssertTrue(texts.contains("\(sheet.number) / \(set.sheets.count)"))
            XCTAssertTrue(texts.contains("1970-01-01"))
            XCTAssertTrue(texts.contains("B"))
            // Everything stays on the paper.
            for p in sheet.primitives.flatMap(\.points) {
                XCTAssertTrue(p.x >= -0.01 && p.x <= sheet.width + 0.01 && p.y >= -0.01 && p.y <= sheet.height + 0.01, "\(sheet.title): \(p)")
            }
        }
        let plan = try XCTUnwrap(set.sheets.first)
        let planTexts = plan.primitives.compactMap { p -> String? in if case let .text(t, _, _, _, _, _) = p.shape { return t }; return nil }
        XCTAssertTrue(planTexts.contains("N"), "north arrow")
        XCTAssertTrue(planTexts.contains("D01"), "door tags")
        XCTAssertTrue(planTexts.contains("A"), "section mark")
        XCTAssertTrue(planTexts.contains("Floor plan"))

        // A smaller sheet forces a smaller scale.
        project.documentation?.paper = .a4
        XCTAssertEqual(DrawingSetComposer().compose(project: project).planScale, 75)
        project.documentation?.planScale = 20
        XCTAssertEqual(DrawingSetComposer().compose(project: project).planScale, 20, "an explicit scale is respected")
    }

    func testScheduleTablesFlowAcrossColumnsAndSheets() {
        let rows = (1...120).map { ["W\($0)", "Room", "1200", "1200"] }
        let table = ProjectSchedules.Table(title: "Window schedule", columns: ["Mark", "Room", "Width mm", "Height mm"], rows: rows, numericColumns: [2, 3])
        let area = DrawingSetComposer.drawingArea(.a4)
        let sheets = DrawingSetComposer.scheduleSheets([table, table], in: area)
        XCTAssertGreaterThan(sheets.count, 1)
        let allTexts = sheets.flatMap { $0 }.compactMap { p -> String? in if case let .text(t, _, _, _, _, _) = p.shape { return t }; return nil }
        XCTAssertEqual(allTexts.filter { $0 == "W120" }.count, 2, "every row is printed once per table")
        XCTAssertTrue(allTexts.contains("Window schedule (continued)"))
        for p in sheets.flatMap({ $0 }).flatMap(\.points) {
            XCTAssertTrue(area.expanded(by: 0.01).contains(p), "\(p)")
        }
    }

    // MARK: Persistence

    func testDocumentationSettingsPersistAndOldProjectsDecode() throws {
        var project = GoldenExchangeTests.project()
        let plain = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("documentation"), "untouched projects encode as before")
        XCTAssertNil(try JSONDecoder().decode(PlanOpsisProject.self, from: plain).documentation)
        project.documentationSettings.company = "Atelier"
        project.documentationSettings.sections.append(SectionLine(label: project.documentationSettings.nextSectionLabel, start: .zero, end: Point2D(x: 1, y: 0)))
        let decoded = try JSONDecoder().decode(PlanOpsisProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.documentationSettings.sections.first?.label, "A")
        XCTAssertEqual(decoded.documentationSettings.nextSectionLabel, "B")
    }

    #if canImport(CoreText)
    func testPDFHasOnePagePerSheet() throws {
        var project = GoldenExchangeTests.project()
        project.documentationSettings.sections = [SectionLine(label: "A", start: Point2D(x: -6_000, y: 0), end: Point2D(x: 8_000, y: 0))]
        let set = DrawingSetComposer().compose(project: project)
        let pdf = try SheetPDFRenderer().render(set)
        XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, set.sheets.count)
        let box = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 420 * 72 / 25.4, accuracy: 0.5)
    }
    #endif
}

/// Writes the golden drawing set as SVG for visual review: `PLANOPSIS_SHEET_SVG_DIR=/path swift test`.
final class PlanOpsisV124SheetPreviewDump: XCTestCase {
    func testDumpSheetsAsSVG() throws {
        guard let dir = ProcessInfo.processInfo.environment["PLANOPSIS_SHEET_SVG_DIR"] else { throw XCTSkip("PLANOPSIS_SHEET_SVG_DIR not set") }
        var project = GoldenExchangeTests.project()
        project.name = "Golden flat"
        project.documentationSettings.sections = [SectionLine(label: "A", start: Point2D(x: -6_000, y: 0), end: Point2D(x: 8_000, y: 0))]
        project.documentationSettings.author = "RS"
        project.documentationSettings.finishes[project.rooms[0].id] = RoomFinishes(floor: "Oak parquet", walls: "Emulsion paint", ceiling: "Emulsion paint", skirting: "Painted MDF")
        let set = DrawingSetComposer().compose(project: project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for sheet in set.sheets {
            var svg = "<svg xmlns='http://www.w3.org/2000/svg' width='\(sheet.width * 4)' height='\(sheet.height * 4)' viewBox='0 0 \(sheet.width) \(sheet.height)'><rect width='100%' height='100%' fill='white'/><g transform='translate(0 \(sheet.height)) scale(1 -1)' stroke-linecap='round'>"
            func pts(_ p: [Point2D]) -> String { p.map { "\($0.x),\($0.y)" }.joined(separator: " ") }
            for p in sheet.primitives {
                let ink = "rgb(\(Int(p.gray * 255)),\(Int(p.gray * 255)),\(Int(p.gray * 255)))"
                let fill = p.fillColor.map { "rgb(\(Int($0.red * 255)),\(Int($0.green * 255)),\(Int($0.blue * 255)))" }
                    ?? p.fill.map { "rgb(\(Int($0 * 255)),\(Int($0 * 255)),\(Int($0 * 255)))" } ?? "none"
                let stroke = p.weight > 0 ? "stroke='\(ink)' stroke-width='\(p.weight)'" : "stroke='none'"
                switch p.shape {
                case let .line(a, b): svg += "<line x1='\(a.x)' y1='\(a.y)' x2='\(b.x)' y2='\(b.y)' \(stroke)/>"
                case let .polyline(q, closed): svg += "<\(closed ? "polygon" : "polyline") points='\(pts(q))' fill='\(fill)' \(stroke)/>"
                case let .polygon(q): svg += "<polygon points='\(pts(q))' fill='\(fill)' \(stroke)/>"
                case let .circle(c, r): svg += "<circle cx='\(c.x)' cy='\(c.y)' r='\(r)' fill='\(fill)' \(stroke)/>"
                case let .arc(c, r, a, b):
                    let p0 = Point2D(x: c.x + r * cos(a), y: c.y + r * sin(a)), p1 = Point2D(x: c.x + r * cos(b), y: c.y + r * sin(b))
                    var sweep = b - a; if sweep < 0 { sweep += 2 * .pi }
                    svg += "<path d='M \(p0.x) \(p0.y) A \(r) \(r) 0 \(sweep > .pi ? 1 : 0) 1 \(p1.x) \(p1.y)' fill='none' \(stroke)/>"
                case let .text(t, at, h, rot, anchor, bold):
                    let a = anchor == .left ? "start" : (anchor == .center ? "middle" : "end")
                    let escaped = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    svg += "<text transform='translate(\(at.x) \(at.y)) rotate(\(rot * 180 / .pi)) scale(1 -1)' font-family='Helvetica' font-size='\(h / 0.72)' font-weight='\(bold ? "bold" : "normal")' text-anchor='\(a)' fill='\(ink)'>\(escaped)</text>"
                }
            }
            svg += "</g></svg>"
            try svg.write(toFile: "\(dir)/sheet-\(sheet.number).svg", atomically: true, encoding: .utf8)
        }
    }
}
