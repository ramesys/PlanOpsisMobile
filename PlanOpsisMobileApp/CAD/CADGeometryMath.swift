import Foundation

/// 2D affine transform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
public struct CADAffine: Hashable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = CADAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ p: Point2D) -> CADAffine { CADAffine(a: 1, b: 0, c: 0, d: 1, tx: p.x, ty: p.y) }
    public static func rotation(_ angle: Double) -> CADAffine { CADAffine(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0) }
    public static func scale(_ sx: Double, _ sy: Double) -> CADAffine { CADAffine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    public static let mirrorX = CADAffine(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public func apply(_ p: Point2D) -> Point2D {
        Point2D(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    /// Applies only the linear part, for direction vectors.
    public func applyVector(_ v: Point2D) -> Point2D {
        Point2D(x: a * v.x + c * v.y, y: b * v.x + d * v.y)
    }

    /// `self ∘ other`: applies `other` first.
    public func concatenating(_ other: CADAffine) -> CADAffine {
        CADAffine(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            tx: a * other.tx + c * other.ty + tx,
            ty: b * other.tx + d * other.ty + ty
        )
    }

    public var determinant: Double { a * d - b * c }
    public var isMirrored: Bool { determinant < 0 }
    /// Geometric-mean scale; exact for similarity transforms.
    public var uniformScale: Double { sqrt(abs(determinant)) }
    /// Rotation of the X axis.
    public var rotation: Double { atan2(b, a) }

    /// True when circles stay circles (uniform scale, no shear), possibly mirrored.
    public var isSimilarity: Bool {
        let sx = hypot(a, b), sy = hypot(c, d)
        guard sx > 1e-12, sy > 1e-12 else { return false }
        return abs(sx - sy) <= 1e-9 * max(sx, sy) && abs(a * c + b * d) <= 1e-9 * sx * sy
    }
}

/// Axis-aligned rectangle in drawing units.
public struct CADRect: Hashable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init?(points: [Point2D]) {
        guard let first = points.first else { return nil }
        var r = CADRect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() { r.include(p) }
        self = r
    }

    public static let empty = CADRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var isEmpty: Bool { !(minX <= maxX && minY <= maxY) }
    public var width: Double { max(0, maxX - minX) }
    public var height: Double { max(0, maxY - minY) }
    public var center: Point2D { Point2D(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }

    public mutating func include(_ p: Point2D) {
        guard p.x.isFinite, p.y.isFinite else { return }
        minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }

    public func union(_ other: CADRect) -> CADRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return CADRect(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    public func intersects(_ other: CADRect) -> Bool {
        !isEmpty && !other.isEmpty && minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
    }

    public func contains(_ p: Point2D) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func contains(_ other: CADRect) -> Bool {
        !other.isEmpty && other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func expanded(by amount: Double) -> CADRect {
        isEmpty ? self : CADRect(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }

    /// The `FloorGeometry` the plan camera fits to.
    public var floorGeometry: FloorGeometry? {
        isEmpty ? nil : FloorGeometry(min: Point2D(x: minX, y: minY), max: Point2D(x: maxX, y: maxY))
    }
}

/// Curve flattening shared by the reader (hatch edges) and the scene builder.
public enum CADTessellation {
    /// Segments for a sweep: 128 per full turn, at least 4 and at most 256.
    static func segmentCount(sweep: Double) -> Int {
        min(256, max(4, Int((abs(sweep) / (2 * .pi) * 128).rounded(.up))))
    }

    /// Circular arc from `start` through signed `sweep` (radians, positive counter-clockwise), endpoints included.
    public static func arc(center: Point2D, radius: Double, start: Double, sweep: Double) -> [Point2D] {
        let n = segmentCount(sweep: sweep)
        return (0...n).map { i in
            let t = start + sweep * Double(i) / Double(n)
            return Point2D(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    /// Counter-clockwise sweep from `start` to `end`, in (0, 2π].
    public static func ccwSweep(from start: Double, to end: Double) -> Double {
        var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep <= 1e-12 { sweep += 2 * .pi }
        return sweep
    }

    /// Elliptical arc by parameter. Counter-clockwise from `start` to `end` unless `clockwise`.
    public static func ellipse(center: Point2D, majorAxis: Point2D, ratio: Double, start: Double, end: Double, clockwise: Bool = false) -> [Point2D] {
        let minor = Point2D(x: -majorAxis.y * ratio, y: majorAxis.x * ratio)
        let sweep = clockwise ? -ccwSweep(from: end, to: start) : ccwSweep(from: start, to: end)
        let n = segmentCount(sweep: sweep)
        return (0...n).map { i in
            let t = start + sweep * Double(i) / Double(n)
            return Point2D(x: center.x + majorAxis.x * cos(t) + minor.x * sin(t), y: center.y + majorAxis.y * cos(t) + minor.y * sin(t))
        }
    }

    /// The arc a polyline bulge describes between `a` and `b`, or nil for a straight segment.
    public static func bulgeArc(from a: Point2D, to b: Point2D, bulge: Double) -> (center: Point2D, radius: Double, start: Double, sweep: Double)? {
        let chord = b - a
        let length = chord.length
        guard abs(bulge) > 1e-9, length > 1e-12, bulge.isFinite else { return nil }
        let sweep = 4 * atan(bulge)
        let mid = Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let left = Point2D(x: -chord.y / length, y: chord.x / length)
        let offset = length / 2 * (1 - bulge * bulge) / (2 * bulge)
        let center = mid + left * offset
        let radius = (a - center).length
        return (center, radius, atan2(a.y - center.y, a.x - center.x), sweep)
    }

    /// Polyline points with bulged segments flattened; the closing segment is included when closed.
    public static func polyline(_ polyline: CADPolyline) -> [Point2D] {
        let v = polyline.vertices
        guard v.count >= 2 else { return v.map(\.point) }
        var points: [Point2D] = [v[0].point]
        let segmentCount = polyline.closed ? v.count : v.count - 1
        for i in 0..<segmentCount {
            let a = v[i], b = v[(i + 1) % v.count]
            if let arc = bulgeArc(from: a.point, to: b.point, bulge: a.bulge) {
                points.append(contentsOf: Self.arc(center: arc.center, radius: arc.radius, start: arc.start, sweep: arc.sweep).dropFirst())
            } else {
                points.append(b.point)
            }
        }
        return points
    }

    /// NURBS evaluation by de Boor; fit-point-only splines are drawn through their fit points.
    public static func spline(_ spline: CADSpline) -> [Point2D] {
        let control = spline.controlPoints
        guard control.count >= 2 else { return catmullRom(spline.fitPoints, closed: spline.closed) }
        let p = max(1, min(spline.degree, control.count - 1))
        var knots = spline.knots
        if knots.count != control.count + p + 1 {
            // Clamped uniform knots when the file's vector is missing or inconsistent.
            let inner = max(0, control.count - p - 1)
            knots = Array(repeating: 0, count: p + 1) + (0..<inner).map { Double($0 + 1) / Double(inner + 1) } + Array(repeating: 1, count: p + 1)
        }
        let weights = spline.weights.count == control.count ? spline.weights : Array(repeating: 1, count: control.count)
        let lo = knots[p], hi = knots[control.count]
        guard hi > lo else { return control }
        let samples = min(512, max(16, control.count * 10))
        return (0...samples).map { i in
            let u = lo + (hi - lo) * Double(i) / Double(samples)
            return deBoor(u: min(u, hi - 1e-12 * max(1, abs(hi))), degree: p, knots: knots, control: control, weights: weights)
        }
    }

    private static func deBoor(u: Double, degree p: Int, knots: [Double], control: [Point2D], weights: [Double]) -> Point2D {
        var k = p
        while k + 1 < control.count, u >= knots[k + 1] { k += 1 }
        // Homogeneous control points.
        var d: [(x: Double, y: Double, w: Double)] = (0...p).map { j in
            let i = k - p + j
            let w = weights[i]
            return (control[i].x * w, control[i].y * w, w)
        }
        if p >= 1 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = k - p + j
                    let denominator = knots[i + p - r + 1] - knots[i]
                    let alpha = denominator == 0 ? 0 : (u - knots[i]) / denominator
                    d[j] = ((1 - alpha) * d[j - 1].x + alpha * d[j].x, (1 - alpha) * d[j - 1].y + alpha * d[j].y, (1 - alpha) * d[j - 1].w + alpha * d[j].w)
                }
            }
        }
        let w = d[p].w == 0 ? 1 : d[p].w
        return Point2D(x: d[p].x / w, y: d[p].y / w)
    }

    /// Centripetal-free Catmull-Rom through `points` (8 samples per span).
    public static func catmullRom(_ points: [Point2D], closed: Bool) -> [Point2D] {
        guard points.count >= 3 else { return points }
        let n = points.count
        func at(_ i: Int) -> Point2D {
            if closed { return points[((i % n) + n) % n] }
            return points[max(0, min(n - 1, i))]
        }
        var result: [Point2D] = [points[0]]
        let spans = closed ? n : n - 1
        for i in 0..<spans {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            for s in 1...8 {
                let t = Double(s) / 8, t2 = t * t, t3 = t2 * t
                let x = 0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                result.append(Point2D(x: x, y: y))
            }
        }
        return result
    }
}
