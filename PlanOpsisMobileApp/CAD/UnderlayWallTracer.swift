import Foundation

/// A wall found between two parallel face lines of a drawing, in plan millimetres.
public struct TracedWall: Hashable, Sendable {
    public var start: Point2D
    public var end: Point2D
    public var thickness: Double

    public init(start: Point2D, end: Point2D, thickness: Double) {
        self.start = start
        self.end = end
        self.thickness = thickness
    }

    public var length: Double { (end - start).length }
    public var direction: Point2D { (end - start).normalized }
}

/// A door or window found in a gap between two collinear traced walls.
public struct TracedOpening: Hashable, Sendable {
    public var kind: PlanOpsisOpening.Kind
    /// Index into `UnderlayTraceResult.walls`.
    public var wallIndex: Int
    /// Centre of the opening along the wall from its start, mm.
    public var offset: Double
    public var width: Double
}

public struct UnderlayTraceResult: Hashable, Sendable {
    public var walls: [TracedWall] = []
    public var openings: [TracedOpening] = []
}

/// v12.6 turns the double lines of an architect's drawing into walls.
///
/// A wall is two parallel lines between `minThickness` and `maxThickness` apart. Its axis runs midway;
/// it spans where both faces run, reaching half the corner when one face continues round a corner.
/// `trace(at:)` finds the wall under a tap; `traceAll()` converts every wall drawn on the given lines,
/// joins walls at corners and T-junctions, and turns door and window gaps into openings.
public struct UnderlayWallTracer: Sendable {
    public struct Segment: Hashable, Sendable {
        public var a: Point2D
        public var b: Point2D
        public init(_ a: Point2D, _ b: Point2D) { self.a = a; self.b = b }
        public var length: Double { (b - a).length }
        public var direction: Point2D { (b - a).normalized }
    }

