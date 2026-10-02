import Foundation

/// v12.3 general drawing model for viewing any DXF, not only PlanOpsis exports.
///
/// `DXFExchangeEngine` reads a PlanOpsis drawing back into the semantic model and deliberately ignores
/// everything it cannot map. `CADDocument` is the opposite: a faithful, read-only description of what a
/// DXF contains (layers, blocks, model-space entities) so the viewer can show drawings from Rhino,
/// AutoCAD or an architect. Coordinates are in drawing units, Y up, projected to the XY plane.
public struct CADDocument: Sendable {
    public var version: String?
    public var units: CADUnits
    /// Layers in table order.
    public var layers: [CADLayer]
    public var blocks: [String: CADBlock]
    /// Model-space entities in file order. Paper-space entities are not included.
    public var entities: [CADEntity]
    public var diagnostics: CADReadDiagnostics

    public init(
        version: String? = nil,
        units: CADUnits = .unitless,
        layers: [CADLayer] = [],
        blocks: [String: CADBlock] = [:],
        entities: [CADEntity] = [],
        diagnostics: CADReadDiagnostics = CADReadDiagnostics()
    ) {
        self.version = version
        self.units = units
        self.layers = layers
        self.blocks = blocks
        self.entities = entities
        self.diagnostics = diagnostics
    }

    /// The layer record for `name`, or a default white, visible layer when the table does not define it.
    public func layer(named name: String) -> CADLayer {
        layers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? CADLayer(name: name)
    }
}

/// $INSUNITS. Only the units a building drawing plausibly uses are named; anything else is `.other`.
public enum CADUnits: Hashable, Sendable {
    case unitless
    case inches
    case feet
    case millimetres
    case centimetres
    case metres
    case other(Int)

    public init(insunits code: Int) {
        switch code {
        case 0: self = .unitless
        case 1: self = .inches
        case 2: self = .feet
        case 4: self = .millimetres
        case 5: self = .centimetres
        case 6: self = .metres
        default: self = .other(code)
        }
    }

    /// Millimetres per drawing unit, when the unit is known.
    public var millimetresPerUnit: Double? {
        switch self {
        case .inches: return 25.4
        case .feet: return 304.8
        case .millimetres: return 1
        case .centimetres: return 10
        case .metres: return 1000
        case .unitless, .other: return nil
        }
    }

    public var symbol: String {
        switch self {
        case .unitless: return "units"
        case .inches: return "in"
        case .feet: return "ft"
        case .millimetres: return "mm"
        case .centimetres: return "cm"
        case .metres: return "m"
        case .other: return "units"
        }
    }
}

public struct CADColor: Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// DXF true colour (group 420): 0x00RRGGBB.
    public init(trueColor value: Int) {
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    public static let white = CADColor(red: 255, green: 255, blue: 255)
    public static let black = CADColor(red: 0, green: 0, blue: 0)

    /// True for ACI 7 ("white"), which CAD programs draw as black on a light background.
    public var isWhite: Bool { red == 255 && green == 255 && blue == 255 }

    /// The AutoCAD Colour Index palette. Indices 1–9 and 250–255 are the fixed CAD colours; 10–249 follow
    /// AutoCAD's hue wheel (24 hues × 5 brightness levels × full and half saturation).
    public static func aci(_ index: Int) -> CADColor {
        switch index {
        case 1: return CADColor(red: 255, green: 0, blue: 0)
        case 2: return CADColor(red: 255, green: 255, blue: 0)
        case 3: return CADColor(red: 0, green: 255, blue: 0)
        case 4: return CADColor(red: 0, green: 255, blue: 255)
        case 5: return CADColor(red: 0, green: 0, blue: 255)
        case 6: return CADColor(red: 255, green: 0, blue: 255)
        case 7: return .white
        case 8: return CADColor(red: 128, green: 128, blue: 128)
        case 9: return CADColor(red: 192, green: 192, blue: 192)
        case 250...255:
            let greys: [UInt8] = [51, 91, 132, 173, 214, 255]
            let g = greys[index - 250]
            return CADColor(red: g, green: g, blue: g)
        case 10...249:
            let hue = Double((index - 10) / 10) * 15
            let shade = (index - 10) % 10
            let brightness = [1.0, 1.0, 0.8, 0.8, 0.6, 0.6, 0.5, 0.5, 0.3, 0.3][shade]
            let saturation = shade % 2 == 0 ? 1.0 : 0.5
            return hsv(hue: hue, saturation: saturation, value: brightness)
        default:
            return .white
        }
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> CADColor {
        let h = (hue.truncatingRemainder(dividingBy: 360)) / 60
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, ((v + m) * 255).rounded()))) }
        return CADColor(red: byte(r), green: byte(g), blue: byte(b))
    }
}

