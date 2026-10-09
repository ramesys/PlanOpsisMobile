import Foundation

/// v12.10 what a photo of a plan shows, read as architecture: walls, doors (with their swing), windows,
/// doorways and stairs, the text on it, and the scale the photo is at. Geometry is in the photo's pixels
/// (y up, origin bottom-left, as `PlanPhotoVectorizer` gives it); `plan(transform:)` places it in
/// millimetres and builds the rooms.
public struct PlanPhotoReading: Sendable {
    public enum WallStyle: String, Sendable, Hashable {
        /// Walls inked solid (poché), the usual hand-drawn and printed plan.
        case filled
        /// Walls drawn as two thin face lines.
        case outline
    }

    /// Where the scale came from, best first.
    public enum ScaleSource: Hashable, Sendable {
        /// Dimension figures read on the plan that agree with the lines they label.
        case dimensions(Int)
        /// Door swings, taken as standard 850 mm doors.
        case doors(Int)
        /// The thickest walls, taken as 300 mm.
        case wallThickness
        /// Nothing to go by: the photo taken as 15 m across.
        case assumed

        /// How sure the scale is: dimensions are read, the rest are rules of thumb.
        public var isMeasured: Bool { if case .dimensions = self { return true }; return false }

        public var summary: String {
            switch self {
            case let .dimensions(count): return "from \(count) dimension\(count == 1 ? "" : "s") on the plan"
            case let .doors(count): return "from \(count) door\(count == 1 ? "" : "s"), taken as 850 mm"
            case .wallThickness: return "from the wall thickness, taken as 300 mm"
            case .assumed: return "assumed (15 m across)"
            }
        }
    }

    /// A flight of stairs: treads across `runDirection`, `width` wide, `length` long.
    public struct Stair: Hashable, Sendable {
        public var center: Point2D
        /// Unit direction of travel (across the treads).
        public var runDirection: Point2D
        public var width: Double
        public var length: Double
        public var treads: Int
    }

    public struct Text: Hashable, Sendable {
        public var position: Point2D
        public var string: String
        public var height: Double
        public init(position: Point2D, string: String, height: Double) {
            self.position = position; self.string = string; self.height = height
        }
    }

    public var walls: [TracedWall]
    public var openings: [TracedOpening]
    public var stairs: [Stair]
    public var texts: [Text]
    public var wallStyle: WallStyle
    public var millimetresPerPixel: Double
    public var scaleSource: ScaleSource
    public var width: Int
    public var height: Int

    public var doorCount: Int { openings.filter { $0.kind == .door }.count }
    public var windowCount: Int { openings.filter { $0.kind == .window }.count }
    public var doorwayCount: Int { openings.filter { $0.kind == .opening }.count }

    /// The walls and openings in plan millimetres: `transform` takes photo pixels to the plan.
    public func trace(_ transform: CADAffine) -> UnderlayTraceResult {
        let k = transform.uniformScale
        return UnderlayTraceResult(
            walls: walls.map { TracedWall(start: transform.apply($0.start), end: transform.apply($0.end), thickness: ($0.thickness * k * 10).rounded() / 10) },
            openings: openings.map { o in
                var o = o
                o.offset *= k
                o.width *= k
                return o
            })
    }

    /// The plan the photo shows: rooms split from the closed wall loops (named from the text inside
    /// them), doors, windows and doorways on their walls, stairs in the room that holds them.
    public func plan(transform: CADAffine, wallHeight: Double = ArchitecturalDraftingConvention.Defaults().wallHeight) -> PhotoPlan {
        let traced = trace(transform)
        guard !traced.walls.isEmpty else { return PhotoPlan(rooms: [], roomNames: [:], trace: traced, stairs: 0) }
        let room = traced.makeRoom(wallHeight: wallHeight)
        let split = RoomLoopDetector().split(room)
        var rooms = split.allRooms.isEmpty ? [room] : split.allRooms
        let placedTexts = texts.map { (position: transform.apply($0.position), string: $0.string, height: $0.height * transform.uniformScale) }
        let loops = split.rooms.map(\.loop)
        var names: [UUID: String] = [:]
        for (entry, name) in zip(split.rooms, RoomLoopDetector.names(for: loops, texts: placedTexts)) {
            if let name { names[entry.room.id] = name }
        }
        let k = transform.uniformScale
        for stair in stairs {
            let center = transform.apply(stair.center)
            let run = transform.applyVector(stair.runDirection).normalized
            // The symbol's run is its local +y.
            let component = PlanOpsisComponent(kind: .stairs, position: center, width: stair.width * k, depth: stair.length * k,
                                               rotationRadians: atan2(run.y, run.x) - .pi / 2)
            let index = loops.firstIndex { PlanPolygon.contains(center, in: $0) } ?? 0
            if rooms.indices.contains(index) { rooms[index].components.append(component) }
        }
        return PhotoPlan(rooms: rooms, roomNames: names, trace: traced, stairs: stairs.count)
    }
}

