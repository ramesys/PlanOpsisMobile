import Foundation

/// v12.4 door, window, opening and room schedules, with the marks (D01, W01, O01) shown on drawings.
///
/// Marks follow the physical drawing: a door that two adjacent rooms both captured is one door with one
/// mark. Numbering is deterministic: rooms in project order, then walls in room order, then position
/// along the wall, so marks only change when the model changes.
public struct ProjectSchedules: Sendable {
    public struct DoorRow: Hashable, Sendable, Identifiable {
        public var mark: String
        public var openingIDs: [UUID]
        public var rooms: [String]
        public var width: Double
        public var height: Double
        public var operation: String
        public var swing: String
        public var wallThickness: Double
        public var id: String { mark }
    }

    public struct WindowRow: Hashable, Sendable, Identifiable {
        public var mark: String
        public var openingIDs: [UUID]
        public var rooms: [String]
        public var width: Double
        public var height: Double
        public var sill: Double
        public var operation: String
        public var wallThickness: Double
        public var head: Double { sill + height }
        public var area: Double { width * height }
        public var id: String { mark }
    }

    public struct OpeningRow: Hashable, Sendable, Identifiable {
        public var mark: String
        public var openingIDs: [UUID]
        public var rooms: [String]
        public var width: Double
        public var height: Double
        public var sill: Double
        public var wallThickness: Double
        public var id: String { mark }
    }

    public struct RoomRow: Hashable, Sendable, Identifiable {
        public var roomID: UUID
        public var number: String
        public var name: String
        /// Clear floor area inside the wall faces, mm².
        public var area: Double
        /// Inner face perimeter, mm.
        public var perimeter: Double
        /// Typical (median) wall height, mm.
        public var height: Double
        public var doorCount: Int
        public var windowCount: Int
        /// Window area, mm².
        public var glazingArea: Double
        public var id: UUID { roomID }
        /// Window area as a share of floor area.
        public var glazingRatio: Double { area > 0 ? glazingArea / area : 0 }
    }

    public var doors: [DoorRow] = []
    public var windows: [WindowRow] = []
    public var openings: [OpeningRow] = []
    public var rooms: [RoomRow] = []
    /// Semantic opening ID → mark.
    public var marks: [UUID: String] = [:]

    public init(project: PlanOpsisProject, semanticGeometry: ArchitecturalGeometrySnapshot? = nil, physicalGeometry: DisplayGeometrySnapshot? = nil) {
        let semantic = semanticGeometry ?? ParametricGeometryEngine().generate(from: project)
        let physical = physicalGeometry ?? PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)
        let roomNames = Self.roomNames(project)

        // Where each semantic opening sits, for ordering and lookups.
        struct Placement { var roomIndex: Int; var wallIndex: Int; var offset: Double; var opening: PlanOpsisOpening; var wall: PlanOpsisWall; var roomID: UUID }
        var placements: [UUID: Placement] = [:]
        for (roomIndex, room) in project.rooms.enumerated() {
            for opening in room.openings {
                guard let wallIndex = room.walls.firstIndex(where: { $0.id == opening.parameters.hostWallID }) else { continue }
                placements[opening.id] = Placement(roomIndex: roomIndex, wallIndex: wallIndex, offset: opening.parameters.offsetAlongWall, opening: opening, wall: room.walls[wallIndex], roomID: room.id)
            }
        }

        // One schedule entry per drawn opening; semantic openings not drawn (open rooms) stand alone.
        var groups: [[UUID]] = physical.hostedOpenings.map { $0.sourceOpeningIDs.filter { placements[$0] != nil } }.filter { !$0.isEmpty }
        let grouped = Set(groups.flatMap { $0 })
        groups += placements.keys.filter { !grouped.contains($0) }.map { [$0] }
        func key(_ group: [UUID]) -> (Int, Int, Double, String) {
            let first = group.compactMap { placements[$0] }.min { ($0.roomIndex, $0.wallIndex, $0.offset) < ($1.roomIndex, $1.wallIndex, $1.offset) }!
            return (first.roomIndex, first.wallIndex, first.offset, group.map(\.uuidString).sorted().first ?? "")
        }
        groups = groups.map { $0.sorted { $0.uuidString < $1.uuidString } }.sorted { key($0) < key($1) }

        var counters: [PlanOpsisOpening.Kind: Int] = [:]
        for group in groups {
            let lead = placements[group[0]]!
            let kind = lead.opening.kind
            counters[kind, default: 0] += 1
            let prefix: String
            switch kind {
            case .door: prefix = "D"
            case .window: prefix = "W"
            case .opening: prefix = "O"
            }
            let mark = prefix + String(format: "%02d", counters[kind]!)
            for id in group { marks[id] = mark }
            var seenRooms = Set<UUID>()
            let rooms = group.compactMap { placements[$0] }.filter { seenRooms.insert($0.roomID).inserted }.map { roomNames[$0.roomID] ?? "" }
            let p = lead.opening.parameters
            let thickness = group.compactMap { placements[$0]?.wall.thickness }.max() ?? lead.wall.thickness
            switch lead.opening {
            case let .door(door):
                doors.append(DoorRow(mark: mark, openingIDs: group, rooms: rooms, width: p.width, height: p.height,
                                     operation: Self.title(door.operation.rawValue), swing: Self.title(door.swing.rawValue), wallThickness: thickness))
            case let .window(window):
                windows.append(WindowRow(mark: mark, openingIDs: group, rooms: rooms, width: p.width, height: p.height, sill: p.sillHeight,
                                         operation: Self.title(window.operation.rawValue), wallThickness: thickness))
            case .opening:
                openings.append(OpeningRow(mark: mark, openingIDs: group, rooms: rooms, width: p.width, height: p.height, sill: p.sillHeight, wallThickness: thickness))
            }
        }