/// An entity's colour as written: resolved against its layer or the inserting block when drawn.
public enum CADColorReference: Hashable, Sendable {
    case byLayer
    case byBlock
    case index(Int)
    case rgb(CADColor)
}

/// An entity's line weight as written (group 370, hundredths of a millimetre).
public enum CADLineWeight: Hashable, Sendable {
    case byLayer
    case byBlock
    case `default`
    case hundredthsMM(Int)

    public init(code: Int) {
        switch code {
        case -1: self = .byLayer
        case -2: self = .byBlock
        case let value where value >= 0: self = .hundredthsMM(value)
        default: self = .default
        }
    }
}

public struct CADLayer: Hashable, Sendable, Identifiable {
    public var name: String
    public var color: CADColor
    /// ACI index of the layer colour (positive), used to recognise ACI 7.
    public var colorIndex: Int
    /// Layer "on" state (a negative colour number in the table means off).
    public var isOn: Bool
    public var isFrozen: Bool
    public var isLocked: Bool
    public var isPlotted: Bool
    public var lineType: String
    public var lineWeight: CADLineWeight

    public var id: String { name }

    public init(
        name: String,
        color: CADColor = .white,
        colorIndex: Int = 7,
        isOn: Bool = true,
        isFrozen: Bool = false,
        isLocked: Bool = false,
        isPlotted: Bool = true,
        lineType: String = "CONTINUOUS",
        lineWeight: CADLineWeight = .default
    ) {
        self.name = name
        self.color = color
        self.colorIndex = colorIndex
        self.isOn = isOn
        self.isFrozen = isFrozen
        self.isLocked = isLocked
        self.isPlotted = isPlotted
        self.lineType = lineType
        self.lineWeight = lineWeight
    }

    /// Visible when the drawing opens: on and not frozen.
    public var isInitiallyVisible: Bool { isOn && !isFrozen }
}

public struct CADBlock: Sendable {
    public var name: String
    public var basePoint: Point2D
    public var entities: [CADEntity]

    public init(name: String, basePoint: Point2D = .zero, entities: [CADEntity] = []) {
        self.name = name
        self.basePoint = basePoint
        self.entities = entities
    }
}

public struct CADEntity: Sendable {
    public var type: String
    public var handle: String?
    public var layer: String
    public var color: CADColorReference
    public var lineWeight: CADLineWeight
    public var lineType: String?
    public var geometry: CADGeometry
    /// Extended data by application name, e.g. the PlanOpsis UUIDs written on exported entities.
    public var xdata: [String: [String]]

    public init(
        type: String,
        handle: String? = nil,
        layer: String = "0",
        color: CADColorReference = .byLayer,
        lineWeight: CADLineWeight = .byLayer,
        lineType: String? = nil,
        geometry: CADGeometry,
        xdata: [String: [String]] = [:]
    ) {
        self.type = type
        self.handle = handle
        self.layer = layer
        self.color = color
        self.lineWeight = lineWeight
        self.lineType = lineType
        self.geometry = geometry
        self.xdata = xdata
    }
}

/// A polyline vertex; `bulge` is the tangent of a quarter of the included angle of the arc to the next
/// vertex (0 = straight, positive = counter-clockwise).
public struct CADVertex: Hashable, Sendable {
    public var point: Point2D
    public var bulge: Double

