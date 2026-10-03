import Foundation

/// v12.5 quantity takeoff: room areas and lengths, wall faces net of openings, opening lintels and
/// reveals, wall lengths and volumes, and finish totals.
///
/// All values are millimetres, mm² and mm³ (tables convert to m, m², m³). Walls are measured on the
/// room-side face, corner to corner; walls are flat-topped and ceilings flat at the room height.
public struct ProjectQuantities: Sendable {
    public struct RoomRow: Hashable, Sendable, Identifiable {
        public var roomID: UUID
        public var number: String
        public var name: String
        public var floorArea: Double
        public var ceilingArea: Double
        public var perimeter: Double
        public var height: Double
        public var grossWallArea: Double
        public var openingArea: Double
        /// Perimeter less door and floor-level opening widths.
        public var skirtingLength: Double
        public var netWallArea: Double { max(0, grossWallArea - openingArea) }
        public var volume: Double { floorArea * height }
        public var id: UUID { roomID }
    }

    public struct OpeningRow: Hashable, Sendable, Identifiable {
        public var mark: String
        public var openingID: UUID
        public var width: Double
        public var height: Double
        /// Lintel with 150 mm bearing each side.
        public var lintelLength: Double
        /// Side, head (and sill for windows) reveal surfaces, through the wall thickness.
        public var revealArea: Double
        public var area: Double { width * height }
        public var id: UUID { openingID }
    }

    public struct WallTypeRow: Hashable, Sendable, Identifiable {
        public var thickness: Double
        public var length: Double
        public var netSideArea: Double
        public var netVolume: Double
        public var id: Double { thickness }
    }

    public struct WallRow: Hashable, Sendable, Identifiable {
        public var wallID: UUID
        public var length: Double
        public var thickness: Double
        public var height: Double
        public var openingArea: Double
        public var openingVolume: Double
        public var grossSideArea: Double { length * height }
        public var netSideArea: Double { max(0, grossSideArea - openingArea) }
        public var grossVolume: Double { grossSideArea * thickness }
        public var netVolume: Double { max(0, grossVolume - openingVolume) }
        public var id: UUID { wallID }
    }

    public struct FinishTotal: Hashable, Sendable, Identifiable {
        public var finish: String
        public var floorArea: Double = 0
        public var wallArea: Double = 0
        public var ceilingArea: Double = 0
        public var skirtingLength: Double = 0
        public var id: String { finish }
    }

    public static let lintelBearing = 150.0

    public var rooms: [RoomRow] = []
    public var openings: [OpeningRow] = []
    public var walls: [WallRow] = []
    public var finishes: [UUID: RoomFinishes] = [:]

    public init(project: PlanOpsisProject, schedules: ProjectSchedules) {
        let measurement = SurveyMeasurementEngine()
        finishes = project.documentation?.finishes ?? [:]
        var seenOpenings = Set<String>()
        let ordering = PlanOrdering(project: project)
        for room in ordering.rooms {
            guard let schedule = schedules.rooms.first(where: { $0.roomID == room.id }) else { continue }
            var gross = 0.0, openingArea = 0.0, doorWidths = 0.0
            for wall in room.walls where wall.length > 1 {
                if let side = measurement.roomSide(ofWall: wall.id, in: room),
                   let face = try? measurement.faceSegment(wallID: wall.id, side: side, in: room) {
                    gross += (face.1 - face.0).length * wall.height
                }
            }
            for opening in room.openings {
                let p = opening.parameters
                let host = room.walls.first { $0.id == p.hostWallID }
                let clearHeight = max(0, min(p.height, (host?.height ?? p.height) - p.sillHeight))
                openingArea += p.width * clearHeight
                if opening.kind == .door || (opening.kind == .opening && p.sillHeight < 50) { doorWidths += p.width }
                // Openings shared by two rooms are listed once.
                guard let mark = schedules.marks[opening.id], seenOpenings.insert(mark).inserted, let host else { continue }
                let reveal = opening.kind == .door ? (2 * p.height + p.width) : 2 * (p.height + p.width)
                openings.append(OpeningRow(mark: mark, openingID: opening.id, width: p.width, height: p.height,
                                           lintelLength: p.width + 2 * Self.lintelBearing, revealArea: reveal * host.thickness))
            }
            rooms.append(RoomRow(
                roomID: room.id, number: schedule.number, name: schedule.name,
                floorArea: schedule.area, ceilingArea: schedule.area, perimeter: schedule.perimeter, height: schedule.height,
                grossWallArea: gross, openingArea: openingArea, skirtingLength: max(0, schedule.perimeter - doorWidths)
            ))
        }
        openings.sort { $0.mark < $1.mark }

        // Each wall once, centreline length, openings cut through its full thickness.
        for room in ordering.rooms {
            for wall in ordering.orderedWalls(of: room) where wall.length > 1 {
                let hosted = room.openings.filter { $0.parameters.hostWallID == wall.id }
                let area = hosted.reduce(0.0) { sum, o in sum + o.parameters.width * max(0, min(o.parameters.height, wall.height - o.parameters.sillHeight)) }
                walls.append(WallRow(wallID: wall.id, length: wall.length, thickness: wall.thickness, height: wall.height, openingArea: area, openingVolume: area * wall.thickness))
            }
        }
    }