    /// A short drawn item near a wall gap that tells doors from windows.
    public struct Symbol: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case doorSwing, window }
        public var kind: Kind
        public var bounds: CADRect
        /// Door swing arcs: centre and radius.
        public var center: Point2D?
        public var radius: Double?
        public init(kind: Kind, bounds: CADRect, center: Point2D? = nil, radius: Double? = nil) {
            self.kind = kind; self.bounds = bounds; self.center = center; self.radius = radius
        }
    }

    public var minThickness = 50.0
    public var maxThickness = 700.0
    public var minLength = 100.0
    public var parallelToleranceDegrees = 2.0
    public private(set) var segments: [Segment]
    public var symbols: [Symbol] = []

    public init(segments: [Segment], symbols: [Symbol] = []) {
        self.segments = Self.merged(segments.filter { $0.length > 1 })
        self.symbols = symbols
    }

    // MARK: Drawings

    /// Straight lines of the visible items in a placed scene (plan mm), optionally only on some layers,
    /// with door arcs and window symbols for opening detection.
    public init(scene: CADScene, hiddenLayers: Set<String> = [], near region: CADRect? = nil, layers: ((String) -> Bool)? = nil) {
        var segments: [Segment] = []
        var symbols: [Symbol] = []
        let items = region.map { scene.items(in: $0, hiddenLayers: hiddenLayers) } ?? scene.items.filter { scene.isVisible($0, hiddenLayers: hiddenLayers) }
        for item in items where item.isSnappable {
            if let arc = item.arc, !arc.isFullCircle, Self.isDoorLayer(item.layer) || Self.isDoorSwing(arc) {
                symbols.append(Symbol(kind: .doorSwing, bounds: item.bounds, center: arc.center, radius: arc.radius))
                continue
            }
            if Self.isWindowLayer(item.layer) {
                symbols.append(Symbol(kind: .window, bounds: item.bounds))
                continue
            }
            if let layers, !layers(item.layer) { continue }
            guard item.arc == nil else { continue }
            switch item.shape {
            case let .path(points, closed):
                for (p, q) in zip(points, points.dropFirst()) { segments.append(Segment(p, q)) }
                if closed, let first = points.first, let last = points.last, points.count > 2 { segments.append(Segment(last, first)) }
            case let .segments(points):
                var i = 0
                while i + 1 < points.count { segments.append(Segment(points[i], points[i + 1])); i += 2 }
            default:
                break
            }
        }
        self.init(segments: segments, symbols: symbols)
    }

    /// Layers that hold wall outlines: IfcWall, A-WALL, WALL, MUR, WAND, MURO, PARED, but not axes or
    /// hatching.
    public static func isWallLayer(_ name: String) -> Bool {
        let n = name.uppercased()
        let excluded = ["AXIS", "CNTR", "CENTER", "CENTRE", "PATT", "HATCH", "HTCH", "DIM", "TEXT", "IDEN"]
        guard !excluded.contains(where: n.contains) else { return false }
        return ["IFCWALL", "WALL", "MUR", "WAND", "PARED"].contains(where: n.contains)
    }

    static func isDoorLayer(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["IFCDOOR", "DOOR", "PORTE", "TUER", "TÜR", "PUERTA"].contains(where: n.contains)
    }

    static func isWindowLayer(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["IFCWINDOW", "WINDOW", "GLAZ", "FENETRE", "FENÊTRE", "FENSTER", "VENTANA"].contains(where: n.contains)
    }

    /// A quarter-ish arc of door-leaf size.
    static func isDoorSwing(_ arc: CADSceneArc) -> Bool {
        let degrees = abs(arc.sweep) * 180 / .pi
        return (500...1_400).contains(arc.radius) && (60...100).contains(degrees)
    }

    // MARK: Tracing

    /// The wall whose two faces straddle `point`: the closest pair of parallel lines on either side.
    public func trace(at point: Point2D) -> TracedWall? {
        let near = segments.filter { s in
            let u = s.direction, t = (point - s.a).dot(u)
            return t >= -10 && t <= s.length + 10 && abs(Self.cross(u, point - s.a)) <= maxThickness
        }
        var best: (wall: TracedWall, score: Double)?
        for i in near.indices {
            for j in near.indices where j > i {
                let a = near[i], b = near[j]
                guard isParallel(a, b) else { continue }
                let u = a.direction
                let da = Self.cross(u, point - a.a), db = Self.cross(u, point - b.a)
                guard da * db < 0 else { continue }
                let separation = abs(da - db)
                guard separation >= minThickness, separation <= maxThickness, let wall = wall(between: a, and: b) else { continue }
                let score = separation + abs(abs(da) - abs(db)) * 0.1
                if best == nil || score < best!.score { best = (wall, score) }
            }
        }
        return best?.wall
    }

    /// Every wall drawn as a pair of faces, joined at corners and T-junctions, with door and window gaps
    /// bridged into openings where a door swing or window symbol sits in the gap.
    public func traceAll() -> UnderlayTraceResult {
        var walls: [TracedWall] = []
        var paired = Set<[Int]>()
        let order = segments.indices.sorted { segments[$0].length > segments[$1].length }
        for i in order {
            let a = segments[i]
            var best: (j: Int, separation: Double)?
            for j in segments.indices where j != i {
                let b = segments[j]
                guard isParallel(a, b) else { continue }
                let separation = abs(Self.cross(a.direction, b.a - a.a))
                guard separation >= minThickness, separation <= maxThickness, overlap(a, b) >= min(minLength, 0.3 * min(a.length, b.length)) else { continue }
                if best == nil || separation < best!.separation { best = (j, separation) }
            }
            guard let j = best?.j, paired.insert([min(i, j), max(i, j)]).inserted,
                  let wall = wall(between: a, and: segments[j]) else { continue }
            // A long face pairs with several shorter ones; keep each wall once.
            if walls.contains(where: { Self.duplicates($0, wall) }) { continue }
            walls.append(wall)
        }
        walls = Self.joined(walls)
        return bridgingOpenings(walls)
    }

    /// Moves wall ends onto the axis of a crossing wall when they stop within reach of it: a face ends at
    /// the other wall's face, the axis belongs on the other wall's axis.
    public static func joined(_ walls: [TracedWall], against others: [TracedWall] = []) -> [TracedWall] {
        let all = walls + others
        return walls.enumerated().map { index, wall in
            var result = wall
            for atEnd in [false, true] {
                let point = atEnd ? wall.end : wall.start
                let outward = atEnd ? wall.direction : wall.direction * -1
                var best: (point: Point2D, distance: Double)?
                for (k, other) in all.enumerated() where k != index {
                    let v = other.direction
                    let denominator = cross(outward, v)
                    guard abs(denominator) > sin(15 * Double.pi / 180) else { continue }
                    // Intersection of this wall's line with the other's axis.
                    let s = cross(other.start - point, v) / denominator
                    let reach = max(wall.thickness, other.thickness) * 0.75 + 20
                    guard abs(s) <= reach else { continue }
                    let crossing = point + outward * s
                    let along = (crossing - other.start).dot(v)
                    let slack = wall.thickness / 2 + reach
                    guard along >= -slack, along <= other.length + slack else { continue }
                    if best == nil || abs(s) < best!.distance { best = (crossing, abs(s)) }
                }
                if let best {
                    if atEnd { result.end = best.point } else { result.start = best.point }
                }
            }
            return result.length >= 1 ? result : wall
        }
    }

    // MARK: Geometry

    func isParallel(_ a: Segment, _ b: Segment) -> Bool {
        abs(Self.cross(a.direction, b.direction)) <= sin(parallelToleranceDegrees * .pi / 180)
    }

    /// Length over which two parallel segments run side by side.
    func overlap(_ a: Segment, _ b: Segment) -> Double {
        let u = a.direction
        let a0 = 0.0, a1 = a.length
        let b0 = (b.a - a.a).dot(u), b1 = (b.b - a.a).dot(u)
        return min(a1, max(b0, b1)) - max(a0, min(b0, b1))
    }

    /// The wall between two parallel faces: axis midway, spanning where both faces run and reaching
    /// halfway into a corner where one face carries on round it.
    func wall(between a: Segment, and b: Segment) -> TracedWall? {
        let u = a.direction
        let n = Point2D(x: -u.y, y: u.x)
        let separation = (b.a - a.a).dot(n)
        let origin = a.a + n * (separation / 2)
        let a0 = (a.a - origin).dot(u), a1 = (a.b - origin).dot(u)
        let b0 = (b.a - origin).dot(u), b1 = (b.b - origin).dot(u)
        let aLow = min(a0, a1), aHigh = max(a0, a1), bLow = min(b0, b1), bHigh = max(b0, b1)
        var low = max(aLow, bLow), high = min(aHigh, bHigh)
        guard high - low >= minLength else { return nil }
        let lowExcess = low - min(aLow, bLow), highExcess = max(aHigh, bHigh) - high
        if lowExcess <= maxThickness { low -= lowExcess / 2 }
        if highExcess <= maxThickness { high += highExcess / 2 }
        let thickness = (abs(separation) * 10).rounded() / 10
        return TracedWall(start: origin + u * low, end: origin + u * high, thickness: thickness)
    }

    static func cross(_ a: Point2D, _ b: Point2D) -> Double { a.x * b.y - a.y * b.x }

    static func duplicates(_ a: TracedWall, _ b: TracedWall) -> Bool {
        let u = a.direction
        guard abs(cross(u, b.direction)) < 0.02, abs(cross(u, b.start - a.start)) < 10 else { return false }
        let b0 = (b.start - a.start).dot(u), b1 = (b.end - a.start).dot(u)
        let shared = min(a.length, max(b0, b1)) - max(0, min(b0, b1))
        return shared > 0.5 * min(a.length, b.length)
    }

    /// Collinear segments that touch or overlap become one, so a face broken at polyline vertices
    /// reads as one line.
    static func merged(_ segments: [Segment], gap: Double = 5, offsetTolerance: Double = 2) -> [Segment] {
        struct Line { var segment: Segment; var u: Point2D; var offset: Double }
        var byAngle: [Int: [Line]] = [:]
        for s in segments {
            // Undirected angle in quarter degrees; lines a hair under 180° join those a hair over 0°.
            var angle = atan2(s.b.y - s.a.y, s.b.x - s.a.x)
            if angle < 0 { angle += .pi }
            if angle >= .pi { angle -= .pi }
            var key = Int((angle * 180 / .pi * 4).rounded())
            if key >= 720 { key = 0; angle -= .pi }
            let u = Point2D(x: cos(angle), y: sin(angle))
            byAngle[key, default: []].append(Line(segment: s, u: u, offset: s.a.dot(Point2D(x: -u.y, y: u.x))))
        }
        var result: [Segment] = []
        for key in byAngle.keys.sorted() {
            let lines = byAngle[key]!.sorted { $0.offset < $1.offset }
            var cluster: [Line] = []
            func flush() {
                guard let first = cluster.first else { return }
                let u = first.u, origin = first.segment.a
                let runs = cluster.map { line -> (Double, Double) in
                    let t0 = (line.segment.a - origin).dot(u), t1 = (line.segment.b - origin).dot(u)
                    return (min(t0, t1), max(t0, t1))
                }.sorted { $0.0 < $1.0 }
                var low = runs[0].0, high = runs[0].1
                for run in runs.dropFirst() {
                    if run.0 <= high + gap { high = max(high, run.1) } else {
                        result.append(Segment(origin + u * low, origin + u * high))
                        low = run.0; high = run.1
                    }
                }
                result.append(Segment(origin + u * low, origin + u * high))
                cluster = []
            }
            for line in lines {
                if let last = cluster.last, line.offset - last.offset > offsetTolerance { flush() }
                cluster.append(line)
            }
            flush()
        }
        return result
    }

    // MARK: Openings

    /// Joins two collinear walls of the same thickness across a gap holding a door swing or a window
    /// symbol, and records the opening.
    func bridgingOpenings(_ input: [TracedWall]) -> UnderlayTraceResult {
        var walls = input
        var openings: [(kind: PlanOpsisOpening.Kind, wall: Int, low: Double, high: Double)] = []
        var merged = true
        while merged {
            merged = false
            search: for i in walls.indices {
                for j in walls.indices where j != i {
                    let a = walls[i], b = walls[j]
                    let u = a.direction
                    guard abs(Self.cross(u, b.direction)) < 0.02, abs(Self.cross(u, b.start - a.start)) < 15,
                          abs(a.thickness - b.thickness) < 15 else { continue }
                    let b0 = (b.start - a.start).dot(u), b1 = (b.end - a.start).dot(u)
                    let gapLow = a.length, gapHigh = min(b0, b1)
                    let width = gapHigh - gapLow
                    guard width >= 400, width <= 3_500 else { continue }
                    let jambA = a.start + u * gapLow, jambB = a.start + u * gapHigh
                    guard let kind = openingKind(between: jambA, and: jambB, thickness: a.thickness) else { continue }
                    let joined = TracedWall(start: a.start, end: a.start + u * max(b0, b1), thickness: max(a.thickness, b.thickness))
                    // Openings already on either wall move onto the joined wall.
                    openings = openings.map { o in
                        if o.wall == i { return (o.kind, i, o.low, o.high) }
                        if o.wall == j {
                            let base = (walls[j].start - a.start).dot(u)
                            let flip = walls[j].direction.dot(u) < 0
                            let lo = flip ? base - o.high : base + o.low, hi = flip ? base - o.low : base + o.high
                            return (o.kind, i, lo, hi)
                        }
                        return o
                    }
                    openings.append((kind, i, gapLow, gapHigh))
                    walls[i] = joined
                    walls.remove(at: j)
                    openings = openings.map { o in (o.kind, o.wall > j ? o.wall - 1 : o.wall, o.low, o.high) }
                    merged = true
                    break search
                }
            }
        }
        return UnderlayTraceResult(walls: walls, openings: openings.map {
            TracedOpening(kind: $0.kind, wallIndex: $0.wall, offset: ($0.low + $0.high) / 2, width: $0.high - $0.low)
        })
    }

    func openingKind(between a: Point2D, and b: Point2D, thickness: Double) -> PlanOpsisOpening.Kind? {
        let width = (b - a).length
        let gap = CADRect(points: [a, b])!.expanded(by: thickness / 2 + 20)
        for symbol in symbols where symbol.kind == .doorSwing {
            guard let center = symbol.center, let radius = symbol.radius,
                  radius >= width * 0.35, radius <= width * 1.15 else { continue }
            if min((center - a).length, (center - b).length) <= thickness + 60 || gap.contains(center) { return .door }
        }
        if symbols.contains(where: { $0.kind == .window && $0.bounds.intersects(gap) }) { return .window }
        return nil
    }
}
