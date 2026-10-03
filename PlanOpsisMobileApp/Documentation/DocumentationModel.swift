import Foundation

/// v12.4 paper sizes, landscape, in millimetres.
public enum PaperSize: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case a4, a3, a2, a1

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }

    /// Landscape width × height.
    public var size: (width: Double, height: Double) {
        switch self {
        case .a4: return (297, 210)
        case .a3: return (420, 297)
        case .a2: return (594, 420)
        case .a1: return (841, 594)
        }
    }
}

/// A section cut drawn on the plan (A–A, B–B…).
public struct SectionLine: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var start: Point2D
    public var end: Point2D
    /// True when the section looks to the left of start → end.
    public var looksLeft: Bool

    public init(id: UUID = UUID(), label: String, start: Point2D, end: Point2D, looksLeft: Bool = true) {
        self.id = id
        self.label = label
        self.start = start
        self.end = end
        self.looksLeft = looksLeft
    }

    public var direction: Point2D { (end - start).normalized }
    /// The direction the section looks.
    public var viewDirection: Point2D {
        let d = direction
        return looksLeft ? Point2D(x: -d.y, y: d.x) : Point2D(x: d.y, y: -d.x)
    }
}

/// v12.5 finishes of one room, by surface. Empty means not specified.
public struct RoomFinishes: Codable, Hashable, Sendable {
    public var floor: String
    public var walls: String
    public var ceiling: String
    public var skirting: String

    public init(floor: String = "", walls: String = "", ceiling: String = "", skirting: String = "") {
        self.floor = floor
        self.walls = walls
        self.ceiling = ceiling
        self.skirting = skirting
    }

    public var isEmpty: Bool { [floor, walls, ceiling, skirting].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Common choices offered in the editor; any text is accepted.
    public static let floorSuggestions = ["Oak parquet", "Laminate", "Porcelain tiles", "Ceramic tiles", "Carpet", "Vinyl", "Polished concrete", "Screed"]
    public static let wallSuggestions = ["Emulsion paint", "Ceramic tiles", "Wallpaper", "Plaster, unpainted", "Exposed brick"]
    public static let ceilingSuggestions = ["Emulsion paint", "Plasterboard", "Acoustic tiles", "Exposed concrete"]
    public static let skirtingSuggestions = ["Painted MDF", "Timber", "Tile", "None"]
}

/// v12.4 what the drawing set contains and its title block. Saved with the project.
public struct DocumentationSettings: Codable, Hashable, Sendable {
    public var paper: PaperSize
    /// Plan scale denominator (50 = 1:50); nil picks the largest standard scale that fits.
    public var planScale: Int?
    /// Elevation and section scale denominator; nil picks one that fits.
    public var elevationScale: Int?
    public var author: String
    public var company: String
    public var siteAddress: String
    public var revision: String
    public var includeSchedules: Bool
    public var includeElevations: Bool
    public var includeSections: Bool
    public var sections: [SectionLine]
    /// v12.5 quantity tables (areas, lengths, finishes) with the schedules.
    public var includeQuantities: Bool
    /// v12.5 colour-filled area plan with a room legend.
    public var includeAreaPlan: Bool
    /// v12.5 reflected ceiling plan with ceiling heights.
    public var includeCeilingPlan: Bool
    /// v12.5 finishes by room.
    public var finishes: [UUID: RoomFinishes]

    public init(
        paper: PaperSize = .a3,
        planScale: Int? = nil,
        elevationScale: Int? = nil,
        author: String = "",
        company: String = "",
        siteAddress: String = "",
        revision: String = "A",
        includeSchedules: Bool = true,
        includeElevations: Bool = true,
        includeSections: Bool = true,
        sections: [SectionLine] = [],
        includeQuantities: Bool = true,
        includeAreaPlan: Bool = true,
        includeCeilingPlan: Bool = true,
        finishes: [UUID: RoomFinishes] = [:]
    ) {
        self.includeQuantities = includeQuantities
        self.includeAreaPlan = includeAreaPlan
        self.includeCeilingPlan = includeCeilingPlan
        self.finishes = finishes
        self.paper = paper
        self.planScale = planScale
        self.elevationScale = elevationScale
        self.author = author
        self.company = company
        self.siteAddress = siteAddress
        self.revision = revision
        self.includeSchedules = includeSchedules
        self.includeElevations = includeElevations
        self.includeSections = includeSections
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case paper, planScale, elevationScale, author, company, siteAddress, revision
        case includeSchedules, includeElevations, includeSections, sections
        case includeQuantities, includeAreaPlan, includeCeilingPlan, finishes
    }

    /// Every field is optional on read, so settings saved by earlier versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DocumentationSettings()
        paper = try c.decodeIfPresent(PaperSize.self, forKey: .paper) ?? d.paper
        planScale = try c.decodeIfPresent(Int.self, forKey: .planScale)
        elevationScale = try c.decodeIfPresent(Int.self, forKey: .elevationScale)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? d.author
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? d.company
        siteAddress = try c.decodeIfPresent(String.self, forKey: .siteAddress) ?? d.siteAddress
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? d.revision
        includeSchedules = try c.decodeIfPresent(Bool.self, forKey: .includeSchedules) ?? d.includeSchedules
        includeElevations = try c.decodeIfPresent(Bool.self, forKey: .includeElevations) ?? d.includeElevations
        includeSections = try c.decodeIfPresent(Bool.self, forKey: .includeSections) ?? d.includeSections
        sections = try c.decodeIfPresent([SectionLine].self, forKey: .sections) ?? []
        includeQuantities = try c.decodeIfPresent(Bool.self, forKey: .includeQuantities) ?? d.includeQuantities
        includeAreaPlan = try c.decodeIfPresent(Bool.self, forKey: .includeAreaPlan) ?? d.includeAreaPlan
        includeCeilingPlan = try c.decodeIfPresent(Bool.self, forKey: .includeCeilingPlan) ?? d.includeCeilingPlan
        finishes = try c.decodeIfPresent([UUID: RoomFinishes].self, forKey: .finishes) ?? [:]
    }

