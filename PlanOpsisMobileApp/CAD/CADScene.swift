import Foundation

public enum CADKeyPointKind: String, Hashable, Sendable, CaseIterable {
    case endpoint
    case midpoint
    case center
    case quadrant
    case insertion
    case node
}

public struct CADKeyPoint: Hashable, Sendable {
    public var point: Point2D
    public var kind: CADKeyPointKind

    public init(_ point: Point2D, _ kind: CADKeyPointKind) {
        self.point = point
        self.kind = kind
    }
}

/// A circle or arc that survived its block transforms as a true circle, kept for exact snapping.
public struct CADSceneArc: Hashable, Sendable {
    public var center: Point2D
    public var radius: Double
    public var start: Double
    /// Signed, radians; ±2π for a full circle.
    public var sweep: Double

    public init(center: Point2D, radius: Double, start: Double, sweep: Double) {
        self.center = center
        self.radius = radius
        self.start = start
        self.sweep = sweep
    }

    public var isFullCircle: Bool { abs(sweep) >= 2 * .pi - 1e-9 }

    /// True when the angle of `p` about the centre lies on the arc.
    public func containsAngle(of p: Point2D) -> Bool {
        if isFullCircle { return true }
        let angle = atan2(p.y - center.y, p.x - center.x)
        var delta = (sweep >= 0 ? angle - start : start - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        return delta <= abs(sweep) + 1e-9
    }
}

public struct CADSceneText: Hashable, Sendable {
    public var position: Point2D
    public var height: Double
    public var rotation: Double
    public var string: String
    public var horizontal: CADTextHorizontalAlignment
    public var vertical: CADTextVerticalAlignment
    public var widthFactor: Double
}

public enum CADShape: Sendable {
    /// Connected points; `closed` adds the closing segment.
    case path([Point2D], closed: Bool)
    /// Independent segments as consecutive point pairs (hatch pattern lines, dimension ticks).
    case segments([Point2D])
    /// Even-odd filled loops.
    case fill([[Point2D]])
    case text(CADSceneText)
    case point(Point2D)
}

/// One drawable, already in drawing coordinates.
public struct CADSceneItem: Sendable, Identifiable {
    public var id: Int
    /// Index of the model-space entity this item came from (an INSERT for block content).
    public var entityIndex: Int
    /// The innermost block this item was drawn from, nil for model-space entities.
    public var blockName: String?
    /// Effective layer: entities on layer 0 inside a block take the inserting entity's layer.
    public var layer: String
    /// Layer of the model-space entity; hiding it hides the whole insert, as in CAD programs.
    public var hostLayer: String
    public var color: CADColor
    /// Plotted line weight in millimetres; nil means the thin default.
    public var lineWeightMM: Double?
    public var shape: CADShape
    public var bounds: CADRect
    public var keyPoints: [CADKeyPoint]
    public var arc: CADSceneArc?
    /// False for hatch patterns and fills, which snaps and picks ignore.
    public var isSnappable: Bool
}

public struct CADSceneLayer: Hashable, Sendable, Identifiable {
    public var layer: CADLayer
    public var itemCount: Int
    public var id: String { layer.name }
}

/// v12.3 flattened, drawable form of a `CADDocument`: blocks expanded, curves tessellated, colours resolved.
///
/// The scene is immutable after building. Layer visibility is a view concern: the viewer passes the set
/// of hidden layers to queries instead of rebuilding.
public struct CADScene: Sendable {
    public let items: [CADSceneItem]
    public let layers: [CADSceneLayer]
    public let bounds: CADRect
    public let units: CADUnits
    public let diagnostics: CADReadDiagnostics
    public let index: CADSpatialIndex

    /// - Parameter transform: placement of the whole drawing, e.g. a unit scale and offset when a DXF is
    ///   used as an underlay below the plan.
    public init(document: CADDocument, limits: CADSceneLimits = CADSceneLimits(), transform: CADAffine = .identity) {
        var builder = CADSceneBuilder(document: document, limits: limits, root: transform)
        builder.build()
        items = builder.items
        bounds = builder.items.reduce(CADRect.empty) { $0.union($1.bounds) }
        units = document.units
        var diagnostics = document.diagnostics
        diagnostics.warnings.append(contentsOf: builder.warnings)
        self.diagnostics = diagnostics
        var counts: [String: Int] = [:]
        for item in builder.items { counts[item.layer, default: 0] += 1 }
        var seen = Set<String>()
        var layers: [CADSceneLayer] = []
        for layer in document.layers where seen.insert(layer.name).inserted {
            layers.append(CADSceneLayer(layer: layer, itemCount: counts[layer.name] ?? 0))
        }
        for name in counts.keys.sorted() where !seen.contains(name) {
            layers.append(CADSceneLayer(layer: document.layer(named: name), itemCount: counts[name] ?? 0))
        }
        self.layers = layers
        index = CADSpatialIndex(items: items, bounds: bounds)
    }