    public init(_ point: Point2D, bulge: Double = 0) {
        self.point = point
        self.bulge = bulge
    }
}

public struct CADPolyline: Hashable, Sendable {
    public var vertices: [CADVertex]
    public var closed: Bool

    public init(vertices: [CADVertex], closed: Bool) {
        self.vertices = vertices
        self.closed = closed
    }
}

public enum CADTextHorizontalAlignment: Hashable, Sendable {
    case left
    case center
    case right
}

public enum CADTextVerticalAlignment: Hashable, Sendable {
    case baseline
    case bottom
    case middle
    case top
}

public struct CADText: Hashable, Sendable {
    /// The anchor the alignment refers to, in drawing units.
    public var position: Point2D
    public var height: Double
    /// Counter-clockwise, radians.
    public var rotation: Double
    /// Plain text; MTEXT formatting codes are removed and paragraph breaks become newlines.
    public var string: String
    public var horizontal: CADTextHorizontalAlignment
    public var vertical: CADTextVerticalAlignment
    public var widthFactor: Double

    public init(
        position: Point2D,
        height: Double,
        rotation: Double = 0,
        string: String,
        horizontal: CADTextHorizontalAlignment = .left,
        vertical: CADTextVerticalAlignment = .baseline,
        widthFactor: Double = 1
    ) {
        self.position = position
        self.height = height
        self.rotation = rotation
        self.string = string
        self.horizontal = horizontal
        self.vertical = vertical
        self.widthFactor = widthFactor
    }
}

public struct CADInsert: Hashable, Sendable {
    public var blockName: String
    public var position: Point2D
    public var scaleX: Double
    public var scaleY: Double
    /// Radians.
    public var rotation: Double
    public var columns: Int
    public var rows: Int
    public var columnSpacing: Double
    public var rowSpacing: Double
    /// ATTRIB values drawn with the insert, in drawing coordinates.
    public var attributes: [CADText]
    /// True when the insert's extrusion is (0, 0, -1): the whole block is mirrored about the Y axis.
    public var mirrored: Bool

    public init(
        blockName: String,
        position: Point2D,
        scaleX: Double = 1,
        scaleY: Double = 1,
        rotation: Double = 0,
        columns: Int = 1,
        rows: Int = 1,
        columnSpacing: Double = 0,
        rowSpacing: Double = 0,
        attributes: [CADText] = [],
        mirrored: Bool = false
    ) {
        self.blockName = blockName
        self.position = position
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotation = rotation
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.attributes = attributes
        self.mirrored = mirrored
    }
}

public enum CADDimensionKind: Int, Hashable, Sendable {
    case linear = 0
    case aligned = 1
    case angular = 2
    case diameter = 3
    case radius = 4
    case angular3Point = 5
    case ordinate = 6
}

public struct CADDimension: Hashable, Sendable {
    public var kind: CADDimensionKind
    /// The anonymous block (`*D…`) holding the dimension's drawn geometry, when the writer provided one.
    public var blockName: String?
    /// Group 10: a point on the dimension line.
    public var dimensionLinePoint: Point2D
    /// Group 11: text middle point.
    public var textPoint: Point2D
    /// Groups 13 and 14: the measured points (linear/aligned).
    public var firstPoint: Point2D?
    public var secondPoint: Point2D?
    /// Group 50: rotation of a linear dimension, radians.
    public var rotation: Double
    /// Group 42.
    public var measurement: Double?
    /// Group 1. Empty or "<>" means the measured value.
    public var textOverride: String?

    public init(
        kind: CADDimensionKind,
        blockName: String?,
        dimensionLinePoint: Point2D,
        textPoint: Point2D,
        firstPoint: Point2D? = nil,
        secondPoint: Point2D? = nil,
        rotation: Double = 0,
        measurement: Double? = nil,
        textOverride: String? = nil
    ) {
        self.kind = kind
        self.blockName = blockName
        self.dimensionLinePoint = dimensionLinePoint
        self.textPoint = textPoint
        self.firstPoint = firstPoint
        self.secondPoint = secondPoint
        self.rotation = rotation
        self.measurement = measurement
        self.textOverride = textOverride
    }
}