/// v12.10 the rooms built from a photo, ready to go into a project.
public struct PhotoPlan: Sendable {
    public var rooms: [PlanOpsisRoom]
    public var roomNames: [UUID: String]
    public var trace: UnderlayTraceResult
    public var stairs: Int
}

/// v12.10 what a photo was read as, for the check after the plan is built.
public struct PhotoPlanReview: Identifiable, Sendable {
    public let id = UUID()
    public var walls: Int
    public var doors: Int
    public var windows: Int
    public var doorways: Int
    public var stairs: Int
    public var rooms: Int
    public var roomNames: [String]
    /// "from 3 dimensions on the plan", "calibrated"…
    public var scale: String
    /// Read from the plan or measured by the user, rather than a rule of thumb.
    public var scaleIsMeasured: Bool
    public var wallStyle: PlanPhotoReading.WallStyle
    public var millimetresPerPixel: Double

    public init(reading: PlanPhotoReading, plan: PhotoPlan, calibrated: Bool, millimetresPerPixel: Double) {
        walls = reading.walls.count
        doors = reading.doorCount
        windows = reading.windowCount
        doorways = reading.doorwayCount
        stairs = plan.stairs
        rooms = plan.rooms.filter { !$0.walls.isEmpty }.count
        roomNames = plan.rooms.compactMap { plan.roomNames[$0.id] }
        scale = calibrated ? "calibrated" : reading.scaleSource.summary
        scaleIsMeasured = calibrated || reading.scaleSource.isMeasured
        wallStyle = reading.wallStyle
        self.millimetresPerPixel = millimetresPerPixel
    }

    /// "12 walls, 4 doors, 3 windows, 1 stair in 3 rooms; scale from 2 dimensions on the plan."
    public var summary: String {
        func count(_ n: Int, _ word: String) -> String? { n > 0 ? "\(n) \(word)\(n == 1 ? "" : "s")" : nil }
        let parts = [count(walls, "wall"), count(doors, "door"), count(windows, "window"), count(doorways, "doorway"), count(stairs, "stair")].compactMap { $0 }
        return parts.joined(separator: ", ") + (rooms > 0 ? " in \(rooms) room\(rooms == 1 ? "" : "s")" : "") + "; scale \(scale)."
    }
}

/// v12.10 reads a vectorised plan photo as architecture.
///
/// - **Walls**: thick strokes when the plan inks its walls solid, else pairs of thin parallel lines.
/// - **Openings**: where a wall stops and carries on further along (or stops short of a wall across
///   its path), the band between is looked at in the photo: a quarter circle from a jamb is a door
///   swing (its hinge and side give the door's hand), lines along the band are a window, a clean gap is
///   a doorway. The wall is joined across, so rooms close.
/// - **Stairs**: five or more parallel lines of similar length at an even step.
/// - **Scale**: dimension figures matched with the lines they label, else door widths, else the
///   thickest walls, else an assumed 15 m across.
public struct PlanPhotoInterpreter: Sendable {
    public struct Options: Sendable {
        public var standardDoorWidth = 850.0
        public var exteriorWallThickness = 300.0
        public var assumedLongSide = 15_000.0
        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) { self.options = options }

