import Foundation

/// Architectural drawing convention used consistently by the PlanOpsis plan view and DXF exchange.
/// Layer organization follows a compact ISO 13567 / NCS-style discipline grouping while semantic
/// object classes retain explicit IFC-compatible class names in DXF XDATA.
public enum ArchitecturalDraftingConvention {
    public enum IFCClass: String, Codable, Hashable, Sendable, CaseIterable {
        case wall = "IfcWall"
        case door = "IfcDoor"
        case window = "IfcWindow"
        case opening = "IfcOpeningElement"
        case space = "IfcSpace"
        case column = "IfcColumn"
        case beam = "IfcBeam"
        case furnishing = "IfcFurnishingElement"
        case sanitaryTerminal = "IfcSanitaryTerminal"
    }

    public enum Layer: String, CaseIterable, Sendable {
        /// Visible architectural/semantic layers.
        case wall = "A-WALL"
        case door = "A-DOOR"
        case doorSwing = "A-DOOR-SWNG"
        case window = "A-WIND"
        case opening = "A-OPEN"
        case space = "A-SPACE"
        case column = "S-COLS"
        case beam = "S-BEAM"
        case furnishing = "A-FURN"
        case sanitary = "P-FIXT"

        /// Drawing and annotation layers.
        case dimensions = "A-DIMS"
        case annotation = "A-ANNO"
        case roomAnnotation = "A-ANNO-ROOM"
        /// v12.4 door, window and opening marks (D01, W01…).
        case tags = "A-ANNO-TAGS"

        /// Technical PlanOpsis round-trip layers. These are non-plot/off by default.
        case wallCenter = "A-WALL-CNTR"
        case metadata = "A-ANNO-NPLT"
    }

    public struct Defaults: Hashable, Sendable {
        public var wallThickness: Double = 200
        public var wallHeight: Double = 2_800
        public var wallLength: Double = 3_000
        public var doorWidth: Double = 900
        public var doorHeight: Double = 2_100
        public var windowWidth: Double = 1_200
        public var windowHeight: Double = 1_200
        public var windowSill: Double = 900
        public var openingWidth: Double = 1_000
        public var openingHeight: Double = 2_100

        public init() {}
    }

    /// Architectural object -> CAD layer mapping. This is the canonical DXF mapping.
    public static func layer(for ifcClass: IFCClass) -> Layer {
        switch ifcClass {
        case .wall: return .wall
        case .door: return .door
        case .window: return .window
        case .opening: return .opening
        case .space: return .space
        case .column: return .column
        case .beam: return .beam
        case .furnishing: return .furnishing
        case .sanitaryTerminal: return .sanitary
        }
    }

    /// Approximate printed line weights in millimetres for architectural hierarchy.
    public static func lineWeightMM(for layer: Layer) -> Double {
        switch layer {
        case .wall: return 0.50
        case .door, .window, .opening: return 0.25
        case .space: return 0.13
        case .column, .beam: return 0.35
        case .furnishing, .sanitary: return 0.18
        case .doorSwing, .dimensions, .roomAnnotation, .tags: return 0.13
        case .wallCenter, .annotation, .metadata: return 0.09
        }
    }

    /// AutoCAD indexed colors are used only for layer differentiation in simple viewers.
    /// Plotting intent remains line-weight/layer driven rather than color driven.
    public static func dxfColorIndex(for layer: Layer) -> Int {
        switch layer {
        case .wallCenter, .metadata, .space: return 8
        default: return 7
        }
    }

    /// Technical layers stay in the file for deterministic round-trip but should not plot.
    public static func isPlotLayer(_ layer: Layer) -> Bool {
        switch layer {
        case .wallCenter, .metadata, .space: return false
        default: return true
        }
    }

    /// Technical layers are off by default in third-party CAD viewers.
    public static func isInitiallyVisible(_ layer: Layer) -> Bool {
        switch layer {
        case .wallCenter, .metadata, .space: return false
        default: return true
        }
    }

    /// DXF only accepts a discrete set of lineweight values in hundredths of a millimetre.
    /// Quantize arbitrary display weights so third-party CAD auditors do not repair the file.
    public static func dxfLineWeightHundredthsMM(_ millimetres: Double) -> Int {
        let valid = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]
        let requested = Int((max(0, millimetres) * 100).rounded())
        return valid.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 18
    }

    public static func dxfLineWeightHundredthsMM(for layer: Layer) -> Int {
        dxfLineWeightHundredthsMM(lineWeightMM(for: layer))
    }
}