    /// Wall totals by thickness, thickest first.
    public var wallTypes: [WallTypeRow] {
        var byThickness: [Double: WallTypeRow] = [:]
        for wall in walls {
            let key = (wall.thickness).rounded()
            var row = byThickness[key] ?? WallTypeRow(thickness: key, length: 0, netSideArea: 0, netVolume: 0)
            row.length += wall.length
            row.netSideArea += wall.netSideArea
            row.netVolume += wall.netVolume
            byThickness[key] = row
        }
        return byThickness.values.sorted { $0.thickness > $1.thickness }
    }

    /// Areas and lengths summed per finish name across rooms.
    public var finishTotals: [FinishTotal] {
        var totals: [String: FinishTotal] = [:]
        func add(_ name: String, _ update: (inout FinishTotal) -> Void) {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            var total = totals[key] ?? FinishTotal(finish: key)
            update(&total)
            totals[key] = total
        }
        for room in rooms {
            guard let f = finishes[room.roomID] else { continue }
            add(f.floor) { $0.floorArea += room.floorArea }
            add(f.walls) { $0.wallArea += room.netWallArea }
            add(f.ceiling) { $0.ceilingArea += room.ceilingArea }
            add(f.skirting) { $0.skirtingLength += room.skirtingLength }
        }
        return totals.values.sorted { $0.finish.localizedCaseInsensitiveCompare($1.finish) == .orderedAscending }
    }

    public var totalFloorArea: Double { rooms.reduce(0) { $0 + $1.floorArea } }

    // MARK: Tables

    public var tables: [ProjectSchedules.Table] {
        func m(_ v: Double) -> String { String(format: "%.2f", v / 1_000) }
        func m2(_ v: Double) -> String { String(format: "%.2f", v / 1_000_000) }
        func m3(_ v: Double) -> String { String(format: "%.2f", v / 1_000_000_000) }
        var result: [ProjectSchedules.Table] = []
        if !rooms.isEmpty {
            var rows = rooms.map { [$0.number, $0.name, m2($0.floorArea), m2($0.ceilingArea), m($0.perimeter), m2($0.grossWallArea), m2($0.openingArea), m2($0.netWallArea), m($0.skirtingLength), m3($0.volume)] }
            if rooms.count > 1 {
                func sum(_ key: KeyPath<RoomRow, Double>) -> Double { rooms.reduce(0) { $0 + $1[keyPath: key] } }
                rows.append(["", "Total", m2(sum(\.floorArea)), m2(sum(\.ceilingArea)), m(sum(\.perimeter)), m2(sum(\.grossWallArea)), m2(sum(\.openingArea)), m2(sum(\.netWallArea)), m(sum(\.skirtingLength)), m3(sum(\.volume))])
            }
            result.append(.init(title: "Room quantities",
                                columns: ["No.", "Name", "Floor m²", "Ceiling m²", "Perimeter m", "Walls gross m²", "Openings m²", "Walls net m²", "Skirting m", "Volume m³"],
                                rows: rows, numericColumns: Set(2...9)))
        }
        if finishes.values.contains(where: { !$0.isEmpty }) {
            result.append(.init(title: "Finishes",
                                columns: ["No.", "Room", "Floor", "Walls", "Ceiling", "Skirting"],
                                rows: rooms.map { room in
                                    let f = finishes[room.roomID] ?? RoomFinishes()
                                    return [room.number, room.name, f.floor, f.walls, f.ceiling, f.skirting]
                                },
                                numericColumns: []))
            result.append(.init(title: "Finish totals",
                                columns: ["Finish", "Floor m²", "Walls m²", "Ceiling m²", "Skirting m"],
                                rows: finishTotals.map { t in
                                    [t.finish, t.floorArea > 0 ? m2(t.floorArea) : "", t.wallArea > 0 ? m2(t.wallArea) : "",
                                     t.ceilingArea > 0 ? m2(t.ceilingArea) : "", t.skirtingLength > 0 ? m(t.skirtingLength) : ""]
                                },
                                numericColumns: [1, 2, 3, 4]))
        }
        if !openings.isEmpty {
            result.append(.init(title: "Opening quantities",
                                columns: ["Mark", "Width mm", "Height mm", "Area m²", "Lintel mm", "Reveals m²"],
                                rows: openings.map { [$0.mark, String(Int($0.width.rounded())), String(Int($0.height.rounded())), m2($0.area), String(Int($0.lintelLength.rounded())), m2($0.revealArea)] },
                                numericColumns: [1, 2, 3, 4, 5]))
        }
        if !walls.isEmpty {
            result.append(.init(title: "Wall quantities",
                                columns: ["Thickness mm", "Length m", "Net side area m²", "Net volume m³"],
                                rows: wallTypes.map { [String(Int($0.thickness)), m($0.length), m2($0.netSideArea), m3($0.netVolume)] },
                                numericColumns: [0, 1, 2, 3]))
        }
        return result
    }
}