    public func read(_ result: PlanPhotoVectorizer.Result, texts: [PlanPhotoReading.Text] = []) -> PlanPhotoReading {
        let ink = Ink(mask: result.ink, width: result.width, height: result.height)
        let long = Double(max(result.width, result.height))

        // Thin lines broken where the straightened photo's pixels step (or by glare) joined up again.
        let lines = UnderlayWallTracer.merged(result.lines.map { UnderlayWallTracer.Segment($0.start, $0.end) }, gap: 3, offsetTolerance: 1.5)
            .map { PlanPhotoVectorizer.Stroke(start: $0.a, end: $0.b, thickness: 1, isWall: false) }
        // Stairs first: their treads would otherwise pair up as outline walls.
        let found = stairs(in: lines)
        let treadLines = Set(found.flatMap { $0.lines })
        let thin = lines.enumerated().filter { !treadLines.contains($0.offset) }.map(\.element)

        let filledLength = result.walls.reduce(0) { $0 + $1.length }
        let style: PlanPhotoReading.WallStyle = filledLength >= long ? .filled : .outline
        var walls = style == .filled ? filledWalls(result.walls) : outlineWalls(thin, long: long)
        walls = UnderlayWallTracer.joined(walls, padding: 2).filter { $0.length >= $0.thickness }

        let gaps = self.gaps(walls, ink: ink, style: style, long: long)
        let windowsAlong = style == .outline ? outlineWindows(walls, ink: ink) : []

        // Scale: dimensions, doors, walls, or an assumption.
        let medianThickness = Self.weightedPercentile(walls.map { ($0.thickness, $0.length) }, 0.5) ?? 0
        let plausible: (Double) -> Bool = { scale in
            medianThickness <= 0 || (60...600).contains(medianThickness * scale)
        }
        var scale = options.assumedLongSide / long
        var source = PlanPhotoReading.ScaleSource.assumed
        let doorWidths = gaps.flatMap { $0.stretches.filter { $0.detail?.kind == .door }.map { $0.width / ($0.detail!.isDouble ? 2 : 1) } }
        if let (value, count) = dimensionScale(texts: texts, lines: lines, plausible: plausible) {
            scale = value; source = .dimensions(count)
        } else if !doorWidths.isEmpty, let median = Self.weightedPercentile(doorWidths.map { ($0, 1) }, 0.5),
                  plausible(options.standardDoorWidth / median) {
            scale = options.standardDoorWidth / median; source = .doors(doorWidths.count)
        } else if let thick = Self.weightedPercentile(walls.map { ($0.thickness, $0.length) }, 0.85), thick > 0 {
            scale = options.exteriorWallThickness / thick; source = .wallThickness
        }

        // Join walls across the gaps that read as openings at that scale.
        let built = bridge(walls, gaps: gaps, extraOpenings: windowsAlong, millimetresPerPixel: scale)
        let flights = found.map { $0.stair }.filter { stair in
            let tread = stair.length / Double(max(1, stair.treads - 1))
            return (150...420).contains(tread * scale) && (550...2_200).contains(stair.width * scale)
        }
        return PlanPhotoReading(walls: built.walls, openings: built.openings, stairs: flights, texts: texts, wallStyle: style,
                                millimetresPerPixel: scale, scaleSource: source, width: result.width, height: result.height)
    }

    // MARK: Ink

    struct Ink {
        let mask: [Bool]
        let width: Int
        let height: Int

        /// Ink at a point in y-up pixels.
        func at(_ p: Point2D) -> Bool {
            let x = Int(p.x.rounded(.down)), row = Int((Double(height) - p.y).rounded(.down))
            guard !mask.isEmpty, x >= 0, x < width, row >= 0, row < height else { return false }
            return mask[row * width + x]
        }

        func near(_ p: Point2D, radius: Int) -> Bool {
            for dy in -radius...radius {
                for dx in -radius...radius where at(Point2D(x: p.x + Double(dx), y: p.y + Double(dy))) { return true }
            }
            return false
        }

        /// Across the band of a wall at `p` (normal `n`, `half` either side): how much is ink, and how many
        /// separate lines of ink it crosses.
        func profile(at p: Point2D, normal n: Point2D, half: Double) -> (fraction: Double, runs: Int) {
            var inkSamples = 0, samples = 0, runs = 0, previous = false
            var t = -half
            while t <= half + 1e-9 {
                let value = at(p + n * t)
                if value { inkSamples += 1; if !previous { runs += 1 } }
                previous = value
                samples += 1
                t += 0.5
            }
            return (samples > 0 ? Double(inkSamples) / Double(samples) : 0, runs)
        }
    }

    // MARK: Walls

    /// Thick strokes as walls, broken pieces of one wall joined.
    func filledWalls(_ strokes: [PlanPhotoVectorizer.Stroke]) -> [TracedWall] {
        var walls = strokes.map { TracedWall(start: $0.start, end: $0.end, thickness: $0.thickness) }
        var merged = true
        while merged {
            merged = false
            search: for i in walls.indices {
                for j in walls.indices where j > i {
                    if let joined = Self.collinearUnion(walls[i], walls[j], gap: max(2, 0.3 * min(walls[i].thickness, walls[j].thickness))) {
                        walls[i] = joined
                        walls.remove(at: j)
                        merged = true
                        break search
                    }
                }
            }
        }
        // A line inside a wall's band (a window's glass line running on into the wall either side) reads
        // as a thin wall over the thick one: it is part of the thick wall, not a wall of its own.
        return walls.filter { a in
            let u = a.direction
            let covered = walls.reduce(0.0) { sum, b in
                guard b.thickness >= 1.5 * a.thickness, abs(UnderlayWallTracer.cross(u, b.direction)) < 0.05,
                      abs(UnderlayWallTracer.cross(b.direction, a.start - b.start)) <= b.thickness / 2 + 1 else { return sum }
                let b0 = (b.start - a.start).dot(u), b1 = (b.end - a.start).dot(u)
                return sum + max(0, min(a.length, max(b0, b1)) - max(0, min(b0, b1)))
            }
            return covered < 0.5 * a.length
        }
    }