/// One line family of a hatch pattern, already scaled and rotated as stored in the HATCH entity.
public struct CADHatchPatternLine: Hashable, Sendable {
    /// Radians.
    public var angle: Double
    public var basePoint: Point2D
    /// Offset between successive lines of the family.
    public var offset: Point2D
    /// Dash lengths: positive = drawn, negative = gap, zero = dot. Empty = continuous.
    public var dashes: [Double]

    public init(angle: Double, basePoint: Point2D, offset: Point2D, dashes: [Double]) {
        self.angle = angle
        self.basePoint = basePoint
        self.offset = offset
        self.dashes = dashes
    }
}

public struct CADHatch: Hashable, Sendable {
    public var patternName: String
    public var isSolid: Bool
    public var loops: [CADPolyline]
    public var patternLines: [CADHatchPatternLine]

    public init(patternName: String, isSolid: Bool, loops: [CADPolyline], patternLines: [CADHatchPatternLine] = []) {
        self.patternName = patternName
        self.isSolid = isSolid
        self.loops = loops
        self.patternLines = patternLines
    }
}

public struct CADSpline: Hashable, Sendable {
    public var degree: Int
    public var knots: [Double]
    public var controlPoints: [Point2D]
    public var weights: [Double]
    public var fitPoints: [Point2D]
    public var closed: Bool

    public init(degree: Int, knots: [Double], controlPoints: [Point2D], weights: [Double] = [], fitPoints: [Point2D] = [], closed: Bool = false) {
        self.degree = degree
        self.knots = knots
        self.controlPoints = controlPoints
        self.weights = weights
        self.fitPoints = fitPoints
        self.closed = closed
    }
}

public enum CADGeometry: Sendable {
    case line(Point2D, Point2D)
    case polyline(CADPolyline)
    case circle(center: Point2D, radius: Double)
    /// Counter-clockwise from `startAngle` to `endAngle`, radians.
    case arc(center: Point2D, radius: Double, startAngle: Double, endAngle: Double)
    /// `majorAxis` is the vector from the centre to the end of the major axis; parameters in radians.
    case ellipse(center: Point2D, majorAxis: Point2D, ratio: Double, startParameter: Double, endParameter: Double)
    case spline(CADSpline)
    case text(CADText)
    case insert(CADInsert)
    case dimension(CADDimension)
    case hatch(CADHatch)
    /// SOLID, TRACE and 3DFACE corners in drawing order (SOLID's third and fourth corners are swapped
    /// back to outline order by the reader).
    case filledPolygon([Point2D])
    case point(Point2D)
    /// LEADER vertices, drawn as an open polyline with an arrowhead at the first vertex.
    case leader([Point2D])
}

/// What the reader skipped, so the viewer can say "3 PROXY entities not shown" instead of silently dropping them.
public struct CADReadDiagnostics: Hashable, Sendable {
    /// Entity type → count of entities the reader does not draw.
    public var unsupportedEntities: [String: Int]
    public var paperSpaceEntities: Int
    public var missingBlocks: Set<String>
    public var warnings: [String]

    public init(unsupportedEntities: [String: Int] = [:], paperSpaceEntities: Int = 0, missingBlocks: Set<String> = [], warnings: [String] = []) {
        self.unsupportedEntities = unsupportedEntities
        self.paperSpaceEntities = paperSpaceEntities
        self.missingBlocks = missingBlocks
        self.warnings = warnings
    }

    public var summary: [String] {
        var lines = unsupportedEntities.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key) \($0.value == 1 ? "entity" : "entities") not shown" }
        if paperSpaceEntities > 0 { lines.append("\(paperSpaceEntities) paper-space \(paperSpaceEntities == 1 ? "entity" : "entities") not shown (model space only)") }
        if !missingBlocks.isEmpty { lines.append("Missing block definitions: \(missingBlocks.sorted().joined(separator: ", "))") }
        return lines + warnings
    }
}
