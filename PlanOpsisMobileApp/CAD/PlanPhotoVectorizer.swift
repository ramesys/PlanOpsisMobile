import Foundation

/// v12.9 an 8-bit grey image, row by row from the top; 0 is black.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "GrayImage needs width × height pixels")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// v12.9 turns a photo or scan of a plan into line work.
///
/// The image is made black and white against its local brightness (so shadows and uneven light do not
/// matter), straightened by the angle that lines its ink up best with rows and columns, and read as
/// horizontal and vertical strokes: runs of ink row by row (and column by column) that continue with the
/// same ends are one stroke, as thick as the rows it spans. Thick strokes are walls; thin ones are the
/// plan's other lines. Text, hatching and specks are too short to count. Coordinates are pixels with y up,
/// origin at the image's bottom-left, so the result sits under the plan like a drawing.
public struct PlanPhotoVectorizer: Sendable {
    public struct Options: Sendable {
        /// Strokes shorter than this share of the image's long side are text, hatching or noise.
        public var minimumLineFraction = 0.025
        /// Local brightness window, as a share of the long side.
        public var windowFraction = 1.0 / 24
        /// Ink is this much darker than its surroundings.
        public var darkness = 0.15
        /// Straightening searched up to this angle either way.
        public var maximumSkewDegrees = 6.0
        /// Strokes at least this thick (share of the long side, and at least 4 px) are walls.
        public var wallThicknessFraction = 0.0035
        /// Strokes thicker than this share are filled areas (legends, title blocks), not lines.
        public var maximumThicknessFraction = 0.04
        public init() {}
    }

    public struct Stroke: Hashable, Sendable {
        public var start: Point2D
        public var end: Point2D
        /// Pixels.
        public var thickness: Double
        public var isWall: Bool
        public var length: Double { (end - start).length }
    }

    public struct Result: Sendable {
        public var strokes: [Stroke]
        /// The rotation corrected, degrees counter-clockwise.
        public var skewDegrees: Double
        public var width: Int
        public var height: Int
        public var walls: [Stroke] { strokes.filter(\.isWall) }
        public var lines: [Stroke] { strokes.filter { !$0.isWall } }
    }

    public var options: Options

    public init(options: Options = Options()) { self.options = options }

    public func vectorize(_ image: GrayImage) -> Result {
        let mask = binarize(image)
        let skew = estimateSkew(mask, width: image.width, height: image.height)
        let straight = abs(skew) < 0.05 ? mask : rotate(mask, width: image.width, height: image.height, degrees: -skew)
        var strokes = runs(straight, width: image.width, height: image.height)
        if abs(skew) >= 0.05 {
            // Back onto the photo as taken.
            let centre = Point2D(x: Double(image.width) / 2, y: Double(image.height) / 2)
            let turn = PlanSimilarity.rotation(skew * .pi / 180, about: centre)
            strokes = strokes.map { Stroke(start: turn.apply($0.start), end: turn.apply($0.end), thickness: $0.thickness, isWall: $0.isWall) }
        }
        return Result(strokes: strokes, skewDegrees: skew, width: image.width, height: image.height)
    }

    // MARK: Black and white