    /// Two collinear walls that touch or overlap, as one.
    static func collinearUnion(_ a: TracedWall, _ b: TracedWall, gap: Double) -> TracedWall? {
        let u = a.direction
        let t = max(a.thickness, b.thickness)
        guard abs(UnderlayWallTracer.cross(u, b.direction)) < 0.05,
              abs(UnderlayWallTracer.cross(u, b.start - a.start)) <= max(2, 0.35 * t),
              abs(UnderlayWallTracer.cross(u, b.end - a.start)) <= max(2, 0.35 * t),
              max(a.thickness, b.thickness) <= 1.6 * min(a.thickness, b.thickness) + 2 else { return nil }
        let b0 = (b.start - a.start).dot(u), b1 = (b.end - a.start).dot(u)
        guard min(b0, b1) <= a.length + gap, max(b0, b1) >= -gap else { return nil }
        let low = min(0, b0, b1), high = max(a.length, b0, b1)
        let thickness = (a.thickness * a.length + b.thickness * b.length) / max(1e-9, a.length + b.length)
        return TracedWall(start: a.start + u * low, end: a.start + u * high, thickness: thickness)
    }

    /// Walls drawn as two thin faces, paired as the drawing tracer pairs them.
    func outlineWalls(_ lines: [PlanPhotoVectorizer.Stroke], long: Double) -> [TracedWall] {
        var tracer = UnderlayWallTracer(segments: lines.map { UnderlayWallTracer.Segment($0.start, $0.end) })
        tracer.minThickness = max(3, long * 0.002)
        tracer.maxThickness = long * 0.025
        tracer.minLength = max(8, long * 0.02)
        tracer.joinPadding = 2
        return tracer.traceAll().walls
    }

    // MARK: Openings

    /// A stretch of a gap: from `low` to `high` along the wall's direction from the free end, and what
    /// it reads as (nil: a doorway, or nothing if too wide).
    struct Stretch {
        var low: Double
        var high: Double
        var detail: UnderlayWallTracer.OpeningDetail?
        var width: Double { high - low }
    }

    /// Where a wall stops and something carries on further along its line.
    struct Gap {
        var wall: Int
        var atEnd: Bool
        /// The collinear wall across the gap, or the wall the gap closes against and the point on its axis.
        var partner: Int
        var reach: Point2D
        var collinear: Bool
        var length: Double
        var stretches: [Stretch]
    }

    func gaps(_ walls: [TracedWall], ink: Ink, style: PlanPhotoReading.WallStyle, long: Double) -> [Gap] {
        var result: [Gap] = []
        var pairs = Set<[Int]>()
        for (i, wall) in walls.enumerated() {
            for atEnd in [false, true] {
                let e = atEnd ? wall.end : wall.start
                let d = atEnd ? wall.direction : wall.direction * -1
                let t = wall.thickness
                // A free end only: not already against another wall.
                if walls.enumerated().contains(where: { k, other in k != i && Self.distance(e, toSegment: other) <= other.thickness / 2 + t / 2 + 2 }) { continue }
                var best: (k: Int, length: Double, reach: Point2D, collinear: Bool)?
                for (k, other) in walls.enumerated() where k != i {
                    let v = other.direction
                    if abs(UnderlayWallTracer.cross(d, v)) < 0.05 {
                        // Carries on along the same line.
                        guard abs(UnderlayWallTracer.cross(d, other.start - e)) <= max(2, 0.35 * max(t, other.thickness)),
                              max(t, other.thickness) <= 1.8 * min(t, other.thickness) + 2 else { continue }
                        let near = min((other.start - e).dot(d), (other.end - e).dot(d))
                        guard near > 1 else { continue }
                        if best == nil || near < best!.length { best = (k, near, e + d * near, true) }
                    } else {
                        let denominator = UnderlayWallTracer.cross(d, v)
                        guard abs(denominator) > 0.7 else { continue }
                        let s = UnderlayWallTracer.cross(other.start - e, v) / denominator
                        let face = s - other.thickness / 2 / abs(denominator)
                        let hit = e + d * s
                        let along = (hit - other.start).dot(v)
                        guard face > 1, along >= -other.thickness / 2, along <= other.length + other.thickness / 2 else { continue }
                        if best == nil || face < best!.length { best = (k, face, hit, false) }
                    }
                }
                guard let best, best.length <= long * 0.3, best.length >= max(3, 0.8 * t) else { continue }
                if best.collinear, !pairs.insert([min(i, best.k), max(i, best.k)]).inserted { continue }
                let stretches = self.stretches(from: e, direction: d, length: best.length, thickness: t, ink: ink, style: style)
                result.append(Gap(wall: i, atEnd: atEnd, partner: best.k, reach: best.reach, collinear: best.collinear,
                                  length: best.length, stretches: stretches))
            }
        }
        return result
    }

