import Foundation

/// v12.7 one value of an IFC (ISO 10303-21) entity's attribute list.
public indirect enum STEPValue: Hashable, Sendable {
    case ref(Int)
    case string(String)
    case number(Double)
    case enumeration(String)
    case list([STEPValue])
    case typed(String, [STEPValue])
    case null

    var ref: Int? { if case let .ref(v) = self { return v }; return nil }
    var number: Double? {
        switch self {
        case let .number(v): return v
        case let .typed(_, values): return values.first?.number
        default: return nil
        }
    }
    var string: String? {
        switch self {
        case let .string(v): return v
        case let .typed(_, values): return values.first?.string
        default: return nil
        }
    }
    var list: [STEPValue] { if case let .list(v) = self { return v }; return [] }
    var enumeration: String? { if case let .enumeration(v) = self { return v }; return nil }
}

public enum IFCReadError: LocalizedError, Equatable {
    case notIFC
    public var errorDescription: String? { "The file is not an IFC (ISO 10303-21) model." }
}

/// v12.7 reads the entities of an IFC STEP file: `#id=TYPE(arguments);`.
public struct STEPFile: Sendable {
    public struct Entity: Sendable {
        public var type: String
        public var arguments: [STEPValue]
    }

    public private(set) var entities: [Int: Entity] = [:]

    public init(data: Data) throws {
        let bytes = Array(data)
        guard let header = String(data: data.prefix(64), encoding: .ascii) ?? String(data: data.prefix(64), encoding: .utf8),
              header.contains("ISO-10303-21") else { throw IFCReadError.notIFC }
        var parser = Parser(bytes: bytes)
        parser.skipToData()
        while let (id, entity) = parser.nextEntity() { entities[id] = entity }
    }

    public subscript(_ id: Int?) -> Entity? { id.flatMap { entities[$0] } }

    struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipToData() {
            let marker = Array("DATA;".utf8)
            while index + marker.count <= bytes.count {
                if bytes[index] == marker[0], Array(bytes[index..<index + marker.count]) == marker { index += marker.count; return }
                if bytes[index] == UInt8(ascii: "'") { skipString() } else { index += 1 }
            }
        }

        mutating func skipString() {
            index += 1
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "'") {
                    if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "'") { index += 2; continue }
                    index += 1
                    return
                }
                index += 1
            }
        }

        mutating func skipSpace() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1; continue }
                if b == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                    index += 2
                    continue
                }
                return
            }
        }

        /// `#12=IFCWALL(...);`; nil at ENDSEC or the end.
        mutating func nextEntity() -> (Int, Entity)? {
            while true {
                skipSpace()
                guard index < bytes.count else { return nil }
                guard bytes[index] == UInt8(ascii: "#") else {
                    // ENDSEC; or junk: stop at ENDSEC, skip anything else to the next ';'.
                    if bytes[index...].starts(with: Array("ENDSEC".utf8)) { return nil }
                    while index < bytes.count, bytes[index] != UInt8(ascii: ";") {
                        if bytes[index] == UInt8(ascii: "'") { skipString() } else { index += 1 }
                    }
                    index += 1
                    continue
                }
                index += 1
                let id = Int(readWord()) ?? -1
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { skipStatement(); continue }
                index += 1
                skipSpace()
                let type = readWord().uppercased()
                skipSpace()
                var arguments: [STEPValue] = []
                if index < bytes.count, bytes[index] == UInt8(ascii: "(") { arguments = readList() }
                skipStatement()
                if id >= 0, !type.isEmpty { return (id, Entity(type: type, arguments: arguments)) }
            }
        }

        mutating func skipStatement() {
            while index < bytes.count, bytes[index] != UInt8(ascii: ";") {
                if bytes[index] == UInt8(ascii: "'") { skipString() } else { index += 1 }
            }
            index += 1
        }

        mutating func readWord() -> String {
            let start = index
            while index < bytes.count {
                let b = bytes[index]
                if (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == UInt8(ascii: "_") || b == UInt8(ascii: ".")
                    || b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { index += 1 } else { break }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        /// After "(": values up to the matching ")".
        mutating func readList() -> [STEPValue] {
            index += 1
            var values: [STEPValue] = []
            while index < bytes.count {
                skipSpace()
                guard index < bytes.count else { break }
                let b = bytes[index]
                if b == UInt8(ascii: ")") { index += 1; break }
                if b == UInt8(ascii: ",") { index += 1; continue }
                values.append(readValue())
            }
            return values
        }

        mutating func readValue() -> STEPValue {
            let b = bytes[index]
            switch b {
            case UInt8(ascii: "#"):
                index += 1
                return .ref(Int(readWord()) ?? -1)
            case UInt8(ascii: "'"):
                let start = index + 1
                skipString()
                let raw = String(decoding: bytes[start..<max(start, index - 1)], as: UTF8.self)
                return .string(Self.decode(raw.replacingOccurrences(of: "''", with: "'")))
            case UInt8(ascii: "("):
                return .list(readList())
            case UInt8(ascii: "$"), UInt8(ascii: "*"):
                index += 1
                return .null
            case UInt8(ascii: "."):
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: ".") { index += 1 }
                let value = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return .enumeration(value)
            default:
                let word = readWord()
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "(") {
                    return .typed(word.uppercased(), readList())
                }
                if let value = Double(word) { return .number(value) }
                if word.isEmpty { index += 1 }
                return .null
            }
        }

        /// IFC string escapes: \X2\00E9\X0\ (UTF-16 hex) and \X\E9 (ISO 8859-1).
        static func decode(_ raw: String) -> String {
            guard raw.contains("\\X") else { return raw }
            var result = ""
            var rest = Substring(raw)
            while let range = rest.range(of: "\\X") {
                result += rest[..<range.lowerBound]
                rest = rest[range.upperBound...]
                if rest.hasPrefix("2\\"), let end = rest.range(of: "\\X0\\") {
                    let hex = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
                    var units: [UInt16] = []
                    var i = hex.startIndex
                    while hex.distance(from: i, to: hex.endIndex) >= 4 {
                        let j = hex.index(i, offsetBy: 4)
                        if let unit = UInt16(hex[i..<j], radix: 16) { units.append(unit) }
                        i = j
                    }
                    result += String(decoding: units, as: UTF16.self)
                    rest = rest[end.upperBound...]
                } else if rest.hasPrefix("\\"), rest.count >= 3, let code = UInt8(rest.dropFirst().prefix(2), radix: 16) {
                    result += String(UnicodeScalar(code))
                    rest = rest.dropFirst(3)
                } else {
                    result += "\\X"
                }
            }
            return result + rest
        }
    }
}