    /// Layers hidden when the drawing opens (off or frozen in the file).
    public var initiallyHiddenLayers: Set<String> {
        Set(layers.filter { !$0.layer.isInitiallyVisible }.map(\.id))
    }

    public func isVisible(_ item: CADSceneItem, hiddenLayers: Set<String>) -> Bool {
        hiddenLayers.isEmpty || (!hiddenLayers.contains(item.layer) && !hiddenLayers.contains(item.hostLayer))
    }

    /// Visible items overlapping `rect`, in drawing order.
    public func items(in rect: CADRect, hiddenLayers: Set<String>) -> [CADSceneItem] {
        index.query(rect).compactMap { i in
            let item = items[i]
            return isVisible(item, hiddenLayers: hiddenLayers) ? item : nil
        }
    }

    /// Extent of the visible items, for Fit.
    public func visibleBounds(hiddenLayers: Set<String>) -> CADRect {
        guard !hiddenLayers.isEmpty else { return bounds }
        return items.reduce(CADRect.empty) { isVisible($1, hiddenLayers: hiddenLayers) ? $0.union($1.bounds) : $0 }
    }
}

public struct CADSceneLimits: Hashable, Sendable {
    /// Block nesting deeper than this is not drawn (protects against self-referencing blocks).
    public var maxBlockDepth: Int
    /// Upper bound on drawn items; drawing stops with a warning beyond it.
    public var maxItems: Int
    /// Hatch pattern segments per hatch before falling back to a tinted fill.
    public var maxHatchSegments: Int

    public init(maxBlockDepth: Int = 16, maxItems: Int = 400_000, maxHatchSegments: Int = 20_000) {
        self.maxBlockDepth = maxBlockDepth
        self.maxItems = maxItems
        self.maxHatchSegments = maxHatchSegments
    }
}

// MARK: - Builder

private struct InsertContext {
    var transform: CADAffine
    var layer: String
    var color: CADColor
    var lineWeightMM: Double?
    var blockName: String?
    var depth: Int
    var blockStack: [String]
}

private struct CADSceneBuilder {
    let document: CADDocument
    let limits: CADSceneLimits
    var items: [CADSceneItem] = []
    var warnings: [String] = []
    var layerLookup: [String: CADLayer] = [:]
    var entityIndex = 0
    var hostLayer = "0"
    var truncated = false
    var cyclicBlocks = Set<String>()
    var simplifiedHatches = 0
    let root: CADAffine

    init(document: CADDocument, limits: CADSceneLimits, root: CADAffine) {
        self.document = document
        self.limits = limits
        self.root = root
        for layer in document.layers { layerLookup[layer.name.uppercased()] = layer }
    }

    mutating func build() {
        for (i, entity) in document.entities.enumerated() {
            entityIndex = i
            hostLayer = entity.layer
            let root = InsertContext(transform: self.root, layer: entity.layer, color: .white, lineWeightMM: nil, blockName: nil, depth: 0, blockStack: [])
            draw(entity, in: root)
            if truncated { break }
        }
        if truncated { warnings.append("The drawing is very large; only the first \(limits.maxItems) items are shown.") }
        if !cyclicBlocks.isEmpty { warnings.append("Blocks that insert themselves were not expanded: \(cyclicBlocks.sorted().joined(separator: ", ")).") }
        if simplifiedHatches > 0 { warnings.append("\(simplifiedHatches) dense hatch pattern\(simplifiedHatches == 1 ? " is" : "s are") shown as a tint.") }
    }

    func layer(_ name: String) -> CADLayer {
        layerLookup[name.uppercased()] ?? CADLayer(name: name)
    }

    // MARK: Attribute resolution

    func effectiveLayer(_ entity: CADEntity, _ context: InsertContext) -> String {
        context.depth > 0 && entity.layer == "0" ? context.layer : entity.layer
    }