    static func distance(_ p: Point2D, toSegment wall: TracedWall) -> Double {
        let u = wall.direction
        let t = min(max(0, (p - wall.start).dot(u)), wall.length)
        return (p - (wall.start + u * t)).length
    }

    /// Walks the wall's band from its free end: stretches where no wall is drawn, each read as a door,
    /// a window or a doorway.
    func stretches(from e: Point2D, direction d: Point2D, length: Double, thickness t: Double, ink: Ink,
                   style: PlanPhotoReading.WallStyle) -> [Stretch] {
        let n = Point2D(x: -d.y, y: d.x)
        func wallDrawn(at s: Double) -> Bool {
            let p = e + d * s
            switch style {
            case .filled:
                return ink.profile(at: p, normal: n, half: max(1, t / 2 - 1)).fraction >= 0.7
            case .outline:
                let faces = [t / 2, -t / 2].allSatisfy { offset in (-1...1).contains { ink.at(p + n * (offset + Double($0))) } }
                return faces && ink.profile(at: p, normal: n, half: max(1, t / 2 - 2)).runs == 0
            }
        }
        var result: [Stretch] = []
        var start: Double?
        var s = 0.5
        while s < length {
            let drawn = wallDrawn(at: s)
            if !drawn, start == nil { start = s - 0.5 }
            if drawn, let low = start {
                if s - low >= max(2, 0.4 * t) { result.append(Stretch(low: low, high: s, detail: nil)) }
                start = nil
            }
            s += 1
        }
        if let low = start, length - low >= max(2, 0.4 * t) { result.append(Stretch(low: low, high: length, detail: nil)) }
        return result.map { stretch in
            var stretch = stretch
            let a = e + d * stretch.low, b = e + d * stretch.high
            stretch.detail = classify(from: a, to: b, thickness: t, ink: ink)
            return stretch
        }
    }

    /// A door if a swing is drawn from either jamb, a window if lines run along the band, else nil.
    func classify(from a: Point2D, to b: Point2D, thickness t: Double, ink: Ink) -> UnderlayWallTracer.OpeningDetail? {
        let w = (b - a).length
        guard w > 2 else { return nil }
        let u = (b - a).normalized, n = Point2D(x: -u.y, y: u.x)
        let radius = max(1, Int((0.03 * w).rounded()))
        /// Share of a quarter circle from `hinge` (closing towards `towards`, opening to `side`) that is inked.
        func swing(hinge: Point2D, towards: Point2D, side: Point2D, leaf: Double) -> Double {
            var hits = 0, count = 0
            for degrees in stride(from: 15.0, through: 80, by: 5) {
                let angle = degrees * .pi / 180
                let p = hinge + (towards * cos(angle) + side * sin(angle)) * leaf
                if ink.near(p, radius: radius) { hits += 1 }
                count += 1
            }
            // A filled or hatched area is not a swing: inside the arc stays mostly clear.
            var inside = 0, insideCount = 0
            for degrees in stride(from: 30.0, through: 60, by: 10) {
                let angle = degrees * .pi / 180
                if ink.near(hinge + (towards * cos(angle) + side * sin(angle)) * (leaf * 0.55), radius: 0) { inside += 1 }
                insideCount += 1
            }
            return Double(inside) / Double(insideCount) > 0.5 ? 0 : Double(hits) / Double(count)
        }
        var best: (score: Double, hingeAtEnd: Bool, left: Bool)?
        for hingeAtEnd in [false, true] {
            for left in [true, false] {
                let hinge = hingeAtEnd ? b : a
                let score = swing(hinge: hinge, towards: hingeAtEnd ? u * -1 : u, side: left ? n : n * -1, leaf: w)
                if best == nil || score > best!.score { best = (score, hingeAtEnd, left) }
            }
        }
        if let best, best.score >= 0.7 {
            return UnderlayWallTracer.OpeningDetail(kind: .door, hingeAtEnd: best.hingeAtEnd, opensToLeft: best.left)
        }
        for left in [true, false] {
            let side = left ? n : n * -1
            if swing(hinge: a, towards: u, side: side, leaf: w / 2) >= 0.7, swing(hinge: b, towards: u * -1, side: side, leaf: w / 2) >= 0.7 {
                return UnderlayWallTracer.OpeningDetail(kind: .door, hingeAtEnd: nil, opensToLeft: left, isDouble: true)
            }
        }
        // Window: glazing lines along the band through most of the gap.
        var lined = 0, samples = 0
        for k in 1...9 {
            let p = a + u * (w * Double(k) / 10)
            let profile = ink.profile(at: p, normal: n, half: t / 2 + 1)
            if profile.runs >= 1, profile.fraction < 0.7 { lined += 1 }
            samples += 1
        }
        if Double(lined) / Double(samples) >= 0.7 { return UnderlayWallTracer.OpeningDetail(kind: .window) }
        return nil
    }