/// v12.7 the walls, doors, windows and rooms of an architect's IFC model, in plan millimetres.
public struct IFCArchitecturalModel: Sendable {
    public struct Space: Sendable {
        public var name: String
        public var outline: [Point2D]
    }

    public var walls: [TracedWall] = []
    public var wallHeights: [Double] = []
    public var openings: [TracedOpening] = []
    public var openingHeights: [(height: Double, sill: Double)] = []
    public var doorOperations: [Int: PlanOpsisDoor.Operation] = [:]
    public var spaces: [Space] = []
    public var name: String?

    /// The model's walls, doors and windows as one room (see `UnderlayTraceResult.makeRoom`), with the
    /// heights the model gives.
    public func makeRoom() -> PlanOpsisRoom {
        var room = UnderlayTraceResult(walls: walls, openings: openings).makeRoom()
        for i in room.walls.indices where wallHeights.indices.contains(i) { room.walls[i].height = wallHeights[i] }
        room.openings = room.openings.enumerated().map { i, opening in
            var o = opening
            var p = o.parameters
            if openingHeights.indices.contains(i) {
                p.height = openingHeights[i].height
                p.sillHeight = openingHeights[i].sill
            }
            o.parameters = p
            if case var .door(door) = o, let operation = doorOperations[i] {
                door.operation = operation
                o = .door(door)
            }
            return o
        }
        return room
    }

    /// The model moved onto the plan (an underlay placement): positions transformed, sizes scaled.
    public func transformed(by t: CADAffine) -> IFCArchitecturalModel {
        let k = t.uniformScale
        var copy = self
        copy.walls = walls.map { TracedWall(start: t.apply($0.start), end: t.apply($0.end), thickness: $0.thickness * k) }
        copy.openings = openings.map { o in
            var moved = o
            moved.offset *= k
            moved.width *= k
            return moved
        }
        copy.spaces = spaces.map { Space(name: $0.name, outline: $0.outline.map(t.apply)) }
        return copy
    }

    /// The model's space name for each loop: the space whose centre lies inside it.
    public func spaceNames(for loops: [[Point2D]]) -> [String?] {
        loops.map { loop in
            spaces.first { space in
                guard !space.name.isEmpty, let c = PlanPolygon.centroid(space.outline) else { return false }
                return PlanPolygon.contains(c, in: loop)
            }?.name
        }
    }