    /// Ink where a pixel is darker than its neighbourhood's mean by `darkness` (Bradley's method on an
    /// integral image), and darker than mid-grey's upper half, so flat paper never reads as ink. Pixels
    /// at half the paper's brightness or darker are ink outright, so a solid black area is ink right
    /// through rather than an outline.
    public func binarize(_ image: GrayImage) -> [Bool] {
        let w = image.width, h = image.height
        var histogram = [Int](repeating: 0, count: 256)
        for value in image.pixels { histogram[Int(value)] += 1 }
        var paper = 255, seen = 0
        for value in (0..<256).reversed() {
            seen += histogram[value]
            // The brightest tenth is paper.
            if seen >= image.pixels.count / 10 { paper = value; break }
        }
        let solid = Double(paper) * 0.5
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += Int(image.pixels[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let half = max(7, Int(Double(max(w, h)) * options.windowFraction) / 2)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - half), y1 = min(h, y + half + 1)
            for x in 0..<w {
                let x0 = max(0, x - half), x1 = min(w, x + half + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
                let value = Double(image.pixels[y * w + x])
                mask[y * w + x] = value < solid || (value < mean * (1 - options.darkness) && value < 192)
            }
        }
        return mask
    }

    // MARK: Straightening

    /// The small rotation that makes ink line up with rows and columns best: the angle whose row and
    /// column histograms of ink are most peaked.
    public func estimateSkew(_ mask: [Bool], width: Int, height: Int) -> Double {
        var points: [(Double, Double)] = []
        let total = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard total > 0 else { return 0 }
        let every = max(1, total / 80_000)
        var seen = 0
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                if seen % every == 0 { points.append((Double(x), Double(y))) }
                seen += 1
            }
        }
        let cx = Double(width) / 2, cy = Double(height) / 2
        let bins = 2 * (width + height)
        func score(_ degrees: Double) -> Double {
            let a = degrees * .pi / 180, c = cos(a), s = sin(a)
            var rows = [Int](repeating: 0, count: bins), cols = [Int](repeating: 0, count: bins)
            for (x, y) in points {
                let dx = x - cx, dy = y - cy
                let rx = Int((dx * c - dy * s).rounded()) + bins / 2, ry = Int((dx * s + dy * c).rounded()) + bins / 2
                if rx >= 0, rx < bins { cols[rx] += 1 }
                if ry >= 0, ry < bins { rows[ry] += 1 }
            }
            return Double(rows.reduce(0) { $0 + $1 * $1 } + cols.reduce(0) { $0 + $1 * $1 })
        }
        var best = (angle: 0.0, score: score(0))
        var angle = -options.maximumSkewDegrees
        while angle <= options.maximumSkewDegrees + 1e-9 {
            let value = score(angle)
            if value > best.score * 1.0001 { best = (angle, value) }
            angle += 0.25
        }
        // Refine around the best quarter degree.
        for step in stride(from: best.angle - 0.2, through: best.angle + 0.2, by: 0.05) {
            let value = score(step)
            if value > best.score * 1.0001 { best = (step, value) }
        }
        // Scoring rotates image coordinates (rows down), so the best angle is the photo's own turn in
        // y-up plan terms.
        return best.angle
    }

    /// The mask turned by `degrees` (counter-clockwise in y-up terms) about its centre.
    func rotate(_ mask: [Bool], width: Int, height: Int, degrees: Double) -> [Bool] {
        // Image rows run down, so a counter-clockwise turn in plan terms is clockwise in image terms.
        let a = -degrees * .pi / 180, c = cos(a), s = sin(a)
        let cx = Double(width) / 2, cy = Double(height) / 2
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                // Inverse rotation to find the source pixel.
                let sx = Int((dx * c + dy * s + cx).rounded()), sy = Int((-dx * s + dy * c + cy).rounded())
                if sx >= 0, sx < width, sy >= 0, sy < height { out[y * width + x] = mask[sy * width + sx] }
            }
        }
        return out
    }

    // MARK: Strokes

    func runs(_ mask: [Bool], width: Int, height: Int) -> [Stroke] {
        let long = Double(max(width, height))
        let minimum = max(8, Int(long * options.minimumLineFraction))
        let wallPixels = max(4, long * options.wallThicknessFraction)
        let maximumThickness = max(wallPixels * 2, long * options.maximumThicknessFraction)
        func toPlan(_ x: Double, _ y: Double) -> Point2D { Point2D(x: x, y: Double(height) - y) }

        var strokes: [Stroke] = []
        // Horizontal strokes: runs along rows; vertical strokes: the same along columns.
        for horizontal in [true, false] {
            let lines = horizontal ? height : width, along = horizontal ? width : height
            struct Building { var start: Int; var end: Int; var first: Int; var last: Int; var sumStart: Int; var sumEnd: Int; var count: Int }
            var active: [Building] = []
            var done: [Building] = []
            for line in 0..<lines {
                var segments: [(Int, Int)] = []
                var i = 0
                while i < along {
                    let ink = horizontal ? mask[line * width + i] : mask[i * width + line]
                    if ink {
                        let s = i
                        while i < along, horizontal ? mask[line * width + i] : mask[i * width + line] { i += 1 }
                        if i - s >= minimum { segments.append((s, i - 1)) }
                    } else {
                        i += 1
                    }
                }
                var stillActive: [Building] = []
                var used = [Bool](repeating: false, count: segments.count)
                let tolerance = 3 + Int(Double(minimum) * 0.05)
                for var stroke in active {
                    if let k = segments.indices.first(where: { !used[$0] && abs(segments[$0].0 - stroke.start) <= tolerance && abs(segments[$0].1 - stroke.end) <= tolerance }) {
                        used[k] = true
                        stroke.start = segments[k].0
                        stroke.end = segments[k].1
                        stroke.last = line
                        stroke.sumStart += segments[k].0
                        stroke.sumEnd += segments[k].1
                        stroke.count += 1
                        stillActive.append(stroke)
                    } else if line - stroke.last <= 1 {
                        // One missing row of ink (a speck of glare) does not break a stroke.
                        stillActive.append(stroke)
                    } else {
                        done.append(stroke)
                    }
                }
                for (k, segment) in segments.enumerated() where !used[k] {
                    stillActive.append(Building(start: segment.0, end: segment.1, first: line, last: line,
                                                sumStart: segment.0, sumEnd: segment.1, count: 1))
                }
                active = stillActive
            }
            done += active
            for stroke in done {
                guard Double(stroke.last - stroke.first + 1) <= maximumThickness else { continue }
                let a = Double(stroke.sumStart) / Double(stroke.count), b = Double(stroke.sumEnd) / Double(stroke.count) + 1
                // Thickness from the ink around the stroke, so ragged edge rows (a straightened photo's
                // staircase) still count: ink pixels within its extent, two rows either side, per length.
                var inkCount = 0
                let from = Int(a.rounded()), to = Int(b.rounded())
                for line in max(0, stroke.first - 2)...min(lines - 1, stroke.last + 2) where to > from {
                    for i in from..<min(to, along) where horizontal ? mask[line * width + i] : mask[i * width + line] { inkCount += 1 }
                }
                let thickness = max(Double(stroke.last - stroke.first + 1), Double(inkCount) / max(1, b - a))
                let middle = Double(stroke.first + stroke.last + 1) / 2
                let start = horizontal ? toPlan(a, middle) : toPlan(middle, a)
                let end = horizontal ? toPlan(b, middle) : toPlan(middle, b)
                strokes.append(Stroke(start: start, end: end, thickness: thickness, isWall: thickness >= wallPixels))
            }
        }
        return strokes
    }

    // MARK: Drawing

    /// The PlanOpsis semantic layers a photo's line work goes on, named as `naming` names them, so a
    /// photo reads like any other PlanOpsis drawing: walls on the wall layer (IfcWall / A-WALL), the
    /// plan's other lines as annotation (IfcAnnotation / A-ANNO), recognised text as room annotation
    /// (IfcAnnotation / A-ANNO-ROOM).
    public static func wallLayer(_ naming: DXFLayerNaming = .ifcClass) -> String { ArchitecturalDraftingConvention.Layer.wall.dxfName(naming) }
    public static func lineLayer(_ naming: DXFLayerNaming = .ifcClass) -> String { ArchitecturalDraftingConvention.Layer.annotation.dxfName(naming) }
    public static func textLayer(_ naming: DXFLayerNaming = .ifcClass) -> String { ArchitecturalDraftingConvention.Layer.roomAnnotation.dxfName(naming) }

    /// The strokes as a drawing in pixels (y up): walls as their two faces (without end caps, which
    /// would pair up into stubs where walls meet), other lines as centre lines, recognised text for room
    /// names, on PlanOpsis's semantic layers. Built with the internal (discipline) names by default:
    /// they keep room text apart from other annotation, and `CADDocumentDXFWriter` writes them in
    /// whichever naming the user exports with.
    public static func document(from result: Result, texts: [(position: Point2D, string: String, height: Double)] = [],
                                layerNaming naming: DXFLayerNaming = .discipline) -> CADDocument {
        let wallLayer = wallLayer(naming), lineLayer = lineLayer(naming), textLayer = textLayer(naming)
        var entities: [CADEntity] = []
        for stroke in result.strokes {
            if stroke.isWall {
                let u = (stroke.end - stroke.start).normalized
                let n = Point2D(x: -u.y, y: u.x) * (stroke.thickness / 2)
                entities.append(CADEntity(type: "LINE", layer: wallLayer, geometry: .line(stroke.start + n, stroke.end + n)))
                entities.append(CADEntity(type: "LINE", layer: wallLayer, geometry: .line(stroke.start - n, stroke.end - n)))
            } else {
                entities.append(CADEntity(type: "LINE", layer: lineLayer, geometry: .line(stroke.start, stroke.end)))
            }
        }
        for text in texts where !text.string.trimmingCharacters(in: .whitespaces).isEmpty {
            entities.append(CADEntity(type: "TEXT", layer: textLayer,
                                      geometry: .text(CADText(position: text.position, height: text.height, string: text.string, horizontal: .center, vertical: .middle))))
        }
        var layers: [CADLayer] = []
        for name in [wallLayer, lineLayer, textLayer] where !layers.contains(where: { $0.name == name }) { layers.append(CADLayer(name: name)) }
        return CADDocument(units: .unitless, layers: layers, entities: entities)
    }
}