    func color(_ entity: CADEntity, layer: String, _ context: InsertContext) -> CADColor {
        switch entity.color {
        case let .rgb(color): return color
        case let .index(index): return .aci(index)
        case .byBlock: return context.depth > 0 ? context.color : .white
        case .byLayer: return self.layer(layer).color
        }
    }

    func lineWeight(_ entity: CADEntity, layer: String, _ context: InsertContext) -> Double? {
        switch entity.lineWeight {
        case let .hundredthsMM(value): return Double(value) / 100
        case .byBlock: return context.depth > 0 ? context.lineWeightMM : nil
        case .default: return nil
        case .byLayer:
            if case let .hundredthsMM(value) = self.layer(layer).lineWeight { return Double(value) / 100 }
            return nil
        }
    }

    // MARK: Emission

    mutating func emit(_ shape: CADShape, keyPoints: [CADKeyPoint] = [], arc: CADSceneArc? = nil, snappable: Bool = true, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        guard !truncated else { return }
        guard items.count < limits.maxItems else { truncated = true; return }
        let bounds: CADRect
        switch shape {
        case let .path(points, _): bounds = CADRect(points: points) ?? .empty
        case let .segments(points): bounds = CADRect(points: points) ?? .empty
        case let .fill(loops): bounds = CADRect(points: loops.flatMap { $0 }) ?? .empty
        case let .point(p): bounds = CADRect(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
        case let .text(text): bounds = Self.textBounds(text)
        }
        guard !bounds.isEmpty else { return }
        items.append(CADSceneItem(
            id: items.count,
            entityIndex: entityIndex,
            blockName: context.blockName,
            layer: layer,
            hostLayer: hostLayer,
            color: color,
            lineWeightMM: weight,
            shape: shape,
            bounds: bounds,
            keyPoints: keyPoints,
            arc: arc,
            isSnappable: snappable
        ))
    }

    static func textBounds(_ text: CADSceneText) -> CADRect {
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false)
        let columns = Double(lines.map(\.count).max() ?? 0)
        let width = max(text.height, columns * text.height * 0.6 * text.widthFactor)
        let height = text.height * (1 + Double(max(0, lines.count - 1)) * 1.4)
        let x0: Double = text.horizontal == .left ? 0 : (text.horizontal == .center ? -width / 2 : -width)
        let y0: Double
        switch text.vertical {
        case .baseline: y0 = -height + text.height
        case .bottom: y0 = -height + text.height * 1.2
        case .middle: y0 = -height / 2
        case .top: y0 = -height
        }
        let corners = [Point2D(x: x0, y: y0 - text.height * 0.25), Point2D(x: x0 + width, y: y0 - text.height * 0.25), Point2D(x: x0, y: y0 + height), Point2D(x: x0 + width, y: y0 + height)]
        let r = CADAffine.translation(text.position).concatenating(.rotation(text.rotation))
        return CADRect(points: corners.map(r.apply)) ?? .empty
    }

    // MARK: Entities