    /// The model drawn as a plan for the viewer and underlay: wall outlines, opening outlines, door
    /// leaves and room outlines with names, on IFC-class layers, in millimetres.
    public func drawing() -> CADDocument {
        var entities: [CADEntity] = []
        func polyline(_ points: [Point2D], layer: String) {
            entities.append(CADEntity(type: "LWPOLYLINE", layer: layer, geometry: .polyline(CADPolyline(vertices: points.map { CADVertex($0) }, closed: true))))
        }
        for wall in walls {
            let n = Point2D(x: -wall.direction.y, y: wall.direction.x) * (wall.thickness / 2)
            // Faces broken at the openings, so the drawing reads like an architect's plan.
            var cuts: [(Double, Double)] = openings.filter { walls.indices.contains($0.wallIndex) && walls[$0.wallIndex] == wall }
                .map { ($0.offset - $0.width / 2, $0.offset + $0.width / 2) }.sorted { $0.0 < $1.0 }
            cuts.append((wall.length, wall.length))
            var cursor = 0.0
            for (a, b) in cuts {
                if a - cursor > 1 {
                    let p = wall.start + wall.direction * cursor, q = wall.start + wall.direction * a
                    polyline([p + n, q + n, q - n, p - n], layer: "IfcWall")
                }
                cursor = max(cursor, b)
            }
        }
        for opening in openings where walls.indices.contains(opening.wallIndex) {
            let wall = walls[opening.wallIndex]
            let n = Point2D(x: -wall.direction.y, y: wall.direction.x) * (wall.thickness / 2)
            let a = wall.start + wall.direction * (opening.offset - opening.width / 2)
            let b = wall.start + wall.direction * (opening.offset + opening.width / 2)
            if opening.kind == .window {
                entities.append(CADEntity(type: "LINE", layer: "IfcWindow", geometry: .line(a, b)))
                entities.append(CADEntity(type: "LINE", layer: "IfcWindow", geometry: .line(a + n, b + n)))
                entities.append(CADEntity(type: "LINE", layer: "IfcWindow", geometry: .line(a - n, b - n)))
            } else {
                entities.append(CADEntity(type: "LINE", layer: "IfcDoor", geometry: .line(a + n, a - n)))
                entities.append(CADEntity(type: "LINE", layer: "IfcDoor", geometry: .line(b + n, b - n)))
            }
        }
        for space in spaces where space.outline.count >= 3 {
            polyline(space.outline, layer: "IfcSpace")
            if let c = PlanPolygon.centroid(space.outline), !space.name.isEmpty {
                entities.append(CADEntity(type: "TEXT", layer: "IfcSpace", geometry: .text(CADText(position: c, height: 250, string: space.name, horizontal: .center, vertical: .middle))))
            }
        }
        let layers = ["IfcWall", "IfcDoor", "IfcWindow", "IfcSpace"].map { CADLayer(name: $0) }
        return CADDocument(units: .millimetres, layers: layers, entities: entities)
    }
}

/// v12.7 turns an IFC file into plan walls, openings and rooms.
///
/// Placements are resolved in 3D through their chains. Each wall's footprint comes from its body
/// (extruded rectangles or polygons, clipped solids, breps and tessellations, whatever points the
/// geometry has) and becomes the smallest rectangle around it: the axis runs down its middle, the
/// short side is the thickness. Doors and windows sit where their opening (or their own body) is,
/// along the wall it cuts.
public struct IFCModelReader {
    public init() {}

    public func read(data: Data) throws -> IFCArchitecturalModel {
        try read(STEPFile(data: data))
    }

