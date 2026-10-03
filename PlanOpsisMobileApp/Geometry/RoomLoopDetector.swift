import Foundation

/// v12.7 splits a set of walls into rooms: every closed loop of wall axes becomes a room.
///
/// Wall axes form a planar graph: walls are cut where another wall ends on them (T-junctions) or
/// crosses them, and ends closer than `joinTolerance` meet. Each bounded face of that graph is a room.
/// It holds the pieces of the walls around it (a partition shared by two rooms is in both, as when
/// RoomPlan captures both sides), any stem walls reaching into it, the openings on those pieces and the
/// components standing in it. Walls enclosing nothing stay together in one leftover room.
public struct RoomLoopDetector: Sendable {
    public struct Result: Sendable {
        /// Enclosed rooms, each with its centreline loop (counter-clockwise).
        public var rooms: [(room: PlanOpsisRoom, loop: [Point2D])]
        /// Walls, openings and components outside every loop, or nil when there are none.
        public var unenclosed: PlanOpsisRoom?
        public var allRooms: [PlanOpsisRoom] { rooms.map(\.room) + (unenclosed.map { [$0] } ?? []) }
    }

    public var joinTolerance = 30.0
    /// Loops smaller than this (mm²) are slivers between nearly coincident walls, not rooms.
    public var minimumArea = 500_000.0

    public init() {}