    mutating func draw(_ entity: CADEntity, in context: InsertContext) {
        let layer = effectiveLayer(entity, context)
        let color = self.color(entity, layer: layer, context)
        let weight = lineWeight(entity, layer: layer, context)
        let m = context.transform
        switch entity.geometry {
        case let .line(a, b):
            let p = [m.apply(a), m.apply(b)]
            emit(.path(p, closed: false), keyPoints: [CADKeyPoint(p[0], .endpoint), CADKeyPoint(p[1], .endpoint), CADKeyPoint(Self.mid(p[0], p[1]), .midpoint)], layer: layer, color: color, weight: weight, context: context)

        case let .polyline(polyline):
            emitPolyline(polyline, transform: m, layer: layer, color: color, weight: weight, context: context)

        case let .circle(center, radius):
            emitArc(center: center, radius: radius, start: 0, sweep: 2 * .pi, transform: m, layer: layer, color: color, weight: weight, context: context)

        case let .arc(center, radius, start, end):
            emitArc(center: center, radius: radius, start: start, sweep: CADTessellation.ccwSweep(from: start, to: end), transform: m, layer: layer, color: color, weight: weight, context: context)

        case let .ellipse(center, major, ratio, start, end):
            let points = CADTessellation.ellipse(center: center, majorAxis: major, ratio: ratio, start: start, end: end).map(m.apply)
            let full = abs(CADTessellation.ccwSweep(from: start, to: end) - 2 * .pi) < 1e-9
            var keys = [CADKeyPoint(m.apply(center), .center)]
            if full {
                let minor = Point2D(x: -major.y * ratio, y: major.x * ratio)
                keys += [center + major, center - major, center + minor, center - minor].map { CADKeyPoint(m.apply($0), .quadrant) }
            } else if let first = points.first, let last = points.last {
                keys += [CADKeyPoint(first, .endpoint), CADKeyPoint(last, .endpoint)]
            }
            emit(.path(points, closed: full), keyPoints: keys, layer: layer, color: color, weight: weight, context: context)

        case let .spline(spline):
            let points = CADTessellation.spline(spline).map(m.apply)
            guard points.count >= 2 else { return }
            var keys: [CADKeyPoint] = []
            if !spline.closed, let first = points.first, let last = points.last { keys = [CADKeyPoint(first, .endpoint), CADKeyPoint(last, .endpoint)] }
            emit(.path(points, closed: spline.closed), keyPoints: keys, layer: layer, color: color, weight: weight, context: context)

        case let .text(text):
            emitText(text, transform: m, layer: layer, color: color, context: context)

        case let .insert(insert):
            drawInsert(insert, entity: entity, layer: layer, color: color, weight: weight, context: context)

        case let .dimension(dimension):
            drawDimension(dimension, entity: entity, layer: layer, color: color, weight: weight, context: context)

        case let .hatch(hatch):
            drawHatch(hatch, transform: m, layer: layer, color: color, context: context)

        case let .filledPolygon(points):
            let p = points.map(m.apply)
            emit(.fill([p]), keyPoints: p.map { CADKeyPoint($0, .endpoint) }, layer: layer, color: color, weight: weight, context: context)

        case let .point(p):
            let q = m.apply(p)
            emit(.point(q), keyPoints: [CADKeyPoint(q, .node)], layer: layer, color: color, weight: weight, context: context)

        case let .leader(points):
            let p = points.map(m.apply)
            emit(.path(p, closed: false), keyPoints: p.map { CADKeyPoint($0, .endpoint) }, layer: layer, color: color, weight: weight, context: context)
            if p.count >= 2 {
                let head = Self.arrowhead(tip: p[0], from: p[1], size: min((p[1] - p[0]).length * 0.4, Self.arrowSize(for: p)))
                emit(.fill([head]), snappable: false, layer: layer, color: color, weight: nil, context: context)
            }
        }
    }

