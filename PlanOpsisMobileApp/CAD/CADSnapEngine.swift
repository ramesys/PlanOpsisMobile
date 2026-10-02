import Foundation

public enum CADSnapKind: String, Hashable, Sendable, CaseIterable, Identifiable {
    case endpoint
    case midpoint
    case intersection
    case center
    case quadrant
    case perpendicular
    case nearest
    case insertion
    case node

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .endpoint: return "Endpoint"
        case .midpoint: return "Midpoint"
        case .intersection: return "Intersection"
        case .center: return "Centre"
        case .quadrant: return "Quadrant"
        case .perpendicular: return "Perpendicular"
        case .nearest: return "Nearest"
        case .insertion: return "Insertion"
        case .node: return "Node"
        }
    }

    /// Snap kinds on by default; Nearest is opt-in because it captures almost any tap.
    public static let standard: Set<CADSnapKind> = [.endpoint, .midpoint, .intersection, .center, .quadrant, .perpendicular, .insertion, .node]

    init(_ key: CADKeyPointKind) {
        switch key {
        case .endpoint: self = .endpoint
        case .midpoint: self = .midpoint
        case .center: self = .center
        case .quadrant: self = .quadrant
        case .insertion: self = .insertion
        case .node: self = .node
        }
    }

    /// Among point snaps at similar distance, the more specific one wins.
    var weight: Double {
        switch self {
        case .endpoint, .intersection: return 0.8
        case .center, .node, .insertion: return 0.9
        case .midpoint, .quadrant: return 1.0
        case .perpendicular: return 1.0
        case .nearest: return 1.0
        }
    }
}

public struct CADSnap: Hashable, Sendable {
    public var point: Point2D
    public var kind: CADSnapKind
    /// Scene item the snap belongs to (the first one for intersections).
    public var itemID: Int?

    public init(point: Point2D, kind: CADSnapKind, itemID: Int?) {
        self.point = point
        self.kind = kind
        self.itemID = itemID
    }
}

/// A snappable piece of geometry: a straight segment or a true arc.
public enum CADSnapCurve: Hashable, Sendable {
    case segment(Point2D, Point2D)
    case arc(CADSceneArc)
}

/// v12.3 object snaps over a `CADScene`, as in CAD programs: point snaps (endpoint, midpoint, centre,
/// quadrant, insertion, node, intersection) beat perpendicular, which beats nearest.
///
/// The engine is pure: the caller converts its pick radius from screen points to drawing units.
public struct CADSnapEngine: Sendable {
    public var kinds: Set<CADSnapKind>
    /// Cap on segments considered for intersections near the cursor.
    public var maxIntersectionSegments: Int

    public init(kinds: Set<CADSnapKind> = CADSnapKind.standard, maxIntersectionSegments: Int = 600) {
        self.kinds = kinds
        self.maxIntersectionSegments = maxIntersectionSegments
    }

    public func snap(at cursor: Point2D, radius: Double, in scene: CADScene, hiddenLayers: Set<String> = [], from origin: Point2D? = nil) -> CADSnap? {
        guard radius > 0, !kinds.isEmpty else { return nil }
        let window = CADRect(minX: cursor.x - radius, minY: cursor.y - radius, maxX: cursor.x + radius, maxY: cursor.y + radius)
        let candidates = scene.items(in: window, hiddenLayers: hiddenLayers).filter(\.isSnappable)
        return snap(at: cursor, radius: radius, candidates: candidates, window: window, from: origin)
    }