    /// - Parameter previousBoundary: the centreline outline the room's door swings were drawn against;
    ///   empty means "in" is the left of each wall's direction, as `UnderlayWallTracer` imports them.
    public func split(_ room: PlanOpsisRoom, previousBoundary: [Point2D] = []) -> Result {
        let walls = room.walls.filter { $0.length > joinTolerance }
        guard walls.count >= 3 else { return Result(rooms: [], unenclosed: room) }

        // Nodes: wall ends, T-junctions and crossings, merged within the tolerance.
        var nodes: [Point2D] = []
        func node(_ p: Point2D) -> Int {
            if let i = nodes.firstIndex(where: { ($0 - p).length <= joinTolerance }) { return i }
            nodes.append(p)
            return nodes.count - 1
        }
        var cuts: [[Double]] = walls.map { [0, $0.length] }
        for (i, wall) in walls.enumerated() {
            let u = wall.direction
            for (j, other) in walls.enumerated() where j != i {
                for end in [other.start, other.end] {
                    let t = (end - wall.start).dot(u)
                    if t > joinTolerance, t < wall.length - joinTolerance, abs(Self.cross(u, end - wall.start)) <= joinTolerance { cuts[i].append(t) }
                }
                let v = other.direction, denominator = Self.cross(u, v)
                guard abs(denominator) > 1e-6 else { continue }
                let t = Self.cross(other.start - wall.start, v) / denominator
                let s = Self.cross(other.start - wall.start, u) / denominator
                if t > joinTolerance, t < wall.length - joinTolerance, s > joinTolerance, s < other.length - joinTolerance { cuts[i].append(t) }
            }
        }
        struct Edge { var a: Int; var b: Int; var wall: Int; var t0: Double; var t1: Double }
        var edges: [Edge] = []
        var seenPairs = Set<[Int]>()
        for (i, wall) in walls.enumerated() {
            let ts = cuts[i].sorted().reduce(into: [Double]()) { list, t in if list.last.map({ t - $0 > joinTolerance }) ?? true { list.append(t) } }
            for (t0, t1) in zip(ts, ts.dropFirst()) {
                let a = node(wall.start + wall.direction * t0), b = node(wall.start + wall.direction * t1)
                guard a != b, seenPairs.insert([min(a, b), max(a, b)]).inserted else { continue }
                edges.append(Edge(a: a, b: b, wall: i, t0: t0, t1: t1))
            }
        }

        // Half-edge h = 2e (a→b) or 2e+1 (b→a). Outgoing half-edges sorted counter-clockwise per node.
        func from(_ h: Int) -> Int { h % 2 == 0 ? edges[h / 2].a : edges[h / 2].b }
        func to(_ h: Int) -> Int { h % 2 == 0 ? edges[h / 2].b : edges[h / 2].a }
        var outgoing: [[Int]] = Array(repeating: [], count: nodes.count)
        for h in 0..<(edges.count * 2) { outgoing[from(h)].append(h) }
        for n in outgoing.indices {
            outgoing[n].sort { a, b in
                let da = nodes[to(a)] - nodes[n], db = nodes[to(b)] - nodes[n]
                return atan2(da.y, da.x) < atan2(db.y, db.x)
            }
        }
        // Following the clockwise neighbour of the reverse edge keeps each face on the left.
        func next(_ h: Int) -> Int {
            let list = outgoing[to(h)]
            let twin = h ^ 1
            let index = list.firstIndex(of: twin)!
            return list[(index - 1 + list.count) % list.count]
        }
        var visited = Set<Int>()
        var faces: [[Int]] = []
        for start in 0..<(edges.count * 2) where !visited.contains(start) {
            var face: [Int] = []
            var h = start
            while visited.insert(h).inserted {
                face.append(h)
                h = next(h)
            }
            if h == start { faces.append(face) }
        }

        struct Loop { var halfEdges: [Int]; var polygon: [Point2D]; var area: Double }
        let loops: [Loop] = faces.compactMap { face in
            let polygon = face.map { nodes[from($0)] }
            let area = Self.signedArea(polygon)
            return area >= minimumArea ? Loop(halfEdges: face, polygon: polygon, area: area) : nil
        }.sorted { $0.area < $1.area }

        // Wall pieces per loop: the stretches of each wall the loop runs along.
        var usedIDs = Set<UUID>()
        func freshID(_ id: UUID) -> UUID { usedIDs.insert(id).inserted ? id : UUID() }
        func piece(_ wall: PlanOpsisWall, _ t0: Double, _ t1: Double, whole: Bool) -> PlanOpsisWall {
            var w = wall
            w.id = whole ? freshID(wall.id) : UUID()
            if whole { return w }
            w.start = wall.start + wall.direction * t0
            w.length = t1 - t0
            w.sourceRoomPlanID = nil
            return w
        }
        func intervals(_ list: [(Double, Double)]) -> [(Double, Double)] {
            var merged: [(Double, Double)] = []
            for (a, b) in list.sorted(by: { $0.0 < $1.0 }) {
                if let last = merged.last, a <= last.1 + joinTolerance { merged[merged.count - 1].1 = max(last.1, b) } else { merged.append((a, b)) }
            }
            return merged
        }

        struct Piece { var wallIndex: Int; var t0: Double; var t1: Double; var wall: PlanOpsisWall }
        var usedByWall: [[(Double, Double)]] = Array(repeating: [], count: walls.count)
        var roomPieces: [[Piece]] = []
        for loop in loops {
            var byWall: [Int: [(Double, Double)]] = [:]
            for h in loop.halfEdges {
                let e = edges[h / 2]
                byWall[e.wall, default: []].append((e.t0, e.t1))
            }
            var pieces: [Piece] = []
            for wallIndex in byWall.keys.sorted() {
                let wall = walls[wallIndex]
                for (a, b) in intervals(byWall[wallIndex]!) {
                    usedByWall[wallIndex].append((a, b))
                    let whole = a <= joinTolerance && b >= wall.length - joinTolerance
                    pieces.append(Piece(wallIndex: wallIndex, t0: a, t1: b, wall: piece(wall, a, b, whole: whole)))
                }
            }
            roomPieces.append(pieces)
        }

        // What no loop runs along: stems and free walls go to the loop around them, else to the leftovers.
        var leftovers: [Piece] = []
        for (wallIndex, wall) in walls.enumerated() {
            var cursor = 0.0
            for (a, b) in intervals(usedByWall[wallIndex]) + [(wall.length, wall.length)] {
                if a - cursor > joinTolerance {
                    let whole = cursor <= joinTolerance && a >= wall.length - joinTolerance
                    let p = Piece(wallIndex: wallIndex, t0: cursor, t1: a, wall: piece(wall, cursor, a, whole: whole))
                    let mid = wall.start + wall.direction * ((cursor + a) / 2)
                    if let index = loops.firstIndex(where: { PlanPolygon.contains(mid, in: $0.polygon) }) {
                        roomPieces[index].append(p)
                    } else {
                        leftovers.append(p)
                    }
                }
                cursor = max(cursor, b)
            }
        }

        // Openings follow the piece holding their centre; door swings are re-read for each room.
        let originalInward: (PlanOpsisWall, Double) -> Double = { wall, offset in
            ArchitecturalSymbolLibrary.inwardSign(center: wall.start + wall.direction * offset, angle: wall.angleRadians, boundary: previousBoundary)
        }
        var usedOpeningIDs = Set<UUID>()
        func openings(on pieces: [Piece], loop: [Point2D]?) -> [PlanOpsisOpening] {
            var result: [PlanOpsisOpening] = []
            for opening in room.openings {
                let p = opening.parameters
                guard let wallIndex = walls.firstIndex(where: { $0.id == p.hostWallID }) else { continue }
                for piece in pieces where piece.wallIndex == wallIndex && p.offsetAlongWall >= piece.t0 - 1 && p.offsetAlongWall <= piece.t1 + 1 {
                    var copy = opening
                    var parameters = p
                    parameters.id = usedOpeningIDs.insert(p.id).inserted ? p.id : UUID()
                    parameters.hostWallID = piece.wall.id
                    parameters.offsetAlongWall = p.offsetAlongWall - piece.t0
                    copy.parameters = parameters
                    if case var .door(door) = copy, door.swing != .unspecified, let loop {
                        let wall = walls[wallIndex]
                        let probe = wall.start + wall.direction * p.offsetAlongWall + wall.normal * (wall.thickness / 2 + 50)
                        let inwardHere: Double = PlanPolygon.contains(probe, in: loop) ? 1 : -1
                        if inwardHere != originalInward(wall, p.offsetAlongWall) { door.swing = Self.flippedInOut(door.swing) }
                        copy = .door(door)
                    }
                    result.append(copy)
                }
            }
            return result
        }

        var unplacedComponents = room.components
        var rooms: [(room: PlanOpsisRoom, loop: [Point2D])] = []
        for (index, loop) in loops.enumerated() {
            let pieces = roomPieces[index]
            let components = unplacedComponents.filter { PlanPolygon.contains($0.position, in: loop.polygon) }
            unplacedComponents.removeAll { c in components.contains { $0.id == c.id } }
            let id = index == 0 ? room.id : UUID()
            rooms.append((PlanOpsisRoom(id: id, walls: pieces.map(\.wall), openings: openings(on: pieces, loop: loop.polygon),
                                        components: components, captureFloorElevationMM: room.captureFloorElevationMM), loop.polygon))
        }
        var unenclosed: PlanOpsisRoom?
        if !leftovers.isEmpty || !unplacedComponents.isEmpty {
            unenclosed = PlanOpsisRoom(id: rooms.isEmpty ? room.id : UUID(), walls: leftovers.map(\.wall), openings: openings(on: leftovers, loop: nil),
                                       components: unplacedComponents, captureFloorElevationMM: room.captureFloorElevationMM)
        }
        return Result(rooms: rooms, unenclosed: unenclosed)
    }