        for (index, room) in project.rooms.enumerated() {
            let centerline = ArchitecturalRoomEnvelope.polygon(for: room, topology: semantic.topology)
            let faces = RoomFaceBoundary(room: room, centerline: centerline)
            let inner = faces?.inner ?? []
            let heights = room.walls.map(\.height).sorted()
            let height = heights.isEmpty ? 0 : heights[heights.count / 2]
            let windowsHere = room.openings.filter { $0.kind == .window }
            rooms.append(RoomRow(
                roomID: room.id,
                number: String(index + 1),
                name: roomNames[room.id] ?? "Room \(index + 1)",
                area: faces?.netArea ?? 0,
                perimeter: inner.count >= 3 ? zip(inner, inner.dropFirst() + [inner[0]]).reduce(0) { $0 + ($1.1 - $1.0).length } : 0,
                height: height,
                doorCount: room.openings.filter { $0.kind == .door }.count,
                windowCount: windowsHere.count,
                glazingArea: windowsHere.reduce(0) { $0 + $1.parameters.width * $1.parameters.height }
            ))
        }
    }

    public var isEmpty: Bool { doors.isEmpty && windows.isEmpty && openings.isEmpty && rooms.isEmpty }

    /// Room display names: the survey name, else "Room n".
    public static func roomNames(_ project: PlanOpsisProject) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for (index, room) in project.rooms.enumerated() {
            let surveyName = project.survey.roomNames[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            names[room.id] = surveyName.isEmpty ? "Room \(index + 1)" : surveyName
        }
        return names
    }

    /// "singleHinged" → "Single hinged".
    static func title(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(character)
        }
        words.append(current)
        let sentence = words.map { $0.lowercased() }.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    // MARK: Tables

    /// A schedule as a titled table of strings, used by the sheets, the app and CSV export.
    public struct Table: Hashable, Sendable {
        public var title: String
        public var columns: [String]
        public var rows: [[String]]
        /// Columns holding numbers (right-aligned on sheets).
        public var numericColumns: Set<Int>
    }

    public var tables: [Table] {
        var result: [Table] = []
        func mm(_ v: Double) -> String { String(Int(v.rounded())) }
        func m2(_ v: Double) -> String { String(format: "%.2f", v / 1_000_000) }
        if !rooms.isEmpty {
            result.append(Table(
                title: "Room schedule",
                columns: ["No.", "Name", "Area m²", "Perimeter m", "Height mm", "Doors", "Windows", "Glazing m²", "Glazing %"],
                rows: rooms.map { [$0.number, $0.name, m2($0.area), String(format: "%.2f", $0.perimeter / 1_000), mm($0.height), String($0.doorCount), String($0.windowCount), m2($0.glazingArea), String(format: "%.0f", $0.glazingRatio * 100)] },
                numericColumns: [2, 3, 4, 5, 6, 7, 8]
            ))
        }
        if !doors.isEmpty {
            result.append(Table(
                title: "Door schedule",
                columns: ["Mark", "Room", "Width mm", "Height mm", "Wall mm", "Operation", "Swing"],
                rows: doors.map { [$0.mark, $0.rooms.joined(separator: " / "), mm($0.width), mm($0.height), mm($0.wallThickness), $0.operation, $0.swing] },
                numericColumns: [2, 3, 4]
            ))
        }
        if !windows.isEmpty {
            result.append(Table(
                title: "Window schedule",
                columns: ["Mark", "Room", "Width mm", "Height mm", "Sill mm", "Head mm", "Area m²", "Operation"],
                rows: windows.map { [$0.mark, $0.rooms.joined(separator: " / "), mm($0.width), mm($0.height), mm($0.sill), mm($0.head), m2($0.area), $0.operation] },
                numericColumns: [2, 3, 4, 5, 6]
            ))
        }
        if !openings.isEmpty {
            result.append(Table(
                title: "Opening schedule",
                columns: ["Mark", "Room", "Width mm", "Height mm", "Sill mm", "Wall mm"],
                rows: openings.map { [$0.mark, $0.rooms.joined(separator: " / "), mm($0.width), mm($0.height), mm($0.sill), mm($0.wallThickness)] },
                numericColumns: [2, 3, 4, 5]
            ))
        }
        return result
    }

    /// All schedules in one CSV (RFC 4180), tables separated by a blank line and headed by their title.
    public func csv() -> String { Self.csv(tables) }

    /// Any tables as one CSV (RFC 4180), separated by a blank line and headed by their title.
    public static func csv(_ tables: [Table]) -> String {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : value
        }
        var lines: [String] = []
        for table in tables {
            if !lines.isEmpty { lines.append("") }
            lines.append(field(table.title))
            lines.append(table.columns.map(field).joined(separator: ","))
            lines += table.rows.map { $0.map(field).joined(separator: ",") }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