    static func mid(_ a: Point2D, _ b: Point2D) -> Point2D { Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    mutating func emitPolyline(_ polyline: CADPolyline, transform m: CADAffine, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        let v = polyline.vertices
        guard v.count >= 2 else { return }
        var keys: [CADKeyPoint] = v.map { CADKeyPoint(m.apply($0.point), .endpoint) }
        let segmentCount = polyline.closed ? v.count : v.count - 1
        for i in 0..<segmentCount {
            let a = v[i], b = v[(i + 1) % v.count]
            if let arc = CADTessellation.bulgeArc(from: a.point, to: b.point, bulge: a.bulge) {
                let midAngle = arc.start + arc.sweep / 2
                keys.append(CADKeyPoint(m.apply(Point2D(x: arc.center.x + arc.radius * cos(midAngle), y: arc.center.y + arc.radius * sin(midAngle))), .midpoint))
                keys.append(CADKeyPoint(m.apply(arc.center), .center))
            } else {
                keys.append(CADKeyPoint(m.apply(Self.mid(a.point, b.point)), .midpoint))
            }
        }
        var points = CADTessellation.polyline(polyline).map(m.apply)
        if polyline.closed, points.count > 2, let first = points.first, let last = points.last, (first - last).length < 1e-12 { points.removeLast() }
        emit(.path(points, closed: polyline.closed), keyPoints: keys, layer: layer, color: color, weight: weight, context: context)
    }

    mutating func emitArc(center: Point2D, radius: Double, start: Double, sweep: Double, transform m: CADAffine, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        guard radius > 0 else { return }
        let full = abs(sweep) >= 2 * .pi - 1e-9
        let local = CADTessellation.arc(center: center, radius: radius, start: start, sweep: sweep)
        var points = local.map(m.apply)
        if full { points.removeLast() }
        let c = m.apply(center)
        var keys = [CADKeyPoint(c, .center)]
        var sceneArc: CADSceneArc?
        if m.isSimilarity {
            let startPoint = m.apply(local[0])
            sceneArc = CADSceneArc(center: c, radius: radius * m.uniformScale, start: atan2(startPoint.y - c.y, startPoint.x - c.x), sweep: m.isMirrored ? -sweep : sweep)
        }
        if full {
            if let arc = sceneArc {
                keys += [0.0, 0.5, 1.0, 1.5].map { k in CADKeyPoint(Point2D(x: c.x + arc.radius * cos(k * .pi), y: c.y + arc.radius * sin(k * .pi)), .quadrant) }
            } else {
                keys += [0.0, 0.5, 1.0, 1.5].map { k in CADKeyPoint(m.apply(Point2D(x: center.x + radius * cos(k * .pi), y: center.y + radius * sin(k * .pi))), .quadrant) }
            }
        } else {
            let midAngle = start + sweep / 2
            keys += [
                CADKeyPoint(points[0], .endpoint),
                CADKeyPoint(points[points.count - 1], .endpoint),
                CADKeyPoint(m.apply(Point2D(x: center.x + radius * cos(midAngle), y: center.y + radius * sin(midAngle))), .midpoint),
            ]
            if let arc = sceneArc {
                for k in 0..<4 {
                    let q = Point2D(x: c.x + arc.radius * cos(Double(k) * .pi / 2), y: c.y + arc.radius * sin(Double(k) * .pi / 2))
                    if arc.containsAngle(of: q) { keys.append(CADKeyPoint(q, .quadrant)) }
                }
            }
        }
        emit(.path(points, closed: full), keyPoints: keys, arc: sceneArc, layer: layer, color: color, weight: weight, context: context)
    }

    mutating func emitText(_ text: CADText, transform m: CADAffine, layer: String, color: CADColor, context: InsertContext) {
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let direction = m.applyVector(Point2D(x: cos(text.rotation), y: sin(text.rotation)))
        let position = m.apply(text.position)
        let scene = CADSceneText(
            position: position,
            height: text.height * m.uniformScale,
            rotation: atan2(direction.y, direction.x),
            string: text.string,
            horizontal: text.horizontal,
            vertical: text.vertical,
            widthFactor: text.widthFactor
        )
        emit(.text(scene), keyPoints: [CADKeyPoint(position, .insertion)], layer: layer, color: color, weight: nil, context: context)
    }

    // MARK: Blocks

    mutating func drawInsert(_ insert: CADInsert, entity: CADEntity, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        let ocs = insert.mirrored ? context.transform.concatenating(.mirrorX) : context.transform
        for attribute in insert.attributes {
            emitText(attribute, transform: ocs, layer: layer, color: color, context: context)
        }
        guard let block = document.blocks[insert.blockName] else { return }
        guard context.depth < limits.maxBlockDepth, !context.blockStack.contains(insert.blockName) else {
            cyclicBlocks.insert(insert.blockName)
            return
        }
        let instanceCount = insert.columns * insert.rows
        let columns = instanceCount > 10_000 ? 1 : insert.columns
        let rows = instanceCount > 10_000 ? 1 : insert.rows
        let local = CADAffine.rotation(insert.rotation)
            .concatenating(.scale(insert.scaleX, insert.scaleY))
            .concatenating(.translation(Point2D(x: -block.basePoint.x, y: -block.basePoint.y)))
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = CADAffine.rotation(insert.rotation).apply(Point2D(x: Double(column) * insert.columnSpacing, y: Double(row) * insert.rowSpacing))
                let transform = ocs.concatenating(.translation(insert.position + offset)).concatenating(local)
                let child = InsertContext(
                    transform: transform,
                    layer: layer,
                    color: color,
                    lineWeightMM: weight,
                    blockName: insert.blockName,
                    depth: context.depth + 1,
                    blockStack: context.blockStack + [insert.blockName]
                )
                for blockEntity in block.entities {
                    draw(blockEntity, in: child)
                    if truncated { return }
                }
            }
        }
        if let first = items.last, first.entityIndex == entityIndex, context.depth == 0 {
            // The insertion point snaps like CAD programs' INSertion mode; attach it to the insert's last item.
            items[items.count - 1].keyPoints.append(CADKeyPoint(ocs.apply(insert.position), .insertion))
        }
    }