    /// Snap against an explicit candidate list (used by the plan editor with its own geometry).
    public func snap(at cursor: Point2D, radius: Double, candidates: [CADSceneItem], window: CADRect, from origin: Point2D? = nil) -> CADSnap? {
        var best: (snap: CADSnap, score: Double)?
        func consider(_ point: Point2D, _ kind: CADSnapKind, _ item: Int?) {
            guard kinds.contains(kind) else { return }
            let distance = (point - cursor).length
            guard distance <= radius else { return }
            let score = distance * kind.weight
            if best == nil || score < best!.score { best = (CADSnap(point: point, kind: kind, itemID: item), score) }
        }

        for item in candidates {
            for key in item.keyPoints { consider(key.point, CADSnapKind(key.kind), item.id) }
        }

        var curves: [(curve: CADSnapCurve, item: Int)] = []
        for item in candidates {
            for curve in Self.curves(of: item, near: window) { curves.append((curve, item.id)) }
        }
        if kinds.contains(.intersection) {
            let limited = curves.prefix(maxIntersectionSegments)
            let list = Array(limited)
            for i in 0..<list.count {
                for j in (i + 1)..<max(i + 1, list.count) {
                    // Adjacent pieces of one polyline meet at a vertex, which is already an endpoint.
                    if list[i].item == list[j].item, case .segment = list[i].curve, case .segment = list[j].curve, j == i + 1 { continue }
                    for p in Self.intersections(list[i].curve, list[j].curve) where window.contains(p) {
                        consider(p, .intersection, list[i].item)
                    }
                }
            }
        }
        if best != nil { return best?.snap }

        if kinds.contains(.perpendicular), let origin {
            for (curve, item) in curves {
                if let foot = Self.perpendicularFoot(from: origin, to: curve, near: cursor) { consider(foot, .perpendicular, item) }
            }
            if best != nil { return best?.snap }
        }
        if kinds.contains(.nearest) {
            for (curve, item) in curves { consider(Self.nearestPoint(on: curve, to: cursor), .nearest, item) }
        }
        return best?.snap
    }

    // MARK: Geometry

    /// The item's snappable curves overlapping `window`. True arcs are returned whole for exact results.
    public static func curves(of item: CADSceneItem, near window: CADRect) -> [CADSnapCurve] {
        if let arc = item.arc { return [.arc(arc)] }
        var result: [CADSnapCurve] = []
        func add(_ a: Point2D, _ b: Point2D) {
            let r = CADRect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
            if r.intersects(window) { result.append(.segment(a, b)) }
        }
        switch item.shape {
        case let .path(points, closed):
            guard points.count >= 2 else { break }
            for i in 0..<(points.count - 1) { add(points[i], points[i + 1]) }
            if closed, points.count > 2 { add(points[points.count - 1], points[0]) }
        case let .segments(points):
            var i = 0
            while i + 1 < points.count { add(points[i], points[i + 1]); i += 2 }
        case let .fill(loops):
            for loop in loops where loop.count >= 2 {
                for i in 0..<loop.count { add(loop[i], loop[(i + 1) % loop.count]) }
            }
        case .text, .point:
            break
        }
        return result
    }

    public static func nearestPoint(on curve: CADSnapCurve, to p: Point2D) -> Point2D {
        switch curve {
        case let .segment(a, b):
            let ab = b - a
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            guard lengthSquared > 1e-24 else { return a }
            let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
            return a + ab * t
        case let .arc(arc):
            let v = p - arc.center
            let onCircle = arc.center + (v.length > 1e-12 ? v.normalized : Point2D(x: 1, y: 0)) * arc.radius
            if arc.containsAngle(of: onCircle) { return onCircle }
            let ends = [arc.start, arc.start + arc.sweep].map { Point2D(x: arc.center.x + arc.radius * cos($0), y: arc.center.y + arc.radius * sin($0)) }
            return (ends[0] - p).length <= (ends[1] - p).length ? ends[0] : ends[1]
        }
    }

    /// Foot of the perpendicular from `origin` onto the curve, if it lies on the curve.
    public static func perpendicularFoot(from origin: Point2D, to curve: CADSnapCurve, near cursor: Point2D) -> Point2D? {
        switch curve {
        case let .segment(a, b):
            let ab = b - a
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            guard lengthSquared > 1e-24 else { return nil }
            let t = ((origin.x - a.x) * ab.x + (origin.y - a.y) * ab.y) / lengthSquared
            guard t >= -1e-9, t <= 1 + 1e-9 else { return nil }
            return a + ab * t
        case let .arc(arc):
            let v = origin - arc.center
            guard v.length > 1e-12 else { return nil }
            let u = v.normalized
            let options = [arc.center + u * arc.radius, arc.center - u * arc.radius].filter(arc.containsAngle(of:))
            return options.min { ($0 - cursor).length < ($1 - cursor).length }
        }
    }