    /// The most room-like text inside each loop: words before numbers, then the tallest.
    public static func names(for loops: [[Point2D]], texts: [(position: Point2D, string: String, height: Double)]) -> [String?] {
        loops.map { loop in
            let inside = texts.filter { !$0.string.trimmingCharacters(in: .whitespaces).isEmpty && PlanPolygon.contains($0.position, in: loop) }
            func wordy(_ s: String) -> Bool {
                let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                return letters >= 2 && !s.contains("m²") && !s.lowercased().hasSuffix(" m2")
            }
            let best = inside.sorted { a, b in
                (wordy(a.string) ? 0 : 1, -a.height) < (wordy(b.string) ? 0 : 1, -b.height)
            }.first
            guard let best, wordy(best.string) else { return nil }
            return best.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func flippedInOut(_ swing: PlanOpsisDoor.Swing) -> PlanOpsisDoor.Swing {
        switch swing {
        case .leftIn: return .leftOut
        case .leftOut: return .leftIn
        case .rightIn: return .rightOut
        case .rightOut: return .rightIn
        case .unspecified: return .unspecified
        }
    }

    static func cross(_ a: Point2D, _ b: Point2D) -> Double { a.x * b.y - a.y * b.x }

    static func signedArea(_ polygon: [Point2D]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return zip(polygon, polygon.dropFirst() + [polygon[0]]).reduce(0) { $0 + cross($1.0, $1.1) } / 2
    }
}

extension CADScene {
    /// v12.7 the visible text of a placed drawing, for naming the rooms it labels.
    public func texts(hiddenLayers: Set<String> = []) -> [(position: Point2D, string: String, height: Double)] {
        items.compactMap { item in
            guard isVisible(item, hiddenLayers: hiddenLayers), case let .text(text) = item.shape else { return nil }
            return (text.position, text.string, text.height)
        }
    }
}