    public func read(_ file: STEPFile) -> IFCArchitecturalModel {
        var context = Context(file: file)
        var model = IFCArchitecturalModel()
        model.name = file.entities.values.first { $0.type == "IFCPROJECT" }?.arguments[safe: 2]?.string

        // Walls. A straight wall is the smallest rectangle around its body; a wall whose footprint
        // fills that rectangle poorly (an L or a U) is split into its straight runs.
        var wallIndexByEntity: [Int: [Int]] = [:]
        var wallBase: [Int: Double] = [:]
        let wallTypes: Set = ["IFCWALL", "IFCWALLSTANDARDCASE", "IFCWALLELEMENTEDCASE"]
        for id in file.entities.keys.sorted() {
            guard let entity = file.entities[id], wallTypes.contains(entity.type) else { continue }
            let points = context.bodyPoints(of: id)
            guard points.count >= 3, let rect = Self.minimumRectangle(points.map { Point2D(x: $0.x, y: $0.y) }) else { continue }
            let zs = points.map(\.z)
            let height = (zs.max() ?? 0) - (zs.min() ?? 0)
            guard rect.length > 50, rect.thickness > 10 else { continue }
            var pieces: [TracedWall] = []
            if let outline = context.footprintPolygon(of: id), outline.count >= 5,
               PlanPolygon.area(outline) < 0.85 * rect.length * rect.thickness {
                let edges = zip(outline, outline.dropFirst() + [outline[0]]).map { UnderlayWallTracer.Segment($0.0, $0.1) }
                pieces = UnderlayWallTracer(segments: edges).traceAll().walls
            }
            if pieces.isEmpty {
                guard rect.thickness < 1_500 else { continue }
                pieces = [TracedWall(start: rect.start, end: rect.end, thickness: rect.thickness)]
            }
            for piece in pieces {
                wallIndexByEntity[id, default: []].append(model.walls.count)
                wallBase[model.walls.count] = zs.min() ?? 0
                model.walls.append(TracedWall(start: piece.start, end: piece.end, thickness: (piece.thickness * 10).rounded() / 10))
                model.wallHeights.append(height > 100 ? height : ArchitecturalDraftingConvention.Defaults().wallHeight)
            }
        }

        // Openings: void → wall, fill → door/window.
        var voidHost: [Int: Int] = [:]
        var fillOf: [Int: Int] = [:]
        for entity in file.entities.values {
            if entity.type == "IFCRELVOIDSELEMENT", let wall = entity.arguments[safe: 4]?.ref, let void = entity.arguments[safe: 5]?.ref { voidHost[void] = wall }
            if entity.type == "IFCRELFILLSELEMENT", let void = entity.arguments[safe: 4]?.ref, let filler = entity.arguments[safe: 5]?.ref { fillOf[filler] = void }
        }
        let fillerTypes: [String: PlanOpsisOpening.Kind] = ["IFCDOOR": .door, "IFCDOORSTANDARDCASE": .door, "IFCWINDOW": .window, "IFCWINDOWSTANDARDCASE": .window]
        var filledVoids = Set<Int>()
        for id in file.entities.keys.sorted() {
            guard let entity = file.entities[id], let kind = fillerTypes[entity.type] else { continue }
            let void = fillOf[id]
            if let void { filledVoids.insert(void) }
            // The void says where the opening is; the filler's own body is the fallback.
            var points = void.map { context.bodyPoints(of: $0) } ?? []
            if points.count < 3 { points = context.bodyPoints(of: id) }
            let hosts = void.flatMap { voidHost[$0] }.flatMap { wallIndexByEntity[$0] }
            let width = entity.arguments[safe: 9]?.number.map { $0 * context.unitScale }
            let height = entity.arguments[safe: 8]?.number.map { $0 * context.unitScale }
            guard var placed = place(points: points, kind: kind, hosts: hosts, width: width, height: height, walls: model.walls,
                                     wallBase: { wallBase[$0] ?? 0 }) else { continue }
            if kind == .door {
                // IFC operation types: hinge side as seen looking along the door's +y, the way it opens.
                let operationName = entity.arguments[safe: 11]?.enumeration ?? entity.arguments[safe: 10]?.enumeration ?? ""
                let userDefined = entity.arguments[safe: 12]?.string ?? ""
                let operation = Self.doorOperation(operationName) ?? (operationName == "USERDEFINED" && userDefined.uppercased().contains("POCKET") ? .pocket : nil)
                if let operation { model.doorOperations[model.openings.count] = operation }
                let frame = context.placement(entity.arguments[safe: 5]?.ref)
                let wall = model.walls[placed.opening.wallIndex]
                let normal = Point2D(x: -wall.direction.y, y: wall.direction.x)
                let x = Point2D(x: frame.x.x, y: frame.x.y), y = Point2D(x: frame.y.x, y: frame.y.y)
                if let hand = Self.hingeHand(operationName), abs(x.dot(wall.direction)) > 0.7, abs(y.dot(normal)) > 0.7 {
                    placed.opening.opensToLeft = y.dot(normal) > 0
                    placed.opening.hingeAtEnd = hand == .left ? x.dot(wall.direction) < 0 : x.dot(wall.direction) > 0
                }
                placed.opening.isDouble = operation == .doubleHinged
            }
            model.openingHeights.append((placed.height, placed.sill))
            model.openings.append(placed.opening)
        }
        // Voids nobody fills are plain openings only when they reach the floor (passages), not recesses.
        for (void, wallEntity) in voidHost.sorted(by: { $0.key < $1.key }) where !filledVoids.contains(void) {
            guard let hosts = wallIndexByEntity[wallEntity] else { continue }
            let points = context.bodyPoints(of: void)
            guard let placed = place(points: points, kind: .opening, hosts: hosts, width: nil, height: nil, walls: model.walls, wallBase: { wallBase[$0] ?? 0 }),
                  placed.sill < 50, placed.height > 1_800 else { continue }
            model.openingHeights.append((placed.height, placed.sill))
            model.openings.append(placed.opening)
        }

        // Spaces: their footprint and name, for naming the rooms the walls enclose.
        for id in file.entities.keys.sorted() {
            guard let entity = file.entities[id], entity.type == "IFCSPACE" else { continue }
            let points = context.bodyPoints(of: id).map { Point2D(x: $0.x, y: $0.y) }
            let outline = context.footprintOutline(of: id) ?? Self.convexHull(points)
            guard outline.count >= 3 else { continue }
            let longName = entity.arguments[safe: 7]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = entity.arguments[safe: 2]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            model.spaces.append(.init(name: longName.isEmpty ? name : longName, outline: outline))
        }
        return model
    }

    /// An opening along its wall from the points of its void or body.
    private func place(points: [Point3], kind: PlanOpsisOpening.Kind, hosts: [Int]?, width: Double?, height: Double?,
                       walls: [TracedWall], wallBase: (Int) -> Double) -> (opening: TracedOpening, height: Double, sill: Double)? {
        guard !points.isEmpty else { return nil }
        let plan = points.map { Point2D(x: $0.x, y: $0.y) }
        let center = plan.reduce(Point2D.zero) { $0 + $1 } * (1 / Double(plan.count))
        // The host wall's straight run nearest the opening (any wall when the file names none).
        let candidates = hosts.map { Array($0) } ?? Array(walls.indices)
        let wallIndex = candidates.min { a, b in
            Self.distance(center, to: walls[a]) < Self.distance(center, to: walls[b])
        }
        guard let wallIndex, Self.distance(center, to: walls[wallIndex]) <= walls[wallIndex].thickness + 300 else { return nil }
        let wall = walls[wallIndex]
        let along = plan.map { ($0 - wall.start).dot(wall.direction) }
        guard let low = along.min(), let high = along.max() else { return nil }
        let measured = high - low
        let w = (width.map { $0 > 1 ? $0 : measured } ?? measured)
        guard w > 100 else { return nil }
        let zs = points.map(\.z)
        let base = wallBase(wallIndex)
        let sill = max(0, (zs.min() ?? base) - base)
        let h = height.flatMap { $0 > 1 ? $0 : nil } ?? max(1, (zs.max() ?? 0) - (zs.min() ?? 0))
        let opening = TracedOpening(kind: kind, wallIndex: wallIndex, offset: (low + high) / 2, width: min(w, wall.length))
        return (opening, h, kind == .door ? 0 : sill)
    }