    /// Windows in outline walls: stretches where glazing lines run between the two faces.
    func outlineWindows(_ walls: [TracedWall], ink: Ink) -> [(a: Point2D, b: Point2D, detail: UnderlayWallTracer.OpeningDetail)] {
        var result: [(a: Point2D, b: Point2D, detail: UnderlayWallTracer.OpeningDetail)] = []
        for wall in walls {
            let u = wall.direction, n = Point2D(x: -u.y, y: u.x), t = wall.thickness
            guard t >= 6 else { continue }
            var stretches: [(Double, Double)] = []
            var start: Double?
            var s = 1.0
            while s < wall.length {
                let glazed = ink.profile(at: wall.start + u * s, normal: n, half: t / 2 - 2).runs >= 1
                if glazed, start == nil { start = s }
                if !glazed, let low = start { stretches.append((low, s)); start = nil }
                s += 1
            }
            if let low = start { stretches.append((low, wall.length)) }
            let total = stretches.reduce(0) { $0 + $1.1 - $1.0 }
            // Hatching fills the whole wall; a window is part of it.
            guard total < 0.7 * wall.length else { continue }
            for (low, high) in stretches where high - low >= 1.5 * t {
                result.append((wall.start + u * low, wall.start + u * high, UnderlayWallTracer.OpeningDetail(kind: .window)))
            }
        }
        return result
    }