/// v12.3 how DXF layers are named. Geometry is always grouped by what it represents; this only
/// chooses the names CAD programs see.
public enum DXFLayerNaming: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// One layer per IFC class: IfcWall, IfcDoor, IfcWindow, IfcSpace… (default).
    case ifcClass
    /// CAD discipline layers used up to v12.2: A-WALL, A-DOOR, A-DOOR-SWNG, S-COLS, P-FIXT…
    case discipline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ifcClass: return "IFC class layers"
        case .discipline: return "CAD discipline layers"
        }
    }
}

public extension ArchitecturalDraftingConvention.Layer {
    /// The layer name written to DXF. With IFC naming every element's geometry, including door
    /// swings, sits on its IFC class layer; drawing-only content goes to IfcAnnotation layers.
    func dxfName(_ naming: DXFLayerNaming) -> String {
        guard naming == .ifcClass else { return rawValue }
        switch self {
        case .wall: return "IfcWall"
        case .wallCenter: return "IfcWall-Axis"
        case .door, .doorSwing: return "IfcDoor"
        case .window: return "IfcWindow"
        case .opening: return "IfcOpeningElement"
        case .space: return "IfcSpace"
        case .column: return "IfcColumn"
        case .beam: return "IfcBeam"
        case .furnishing: return "IfcFurnishingElement"
        case .sanitary: return "IfcSanitaryTerminal"
        case .dimensions: return "IfcAnnotation-Dimensions"
        case .annotation, .roomAnnotation: return "IfcAnnotation"
        case .tags: return "IfcAnnotation-Tags"
        case .metadata: return "PlanOpsis-Metadata"
        }
    }

    /// Reads a layer name in either naming (case-insensitive), so files exported before v12.3 and
    /// files edited in Rhino or AutoCAD still import. Merged IFC layers resolve to their main layer.
    init?(dxfName name: String) {
        let key = name.uppercased()
        for naming in [DXFLayerNaming.discipline, .ifcClass] {
            if let layer = Self.allCases.first(where: { $0.dxfName(naming).uppercased() == key }) {
                self = layer
                return
            }
        }
        return nil
    }

    /// The internal layer name for a name read from DXF; unknown layers keep their name.
    static func normalizedName(_ dxfName: String) -> String {
        Self(dxfName: dxfName)?.rawValue ?? dxfName
    }
}

public extension ArchitecturalDraftingConvention {
    /// IFC class of a component kind (the same classes the IFC4 export writes).
    static func ifcClass(for kind: PlanOpsisComponent.Kind) -> IFCClass {
        switch kind {
        case .column: return .column
        case .beam: return .beam
        case .bed, .table, .chair, .sofa: return .furnishing
        case .wc, .sink: return .sanitaryTerminal
        }
    }

    static func ifcClass(for kind: PlanOpsisOpening.Kind) -> IFCClass {
        switch kind {
        case .door: return .door
        case .window: return .window
        case .opening: return .opening
        }
    }
}

public extension ArchitecturalDraftingConvention {
    enum TextStyle {
        public static let name = "STANDARD"
        public static let font = "txt"
        public static let dimensionHeightMM = 150.0
        public static let roomNameHeightMM = 180.0
        public static let roomAreaHeightMM = 150.0
    }
}

/// R2000 is ASCII/CIF. Encode Unicode as DXF UTF-16 escapes, not mislabeled UTF-8 bytes.
public enum DXFTextCodec {
    public static func encode(_ value: String) -> String {
        value.replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ").utf16.map { unit in
            if unit >= 32 && unit <= 126 && unit != 92 { return String(UnicodeScalar(unit)!) }
            return String(format:"\\U+%04X",unit)
        }.joined()
    }
    public static func decode(_ value: String) -> String {
        let units=Array(value.utf16)
        var result:[UInt16]=[], index=0
        while index < units.count {
            if index+6 < units.count, units[index] == 92, units[index+1] == 85, units[index+2] == 43,
               let unit=UInt16(String(decoding:units[(index+3)...(index+6)],as:UTF16.self),radix:16) {
                result.append(unit);index += 7
            } else { result.append(units[index]);index += 1 }
        }
        return String(decoding:result,as:UTF16.self)
    }
}