    /// Standard architectural scales, largest drawing first.
    public static let standardScales = [20, 25, 50, 75, 100, 200, 250, 500, 1_000]

    /// The next unused section letter: A, B, … Z, then A1, B1…
    public var nextSectionLabel: String {
        let used = Set(sections.map(\.label))
        let letters = (65...90).map { String(UnicodeScalar($0)!) }
        for round in 0..<10 {
            for letter in letters {
                let label = round == 0 ? letter : letter + String(round)
                if !used.contains(label) { return label }
            }
        }
        return "S\(sections.count + 1)"
    }
}

/// An RGB colour, components 0…1.
public struct SheetColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Light, print-friendly room colours that stay distinct next to each other.
    public static let roomPalette: [SheetColor] = [
        SheetColor(red: 0.80, green: 0.89, blue: 0.97),
        SheetColor(red: 0.86, green: 0.94, blue: 0.82),
        SheetColor(red: 0.99, green: 0.91, blue: 0.78),
        SheetColor(red: 0.93, green: 0.85, blue: 0.95),
        SheetColor(red: 0.98, green: 0.84, blue: 0.84),
        SheetColor(red: 0.82, green: 0.94, blue: 0.93),
        SheetColor(red: 0.96, green: 0.95, blue: 0.80),
        SheetColor(red: 0.88, green: 0.88, blue: 0.92),
    ]
}

public enum SheetTextAnchor: String, Hashable, Sendable {
    case left, center, right
}

/// One vector element of a drawing view or sheet. Positions are in the container's coordinates
/// (model millimetres for views, paper millimetres for sheets); line weights and text heights are
/// always paper millimetres so they print the same at every scale.
public struct SheetPrimitive: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        case line(Point2D, Point2D)
        case polyline([Point2D], closed: Bool)
        /// Filled, optionally outlined.
        case polygon([Point2D])
        case circle(center: Point2D, radius: Double)
        /// Counter-clockwise from `start` to `end`, radians.
        case arc(center: Point2D, radius: Double, start: Double, end: Double)
        /// Baseline text; `height` is the cap height in paper millimetres.
        case text(String, at: Point2D, height: Double, rotation: Double, anchor: SheetTextAnchor, bold: Bool)
    }

    public var shape: Shape
    /// Pen width in paper millimetres (0 = no outline).
    public var weight: Double
    /// Grey level of the pen, 0 = black.
    public var gray: Double
    /// Fill grey for polygons and circles; nil = not filled.
    public var fill: Double?
    /// v12.5 colour fill, used instead of `fill` when set (area plans).
    public var fillColor: SheetColor?
    /// Dash pattern in paper millimetres; empty = continuous.
    public var dash: [Double]

    public init(_ shape: Shape, weight: Double = 0.18, gray: Double = 0, fill: Double? = nil, dash: [Double] = [], fillColor: SheetColor? = nil) {
        self.fillColor = fillColor
        self.shape = shape
        self.weight = weight
        self.gray = gray
        self.fill = fill
        self.dash = dash
    }

    /// Model points this primitive covers (text by its anchor only).
    public var points: [Point2D] {
        switch shape {
        case let .line(a, b): return [a, b]
        case let .polyline(p, _), let .polygon(p): return p
        case let .circle(c, r), let .arc(c, r, _, _): return [c - Point2D(x: r, y: r), c + Point2D(x: r, y: r)]
        case let .text(_, at, _, _, _, _): return [at]
        }
    }

    /// The same primitive with every position mapped by `transform` (weights and text heights kept).
    public func mapped(_ transform: (Point2D) -> Point2D, scale: Double) -> SheetPrimitive {
        var copy = self
        switch shape {
        case let .line(a, b): copy.shape = .line(transform(a), transform(b))
        case let .polyline(p, closed): copy.shape = .polyline(p.map(transform), closed: closed)
        case let .polygon(p): copy.shape = .polygon(p.map(transform))
        case let .circle(c, r): copy.shape = .circle(center: transform(c), radius: r * scale)
        case let .arc(c, r, s, e): copy.shape = .arc(center: transform(c), radius: r * scale, start: s, end: e)
        case let .text(t, at, h, rot, anchor, bold): copy.shape = .text(t, at: transform(at), height: h, rotation: rot, anchor: anchor, bold: bold)
        }
        return copy
    }
}

/// A drawn view (plan, section or elevation) in model millimetres, before it is placed on a sheet.
public struct DrawingView: Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Scale denominator the view's annotation was laid out for.
    public var scale: Int
    public var primitives: [SheetPrimitive]

    public init(id: String, title: String, scale: Int, primitives: [SheetPrimitive]) {
        self.id = id
        self.title = title
        self.scale = scale
        self.primitives = primitives
    }

    /// Extent of the geometry in model millimetres (text counted by its anchor plus a margin).
    public var bounds: CADRect {
        CADRect(points: primitives.flatMap(\.points)) ?? .empty
    }
}

extension PlanOpsisProject {
    /// v12.4 documentation settings, or the defaults when the project has none yet.
    public var documentationSettings: DocumentationSettings {
        get { documentation ?? DocumentationSettings() }
        set { documentation = newValue }
    }
}