    /// Joins walls across gaps whose stretches read as openings at `millimetresPerPixel`, and places
    /// the openings on the joined walls.
    func bridge(_ input: [TracedWall], gaps: [Gap], extraOpenings: [(a: Point2D, b: Point2D, detail: UnderlayWallTracer.OpeningDetail)],
                millimetresPerPixel scale: Double) -> (walls: [TracedWall], openings: [TracedOpening]) {
        var walls = input
        var parent = Array(walls.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        var removed = Set<Int>()
        var openings: [(a: Point2D, b: Point2D, detail: UnderlayWallTracer.OpeningDetail)] = extraOpenings
        for gap in gaps {
            let e = gap.atEnd ? input[gap.wall].end : input[gap.wall].start
            let d = gap.atEnd ? input[gap.wall].direction : input[gap.wall].direction * -1
            // Every stretch must read as something an opening can be at this scale.
            var accepted: [(a: Point2D, b: Point2D, detail: UnderlayWallTracer.OpeningDetail)] = []
            // A gap with no stretch is wall drawn all the way (a stroke broken by glare).
            var ok = true
            for stretch in gap.stretches {
                let mm = stretch.width * scale
                let detail: UnderlayWallTracer.OpeningDetail
                if let found = stretch.detail {
                    let range: ClosedRange<Double> = found.kind == .door ? 450...2_400 : 300...6_000
                    guard range.contains(mm) else { ok = false; break }
                    detail = found
                } else {
                    guard (550...2_600).contains(mm) else { ok = false; break }
                    detail = UnderlayWallTracer.OpeningDetail(kind: .opening)
                }
                accepted.append((e + d * stretch.low, e + d * stretch.high, detail))
            }
            guard ok else { continue }
            if gap.collinear {
                let a = root(gap.wall), b = root(gap.partner)
                guard a != b, let joined = Self.collinearUnion(walls[a], walls[b], gap: gap.length + 2) else { continue }
                walls[a] = joined
                parent[b] = a
                removed.insert(b)
            } else {
                // Carry the wall on to the axis of the wall it closes against.
                let r = root(gap.wall)
                var extended = walls[r]
                if gap.atEnd { extended.end = gap.reach } else { extended.start = gap.reach }
                guard extended.length > walls[r].length else { continue }
                walls[r] = extended
            }
            openings += accepted
        }
        let kept = walls.indices.filter { !removed.contains($0) && parent[$0] == $0 }.map { walls[$0] }
        var placed: [TracedOpening] = []
        for opening in openings {
            let c = (opening.a + opening.b) * 0.5
            guard let index = kept.firstIndex(where: { w in
                abs(UnderlayWallTracer.cross(w.direction, c - w.start)) <= w.thickness / 2 + 2
                    && (c - w.start).dot(w.direction) >= 0 && (c - w.start).dot(w.direction) <= w.length
                    && abs(UnderlayWallTracer.cross(w.direction, (opening.b - opening.a).normalized)) < 0.1
            }) else { continue }
            let w = kept[index]
            let low = (opening.a - w.start).dot(w.direction), high = (opening.b - w.start).dot(w.direction)
            let detail = high >= low ? opening.detail : opening.detail.reversed
            placed.append(TracedOpening(kind: detail.kind, wallIndex: index, offset: (low + high) / 2, width: abs(high - low),
                                        hingeAtEnd: detail.hingeAtEnd, opensToLeft: detail.opensToLeft, isDouble: detail.isDouble))
        }
        return (kept, placed)
    }

    // MARK: Stairs

    /// Runs of five or more parallel lines of similar length, evenly stepped, side by side.
    func stairs(in lines: [PlanPhotoVectorizer.Stroke]) -> [(stair: PlanPhotoReading.Stair, lines: [Int])] {
        var used = Set<Int>()
        var found: [(stair: PlanPhotoReading.Stair, lines: [Int])] = []
        let order = lines.indices.sorted { lines[$0].length > lines[$1].length }
        for seed in order where !used.contains(seed) {
            let s = lines[seed]
            let u = (s.end - s.start).normalized, n = Point2D(x: -u.y, y: u.x)
            let origin = s.start
            func interval(_ line: PlanPhotoVectorizer.Stroke) -> (Double, Double) {
                let t0 = (line.start - origin).dot(u), t1 = (line.end - origin).dot(u)
                return (min(t0, t1), max(t0, t1))
            }
            let seedInterval = interval(s)
            var members = lines.indices.filter { k in
                guard !used.contains(k) else { return false }
                let line = lines[k]
                // Treads may be broken in a photo: a piece at least half the seed's length, lying alongside it.
                guard abs(UnderlayWallTracer.cross(u, (line.end - line.start).normalized)) < 0.05,
                      line.length >= 0.5 * s.length, line.length <= 1.25 * s.length else { return false }
                let (low, high) = interval(line)
                return min(high, seedInterval.1) - max(low, seedInterval.0) >= 0.8 * min(line.length, s.length)
            }.map { k in (k, (lines[k].start - origin).dot(n)) }.sorted { $0.1 < $1.1 }
            // Merge doubles (both edges of one thick tread line).
            members = members.reduce(into: []) { result, member in
                if let last = result.last, member.1 - last.1 < 2 { return }
                result.append(member)
            }
            // The longest evenly stepped run through the seed.
            guard let at = members.firstIndex(where: { $0.0 == seed }) else { continue }
            var low = at, high = at
            func step(_ i: Int, _ j: Int) -> Double { members[j].1 - members[i].1 }
            var pitch: Double?
            while true {
                var grown = false
                if high + 1 < members.count {
                    let next = step(high, high + 1)
                    if pitch == nil || abs(next - pitch!) <= 0.25 * pitch! {
                        high += 1; grown = true
                        pitch = step(low, high) / Double(high - low)
                    }
                }
                if low > 0 {
                    let previous = step(low - 1, low)
                    if pitch == nil || abs(previous - pitch!) <= 0.25 * pitch! {
                        low -= 1; grown = true
                        pitch = step(low, high) / Double(high - low)
                    }
                }
                if !grown { break }
            }
            let count = high - low + 1
            guard count >= 5, let pitch, pitch >= 0.08 * s.length, pitch <= 0.6 * s.length else { continue }
            let chosen = members[low...high].map(\.0)
            let along = chosen.map { interval(lines[$0]) }
            let first = along.map(\.0).min() ?? 0, last = along.map(\.1).max() ?? s.length
            let across = (members[low].1 + members[high].1) / 2
            let length = members[high].1 - members[low].1
            found.append((PlanPhotoReading.Stair(center: origin + u * ((first + last) / 2) + n * across, runDirection: n,
                                                 width: last - first, length: length, treads: count), chosen))
            used.formUnion(chosen)
        }
        // A grid (tiles, a table) is lines both ways over the same place: not stairs.
        return found.filter { candidate in
            !found.contains { other in
                other.stair.center != candidate.stair.center
                    && abs(candidate.stair.runDirection.dot(other.stair.runDirection)) < 0.3
                    && (other.stair.center - candidate.stair.center).length < 0.5 * max(candidate.stair.length, candidate.stair.width)
            }
        }
    }

    // MARK: Scale

    /// Millimetres per pixel from dimension figures and the lines they sit on, with the number of
    /// figures that agree; nil when none agree with plausible walls.
    func dimensionScale(texts: [PlanPhotoReading.Text], lines: [PlanPhotoVectorizer.Stroke],
                        plausible: (Double) -> Bool) -> (Double, Int)? {
        var candidates: [(text: Int, scale: Double)] = []
        for (index, text) in texts.enumerated() {
            let values = Self.dimensionValues(text.string)
            guard !values.isEmpty else { continue }
            let textWidth = text.height * 0.55 * Double(text.string.count)
            var best: (line: PlanPhotoVectorizer.Stroke, distance: Double)?
            for line in lines {
                let u = (line.end - line.start).normalized
                guard abs(u.y) < 0.15, line.length >= max(textWidth * 1.2, text.height * 3) else { continue }
                let distance = abs(UnderlayWallTracer.cross(u, text.position - line.start))
                let along = (text.position - line.start).dot(u)
                guard distance <= text.height * 2.5 + 2, along >= 0.1 * line.length, along <= 0.9 * line.length else { continue }
                if best == nil || distance < best!.distance { best = (line, distance) }
            }
            guard let line = best?.line else { continue }
            for value in values { candidates.append((index, value / line.length)) }
        }
        guard !candidates.isEmpty else { return nil }
        var best: (scale: Double, support: Int)?
        for candidate in candidates where plausible(candidate.scale) {
            let agreeing = candidates.filter { abs($0.scale - candidate.scale) <= 0.06 * candidate.scale }
            let support = Set(agreeing.map(\.text)).count
            let mean = agreeing.map(\.scale).reduce(0, +) / Double(agreeing.count)
            if best == nil || support > best!.support { best = (mean, support) }
        }
        guard let best, best.support >= 2 || Set(candidates.map(\.text)).count == 1 else { return nil }
        return (best.scale, best.support)
    }

    /// The lengths, in millimetres, a dimension figure may mean: "3500" (mm), "350" (cm or mm),
    /// "3.50" / "3,50" / "3.5 m" (m), "12'-6\"" (feet and inches). Areas and words are not dimensions.
    public static func dimensionValues(_ raw: String) -> [Double] {
        let text = raw.lowercased().replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty, !text.contains("²"), !text.hasSuffix("m2"), !text.contains("x") else { return [] }
        // Feet and inches.
        if text.contains("'") {
            let parts = text.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
            guard let feet = Double(parts[0]) else { return [] }
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "-\"″”")) : ""
            let inches = rest.isEmpty ? 0 : Double(rest) ?? -1
            guard inches >= 0, inches < 12 else { return [] }
            return [(feet * 12 + inches) * 25.4]
        }
        var unit: Double?
        var number = text
        for (suffix, factor) in [("mm", 1.0), ("cm", 10), ("m", 1_000)] where number.hasSuffix(suffix) {
            unit = factor
            number = String(number.dropLast(suffix.count))
            break
        }
        let hasDecimal = number.contains(".") || number.contains(",")
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")), value > 0 else { return [] }
        if let unit { return [value * unit] }
        if hasDecimal { return value < 100 ? [value * 1_000] : [] }
        if value >= 1_000 { return [value] }
        if value >= 100 { return [value, value * 10] }
        if value >= 30 { return [value * 10] }
        return []
    }

    /// The value below which `fraction` of the weight lies.
    static func weightedPercentile(_ values: [(value: Double, weight: Double)], _ fraction: Double) -> Double? {
        let sorted = values.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var seen = 0.0
        for entry in sorted {
            seen += entry.weight
            if seen >= fraction * total { return entry.value }
        }
        return sorted.last?.value
    }
}