    enum Hand { case left, right }

    /// Which side the hinge (or the slide) is on, seen looking along the door's +y.
    static func hingeHand(_ value: String) -> Hand? {
        switch value {
        case "SINGLE_SWING_LEFT", "DOUBLE_SWING_LEFT": return .left
        case "SINGLE_SWING_RIGHT", "DOUBLE_SWING_RIGHT": return .right
        default: return nil
        }
    }

    static func doorOperation(_ value: String) -> PlanOpsisDoor.Operation? {
        switch value {
        case "DOUBLE_DOOR_SINGLE_SWING", "DOUBLE_DOOR_DOUBLE_SWING", "DOUBLE_SWING_LEFT", "DOUBLE_SWING_RIGHT": return .doubleHinged
        case "SLIDING_TO_LEFT", "SLIDING_TO_RIGHT", "DOUBLE_DOOR_SLIDING": return .sliding
        case "SINGLE_SWING_LEFT", "SINGLE_SWING_RIGHT": return .singleHinged
        default: return nil
        }
    }

    static func distance(_ p: Point2D, to wall: TracedWall) -> Double {
        let t = max(0, min(wall.length, (p - wall.start).dot(wall.direction)))
        return (p - (wall.start + wall.direction * t)).length
    }

    // MARK: Geometry

    /// The smallest rectangle around the points: its long axis, length and short side.
    static func minimumRectangle(_ points: [Point2D]) -> (start: Point2D, end: Point2D, length: Double, thickness: Double)? {
        let hull = convexHull(points)
        guard hull.count >= 2 else { return nil }
        var best: (area: Double, u: Point2D, lo: Double, hi: Double, nlo: Double, nhi: Double)?
        for i in hull.indices {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            guard edge.length > 1e-9 else { continue }
            let u = edge.normalized, n = Point2D(x: -u.y, y: u.x)
            let a = hull.map { $0.dot(u) }, b = hull.map { $0.dot(n) }
            let lo = a.min()!, hi = a.max()!, nlo = b.min()!, nhi = b.max()!
            let area = (hi - lo) * (nhi - nlo)
            if best == nil || area < best!.area - 1e-6 { best = (area, u, lo, hi, nlo, nhi) }
        }
        guard var r = best else { return nil }
        // The long side is the axis.
        if r.nhi - r.nlo > r.hi - r.lo {
            let n = Point2D(x: -r.u.y, y: r.u.x)
            r = (r.area, n, r.nlo, r.nhi, -r.hi, -r.lo)
        }
        let n = Point2D(x: -r.u.y, y: r.u.x)
        let mid = (r.nlo + r.nhi) / 2
        return (r.u * r.lo + n * mid, r.u * r.hi + n * mid, r.hi - r.lo, r.nhi - r.nlo)
    }

    static func convexHull(_ points: [Point2D]) -> [Point2D] {
        let sorted = Array(Set(points.map { [($0.x * 1_000).rounded() / 1_000, ($0.y * 1_000).rounded() / 1_000] })).map { Point2D(x: $0[0], y: $0[1]) }
            .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Point2D] = [], upper: [Point2D] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// A 3D point.
struct Point3: Hashable { var x, y, z: Double }

/// A rigid 3D frame: origin plus axes (columns).
struct Frame3 {
    var origin = Point3(x: 0, y: 0, z: 0)
    var x = Point3(x: 1, y: 0, z: 0)
    var y = Point3(x: 0, y: 1, z: 0)
    var z = Point3(x: 0, y: 0, z: 1)