    // MARK: Dimensions

    mutating func drawDimension(_ dimension: CADDimension, entity: CADEntity, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        if let name = dimension.blockName, let block = document.blocks[name], !block.entities.isEmpty, !context.blockStack.contains(name) {
            // Dimension blocks are drawn in the dimension's coordinates without a base-point offset.
            let child = InsertContext(transform: context.transform, layer: layer, color: color, lineWeightMM: weight, blockName: name, depth: context.depth + 1, blockStack: context.blockStack + [name])
            for blockEntity in block.entities { draw(blockEntity, in: child) }
            return
        }
        synthesizeDimension(dimension, layer: layer, color: color, weight: weight, context: context)
    }

    /// Linear/aligned dimensions without a geometry block are drawn from their definition points.
    mutating func synthesizeDimension(_ dimension: CADDimension, layer: String, color: CADColor, weight: Double?, context: InsertContext) {
        guard let p1 = dimension.firstPoint, let p2 = dimension.secondPoint, (p2 - p1).length > 1e-9 else { return }
        guard dimension.kind == .linear || dimension.kind == .aligned else { return }
        let m = context.transform
        let direction = dimension.kind == .aligned ? (p2 - p1).normalized : Point2D(x: cos(dimension.rotation), y: sin(dimension.rotation))
        let normal = Point2D(x: -direction.y, y: direction.x)
        let line = dimension.dimensionLinePoint
        func project(_ p: Point2D) -> Point2D {
            let t = (p.x - line.x) * direction.x + (p.y - line.y) * direction.y
            return line + direction * t
        }
        let d1 = project(p1), d2 = project(p2)
        let length = (d2 - d1).length
        let tick = length * 0.04
        let gap = length * 0.02
        func extensionLine(from p: Point2D, to d: Point2D) -> [Point2D] {
            let v = d - p
            guard v.length > gap else { return [] }
            let u = v.normalized
            return [p + u * gap, d + u * (tick * 0.8)]
        }
        var segments = extensionLine(from: p1, to: d1) + extensionLine(from: p2, to: d2) + [d1, d2]
        let slash = (direction + normal).normalized * (tick * 0.7)
        segments += [d1 - slash, d1 + slash, d2 - slash, d2 + slash]
        let worldSegments = segments.map(m.apply)
        emit(.segments(worldSegments), keyPoints: [CADKeyPoint(m.apply(d1), .endpoint), CADKeyPoint(m.apply(d2), .endpoint)], snappable: false, layer: layer, color: color, weight: weight, context: context)
        let measured = dimension.measurement ?? (dimension.kind == .aligned ? (p2 - p1).length : length)
        var label = Self.format(measured)
        if let override = dimension.textOverride, !override.isEmpty {
            label = override.contains("<>") ? override.replacingOccurrences(of: "<>", with: label) : override
        }
        var angle = atan2(direction.y, direction.x)
        if angle > .pi / 2 + 1e-9 || angle <= -.pi / 2 + 1e-9 { angle += .pi }
        let text = CADText(position: dimension.textPoint, height: max(length * 0.06, 1e-6), rotation: angle, string: label, horizontal: .center, vertical: .middle)
        emitText(text, transform: m, layer: layer, color: color, context: context)
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 1e-9 { return String(Int(rounded.rounded())) }
        return String(format: "%.2f", rounded)
    }

    static func arrowSize(for points: [Point2D]) -> Double {
        guard let r = CADRect(points: points) else { return 1 }
        return max(r.width, r.height) * 0.05
    }

    static func arrowhead(tip: Point2D, from tail: Point2D, size: Double) -> [Point2D] {
        let u = (tail - tip).normalized
        let n = Point2D(x: -u.y, y: u.x)
        let base = tip + u * size
        return [tip, base + n * (size / 3), base - n * (size / 3)]
    }

    // MARK: Hatches