    public static func intersections(_ first: CADSnapCurve, _ second: CADSnapCurve) -> [Point2D] {
        switch (first, second) {
        case let (.segment(a, b), .segment(c, d)):
            return segmentIntersection(a, b, c, d).map { [$0] } ?? []
        case let (.segment(a, b), .arc(arc)), let (.arc(arc), .segment(a, b)):
            return segmentArcIntersections(a, b, arc)
        case let (.arc(p), .arc(q)):
            return arcArcIntersections(p, q)
        }
    }

    static func segmentIntersection(_ a: Point2D, _ b: Point2D, _ c: Point2D, _ d: Point2D) -> Point2D? {
        let r = b - a, s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 * max(1, r.length * s.length) else { return nil }
        let w = c - a
        let t = (w.x * s.y - w.y * s.x) / denominator
        let u = (w.x * r.y - w.y * r.x) / denominator
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return a + r * t
    }

    static func segmentArcIntersections(_ a: Point2D, _ b: Point2D, _ arc: CADSceneArc) -> [Point2D] {
        let d = b - a, f = a - arc.center
        let qa = d.x * d.x + d.y * d.y
        guard qa > 1e-24 else { return [] }
        let qb = 2 * (f.x * d.x + f.y * d.y)
        let qc = f.x * f.x + f.y * f.y - arc.radius * arc.radius
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        let ts = discriminant == 0 ? [-qb / (2 * qa)] : [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)]
        return ts.filter { $0 >= -1e-9 && $0 <= 1 + 1e-9 }.map { a + d * $0 }.filter(arc.containsAngle(of:))
    }

    static func arcArcIntersections(_ p: CADSceneArc, _ q: CADSceneArc) -> [Point2D] {
        let v = q.center - p.center
        let distance = v.length
        guard distance > 1e-12, distance <= p.radius + q.radius + 1e-9, distance >= abs(p.radius - q.radius) - 1e-9 else { return [] }
        let a = (p.radius * p.radius - q.radius * q.radius + distance * distance) / (2 * distance)
        let h = max(0, p.radius * p.radius - a * a).squareRoot()
        let mid = p.center + v * (a / distance)
        let n = Point2D(x: -v.y / distance, y: v.x / distance)
        let points = h < 1e-12 ? [mid] : [mid + n * h, mid - n * h]
        return points.filter { p.containsAngle(of: $0) && q.containsAngle(of: $0) }
    }
}

// MARK: - Picking

public enum CADPicker {
    /// The visible item under `point`: nearest stroke within `radius`, else the topmost fill or text
    /// containing the point.
    public static func pick(at point: Point2D, radius: Double, in scene: CADScene, hiddenLayers: Set<String> = []) -> CADSceneItem? {
        let window = CADRect(minX: point.x - radius, minY: point.y - radius, maxX: point.x + radius, maxY: point.y + radius)
        let candidates = scene.items(in: window, hiddenLayers: hiddenLayers)
        var best: (item: CADSceneItem, distance: Double)?
        for item in candidates {
            let distance: Double?
            switch item.shape {
            case .path, .segments:
                distance = CADSnapEngine.curves(of: item, near: window).map { (CADSnapEngine.nearestPoint(on: $0, to: point) - point).length }.min()
            case let .point(p):
                distance = (p - point).length
            case .fill, .text:
                distance = nil
            }
            if let distance, distance <= radius, best == nil || distance <= best!.distance { best = (item, distance) }
        }
        if let best { return best.item }
        for item in candidates.reversed() {
            switch item.shape {
            case let .fill(loops):
                if CADMeasurement.contains(point, loops: loops) { return item }
            case .text:
                if item.bounds.contains(point) { return item }
            default:
                break
            }
        }
        return nil
    }
}