    func apply(_ p: Point3) -> Point3 {
        Point3(x: origin.x + x.x * p.x + y.x * p.y + z.x * p.z,
               y: origin.y + x.y * p.x + y.y * p.y + z.y * p.z,
               z: origin.z + x.z * p.x + y.z * p.y + z.z * p.z)
    }
    func applyVector(_ v: Point3) -> Point3 {
        Point3(x: x.x * v.x + y.x * v.y + z.x * v.z, y: x.y * v.x + y.y * v.y + z.y * v.z, z: x.z * v.x + y.z * v.y + z.z * v.z)
    }
    /// self ∘ inner: inner's coordinates expressed in self's parent.
    func then(_ inner: Frame3) -> Frame3 {
        Frame3(origin: apply(inner.origin), x: applyVector(inner.x), y: applyVector(inner.y), z: applyVector(inner.z))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct Context {
    let file: STEPFile
    /// Millimetres per model length unit.
    let unitScale: Double
    var placements: [Int: Frame3] = [:]

    init(file: STEPFile) {
        self.file = file
        var scale = 1_000.0
        if let unit = file.entities.values.first(where: { $0.type == "IFCSIUNIT" && $0.arguments[safe: 1]?.enumeration == "LENGTHUNIT" }) {
            switch unit.arguments[safe: 2]?.enumeration {
            case "MILLI": scale = 1
            case "CENTI": scale = 10
            case "DECI": scale = 100
            case "KILO": scale = 1_000_000
            default: scale = 1_000
            }
        } else if let unit = file.entities.values.first(where: { $0.type == "IFCCONVERSIONBASEDUNIT" && $0.arguments[safe: 1]?.enumeration == "LENGTHUNIT" }) {
            switch unit.arguments[safe: 2]?.string?.uppercased() {
            case "FOOT": scale = 304.8
            case "INCH": scale = 25.4
            default: scale = 1_000
            }
        }
        unitScale = scale
    }

    func point(_ id: Int?) -> Point3? {
        guard let e = file[id], e.type == "IFCCARTESIANPOINT" else { return nil }
        let c = e.arguments[safe: 0]?.list.compactMap(\.number) ?? []
        guard c.count >= 2 else { return nil }
        return Point3(x: c[0] * unitScale, y: c[1] * unitScale, z: (c.count > 2 ? c[2] : 0) * unitScale)
    }

    func direction(_ id: Int?) -> Point3? {
        guard let e = file[id], e.type == "IFCDIRECTION" else { return nil }
        let c = e.arguments[safe: 0]?.list.compactMap(\.number) ?? []
        guard c.count >= 2 else { return nil }
        let v = Point3(x: c[0], y: c[1], z: c.count > 2 ? c[2] : 0)
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-12 ? Point3(x: v.x / l, y: v.y / l, z: v.z / l) : nil
    }

    static func cross(_ a: Point3, _ b: Point3) -> Point3 {
        Point3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    /// IfcAxis2Placement3D / 2D as a frame.
    func axisPlacement(_ id: Int?) -> Frame3 {
        guard let e = file[id] else { return Frame3() }
        var frame = Frame3()
        frame.origin = point(e.arguments[safe: 0]?.ref) ?? frame.origin
        if e.type == "IFCAXIS2PLACEMENT2D" {
            if let x = direction(e.arguments[safe: 1]?.ref) {
                frame.x = Point3(x: x.x, y: x.y, z: 0)
                frame.y = Point3(x: -x.y, y: x.x, z: 0)
            }
            return frame
        }
        let z = direction(e.arguments[safe: 1]?.ref) ?? Point3(x: 0, y: 0, z: 1)
        var x = direction(e.arguments[safe: 2]?.ref) ?? (abs(z.x) > 0.9 ? Point3(x: 0, y: 1, z: 0) : Point3(x: 1, y: 0, z: 0))
        // Make x perpendicular to z.
        let d = x.x * z.x + x.y * z.y + x.z * z.z
        x = Point3(x: x.x - d * z.x, y: x.y - d * z.y, z: x.z - d * z.z)
        let l = (x.x * x.x + x.y * x.y + x.z * x.z).squareRoot()
        if l > 1e-12 { x = Point3(x: x.x / l, y: x.y / l, z: x.z / l) }
        frame.x = x
        frame.z = z
        frame.y = Self.cross(z, x)
        return frame
    }

    /// World frame of an IfcLocalPlacement chain.
    mutating func placement(_ id: Int?) -> Frame3 {
        guard let id else { return Frame3() }
        if let cached = placements[id] { return cached }
        guard let e = file[id], e.type == "IFCLOCALPLACEMENT" else { return Frame3() }
        placements[id] = Frame3() // cycles resolve to identity
        let parent = placement(e.arguments[safe: 0]?.ref)
        let world = parent.then(axisPlacement(e.arguments[safe: 1]?.ref))
        placements[id] = world
        return world
    }

    /// Points of a product's 3D body in world plan millimetres.
    mutating func bodyPoints(of productID: Int) -> [Point3] {
        guard let product = file[productID] else { return [] }
        let world = placement(product.arguments[safe: 5]?.ref)
        guard let shape = file[product.arguments[safe: 6]?.ref] else { return [] }
        var representations = shape.arguments[safe: 2]?.list.compactMap(\.ref) ?? []
        // Prefer the body; plan-only representations (Axis, FootPrint) are fallbacks.
        representations.sort { rank(file[$0]) < rank(file[$1]) }
        for representation in representations {
            guard let rep = file[representation] else { continue }
            var points: [Point3] = []
            for item in rep.arguments[safe: 3]?.list.compactMap(\.ref) ?? [] {
                points += itemPoints(item, frame: world, depth: 0)
            }
            if points.count >= 3 { return points }
        }
        return []
    }

    func rank(_ rep: STEPFile.Entity?) -> Int {
        switch rep?.arguments[safe: 1]?.string?.lowercased() {
        case "body": return 0
        case "footprint": return 1
        default: return 2
        }
    }

    /// The plan outline of a space when its body is an extruded profile.
    mutating func footprintOutline(of productID: Int) -> [Point2D]? {
        guard let product = file[productID], let shape = file[product.arguments[safe: 6]?.ref] else { return nil }
        let world = placement(product.arguments[safe: 5]?.ref)
        for representation in shape.arguments[safe: 2]?.list.compactMap(\.ref) ?? [] {
            for item in file[representation]?.arguments[safe: 3]?.list.compactMap(\.ref) ?? [] {
                guard let solid = file[item], solid.type == "IFCEXTRUDEDAREASOLID" else { continue }
                let frame = world.then(axisPlacement(solid.arguments[safe: 1]?.ref))
                let profile = profilePoints(solid.arguments[safe: 0]?.ref)
                if profile.count >= 3 { return profile.map { let p = frame.apply($0); return Point2D(x: p.x, y: p.y) } }
            }
        }
        return nil
    }

    /// The plan outline of a product's body: an extruded profile (through clipping results) when it is
    /// extruded vertically, else a horizontal face of a brep. Nil when neither applies.
    mutating func footprintPolygon(of productID: Int) -> [Point2D]? {
        guard let product = file[productID], let shape = file[product.arguments[safe: 6]?.ref] else { return nil }
        let world = placement(product.arguments[safe: 5]?.ref)
        var representations = shape.arguments[safe: 2]?.list.compactMap(\.ref) ?? []
        representations.sort { rank(file[$0]) < rank(file[$1]) }
        for representation in representations {
            for item in file[representation]?.arguments[safe: 3]?.list.compactMap(\.ref) ?? [] {
                if let outline = itemFootprint(item, frame: world, depth: 0) { return outline }
            }
        }
        return nil
    }

    mutating func itemFootprint(_ id: Int, frame: Frame3, depth: Int) -> [Point2D]? {
        guard depth < 12, let e = file[id] else { return nil }
        switch e.type {
        case "IFCBOOLEANCLIPPINGRESULT", "IFCBOOLEANRESULT":
            return e.arguments[safe: 1]?.ref.flatMap { itemFootprint($0, frame: frame, depth: depth + 1) }
        case "IFCEXTRUDEDAREASOLID":
            let solidFrame = frame.then(axisPlacement(e.arguments[safe: 1]?.ref))
            let along = solidFrame.applyVector(direction(e.arguments[safe: 2]?.ref) ?? Point3(x: 0, y: 0, z: 1))
            guard abs(along.z) > 0.99 else { return nil }
            let profile = profilePoints(e.arguments[safe: 0]?.ref)
            return profile.count >= 3 ? profile.map { let p = solidFrame.apply($0); return Point2D(x: p.x, y: p.y) } : nil
        case "IFCFACETEDBREP", "IFCFACETEDBREPWITHVOIDS":
            guard let shell = file[e.arguments[safe: 0]?.ref] else { return nil }
            var lowest: (z: Double, outline: [Point2D])?
            for faceID in shell.arguments[safe: 0]?.list.compactMap(\.ref) ?? [] {
                guard let face = file[faceID], let boundID = face.arguments[safe: 0]?.list.first?.ref,
                      let loop = file[file[boundID]?.arguments[safe: 0]?.ref], loop.type == "IFCPOLYLOOP" else { continue }
                let points = (loop.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).compactMap(point).map(frame.apply)
                guard points.count >= 3, let z = points.first?.z, points.allSatisfy({ abs($0.z - z) < 1 }) else { continue }
                if lowest == nil || z < lowest!.z { lowest = (z, points.map { Point2D(x: $0.x, y: $0.y) }) }
            }
            return lowest?.outline
        default:
            return nil
        }
    }

    /// Points of a geometric representation item, in `frame`.
    mutating func itemPoints(_ id: Int, frame: Frame3, depth: Int) -> [Point3] {
        guard depth < 12, let e = file[id] else { return [] }
        switch e.type {
        case "IFCEXTRUDEDAREASOLID":
            let solidFrame = frame.then(axisPlacement(e.arguments[safe: 1]?.ref))
            let profile = profilePoints(e.arguments[safe: 0]?.ref)
            let along = direction(e.arguments[safe: 2]?.ref) ?? Point3(x: 0, y: 0, z: 1)
            let length = (e.arguments[safe: 3]?.number ?? 0) * unitScale
            let top = Point3(x: along.x * length, y: along.y * length, z: along.z * length)
            return profile.flatMap { p in
                [solidFrame.apply(p), solidFrame.apply(Point3(x: p.x + top.x, y: p.y + top.y, z: p.z + top.z))]
            }
        case "IFCBOOLEANCLIPPINGRESULT", "IFCBOOLEANRESULT":
            guard let first = e.arguments[safe: 1]?.ref else { return [] }
            return itemPoints(first, frame: frame, depth: depth + 1)
        case "IFCMAPPEDITEM":
            guard let map = file[e.arguments[safe: 0]?.ref], let target = file[e.arguments[safe: 1]?.ref] else { return [] }
            let origin = axisPlacement(map.arguments[safe: 0]?.ref)
            let scale = target.arguments[safe: 3]?.number ?? 1
            var operatorFrame = Frame3()
            operatorFrame.origin = point(target.arguments[safe: 2]?.ref) ?? operatorFrame.origin
            if let x = direction(target.arguments[safe: 0]?.ref) { operatorFrame.x = x }
            if let y = direction(target.arguments[safe: 1]?.ref) { operatorFrame.y = y }
            operatorFrame.x = Point3(x: operatorFrame.x.x * scale, y: operatorFrame.x.y * scale, z: operatorFrame.x.z * scale)
            operatorFrame.y = Point3(x: operatorFrame.y.x * scale, y: operatorFrame.y.y * scale, z: operatorFrame.y.z * scale)
            operatorFrame.z = Point3(x: 0, y: 0, z: scale)
            let mappedFrame = frame.then(operatorFrame).then(Frame3(origin: Point3(x: -origin.origin.x, y: -origin.origin.y, z: -origin.origin.z)))
            guard let rep = file[map.arguments[safe: 1]?.ref] else { return [] }
            return (rep.arguments[safe: 3]?.list.compactMap(\.ref) ?? []).flatMap { itemPoints($0, frame: mappedFrame, depth: depth + 1) }
        case "IFCPOLYLINE":
            return (e.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).compactMap(point).map(frame.apply)
        case "IFCFACETEDBREP", "IFCFACETEDBREPWITHVOIDS":
            guard let shell = file[e.arguments[safe: 0]?.ref] else { return [] }
            return (shell.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).flatMap { faceID -> [Point3] in
                guard let face = file[faceID] else { return [] }
                return (face.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).flatMap { boundID -> [Point3] in
                    guard let bound = file[boundID], let loop = file[bound.arguments[safe: 0]?.ref], loop.type == "IFCPOLYLOOP" else { return [] }
                    return (loop.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).compactMap(point).map(frame.apply)
                }
            }
        case "IFCTRIANGULATEDFACESET", "IFCPOLYGONALFACESET":
            guard let list = file[e.arguments[safe: 0]?.ref] else { return [] }
            return (list.arguments[safe: 0]?.list ?? []).compactMap { tuple -> Point3? in
                let c = tuple.list.compactMap(\.number)
                guard c.count >= 3 else { return nil }
                return frame.apply(Point3(x: c[0] * unitScale, y: c[1] * unitScale, z: c[2] * unitScale))
            }
        default:
            return []
        }
    }

    /// Outline points of a profile in its own plane (z = 0), in millimetres.
    func profilePoints(_ id: Int?) -> [Point3] {
        guard let e = file[id] else { return [] }
        switch e.type {
        case "IFCRECTANGLEPROFILEDEF", "IFCRECTANGLEHOLLOWPROFILEDEF", "IFCROUNDEDRECTANGLEPROFILEDEF":
            let frame = axisPlacement(e.arguments[safe: 2]?.ref)
            let w = (e.arguments[safe: 3]?.number ?? 0) * unitScale / 2, h = (e.arguments[safe: 4]?.number ?? 0) * unitScale / 2
            return [(-w, -h), (w, -h), (w, h), (-w, h)].map { frame.apply(Point3(x: $0.0, y: $0.1, z: 0)) }
        case "IFCARBITRARYCLOSEDPROFILEDEF", "IFCARBITRARYPROFILEDEFWITHVOIDS":
            return curvePoints(e.arguments[safe: 2]?.ref)
        case "IFCCIRCLEPROFILEDEF":
            let frame = axisPlacement(e.arguments[safe: 2]?.ref)
            let r = (e.arguments[safe: 3]?.number ?? 0) * unitScale
            return (0..<16).map { i in let a = Double(i) * .pi / 8; return frame.apply(Point3(x: r * cos(a), y: r * sin(a), z: 0)) }
        default:
            return []
        }
    }

    func curvePoints(_ id: Int?) -> [Point3] {
        guard let e = file[id] else { return [] }
        switch e.type {
        case "IFCPOLYLINE":
            var points = (e.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).compactMap(point)
            if points.count > 1, points.first == points.last { points.removeLast() }
            return points
        case "IFCINDEXEDPOLYCURVE":
            guard let list = file[e.arguments[safe: 0]?.ref] else { return [] }
            var points = (list.arguments[safe: 0]?.list ?? []).compactMap { tuple -> Point3? in
                let c = tuple.list.compactMap(\.number)
                guard c.count >= 2 else { return nil }
                return Point3(x: c[0] * unitScale, y: c[1] * unitScale, z: c.count > 2 ? c[2] * unitScale : 0)
            }
            if points.count > 1, points.first == points.last { points.removeLast() }
            return points
        case "IFCCOMPOSITECURVE":
            return (e.arguments[safe: 0]?.list.compactMap(\.ref) ?? []).flatMap { segmentID -> [Point3] in
                curvePoints(file[segmentID]?.arguments[safe: 2]?.ref)
            }
        case "IFCTRIMMEDCURVE":
            return curvePoints(e.arguments[safe: 0]?.ref)
        default:
            return []
        }
    }
}