    mutating func drawHatch(_ hatch: CADHatch, transform m: CADAffine, layer: String, color: CADColor, context: InsertContext) {
        let localLoops = hatch.loops.map(CADTessellation.polyline).filter { $0.count >= 3 }
        guard !localLoops.isEmpty else { return }
        let loops = localLoops.map { $0.map(m.apply) }
        if hatch.isSolid || hatch.patternLines.isEmpty {
            emit(.fill(loops), snappable: false, layer: layer, color: color, weight: nil, context: context)
            return
        }
        if let segments = Self.patternSegments(loops: localLoops, lines: hatch.patternLines, limit: limits.maxHatchSegments) {
            emit(.segments(segments.map(m.apply)), snappable: false, layer: layer, color: color, weight: nil, context: context)
        } else {
            simplifiedHatches += 1
            let tint = CADColor(red: UInt8((Int(color.red) + 255 * 3) / 4), green: UInt8((Int(color.green) + 255 * 3) / 4), blue: UInt8((Int(color.blue) + 255 * 3) / 4))
            emit(.fill(loops), snappable: false, layer: layer, color: color.isWhite ? CADColor(red: 200, green: 200, blue: 200) : tint, weight: nil, context: context)
        }
    }

    /// Clips each pattern line family to the even-odd interior of `loops` and applies its dashes.
    /// Returns nil when the pattern would need more than `limit` segments.
    static func patternSegments(loops: [[Point2D]], lines: [CADHatchPatternLine], limit: Int) -> [Point2D]? {
        guard let bounds = CADRect(points: loops.flatMap { $0 }) else { return [] }
        var edges: [(Point2D, Point2D)] = []
        for loop in loops {
            for i in 0..<loop.count { edges.append((loop[i], loop[(i + 1) % loop.count])) }
        }
        let corners = [Point2D(x: bounds.minX, y: bounds.minY), Point2D(x: bounds.maxX, y: bounds.minY), Point2D(x: bounds.minX, y: bounds.maxY), Point2D(x: bounds.maxX, y: bounds.maxY)]
        var result: [Point2D] = []
        for family in lines {
            let u = Point2D(x: cos(family.angle), y: sin(family.angle))
            let n = Point2D(x: -u.y, y: u.x)
            let spacing = family.offset.x * n.x + family.offset.y * n.y
            guard abs(spacing) > 1e-9 else { continue }
            let shift = family.offset.x * u.x + family.offset.y * u.y
            let distances = corners.map { ($0.x - family.basePoint.x) * n.x + ($0.y - family.basePoint.y) * n.y }
            let k0 = Int(((distances.min() ?? 0) / spacing).rounded(.down)), k1 = Int(((distances.max() ?? 0) / spacing).rounded(.up))
            let kRange = spacing > 0 ? (k0...k1) : (min(k1, k0)...max(k1, k0))
            if kRange.count > limit { return nil }
            let patternLength = family.dashes.reduce(0) { $0 + abs($1) }
            for k in kRange {
                let origin = family.basePoint + family.offset * Double(k)
                var hits: [Double] = []
                for (a, b) in edges {
                    let e = b - a
                    let denominator = u.x * e.y - u.y * e.x
                    guard abs(denominator) > 1e-12 else { continue }
                    let w = a - origin
                    let t = (w.x * e.y - w.y * e.x) / denominator
                    let s = (w.x * u.y - w.y * u.x) / denominator
                    // Half-open on the edge so a line through a shared vertex counts once.
                    if s >= 0 && s < 1 { hits.append(t) }
                }
                guard hits.count >= 2 else { continue }
                hits.sort()
                var i = 0
                while i + 1 < hits.count {
                    let t0 = hits[i], t1 = hits[i + 1]
                    i += 2
                    guard t1 - t0 > 1e-9 else { continue }
                    if family.dashes.isEmpty || patternLength <= 1e-12 {
                        result.append(origin + u * t0); result.append(origin + u * t1)
                    } else {
                        // The dash pattern starts at the family's origin, shifted along the line per row.
                        let phaseOrigin = shift * Double(k)
                        var start = t0 - ((t0 - phaseOrigin).truncatingRemainder(dividingBy: patternLength) + patternLength).truncatingRemainder(dividingBy: patternLength)
                        if (t1 - t0) / patternLength * Double(family.dashes.count) > Double(limit) { return nil }
                        while start < t1 {
                            for dash in family.dashes {
                                let length = abs(dash)
                                let end = start + (dash == 0 ? patternLength * 0.01 : length)
                                if dash >= 0 {
                                    let a = max(start, t0), b = min(end, t1)
                                    if b > a { result.append(origin + u * a); result.append(origin + u * b) }
                                }
                                start += length
                                if start >= t1 { break }
                            }
                        }
                    }
                    if result.count / 2 > limit { return nil }
                }
            }
        }
        return result
    }
}
