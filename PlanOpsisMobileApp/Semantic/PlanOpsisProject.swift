import Foundation

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    public static func + (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func * (lhs: Point2D, rhs: Double) -> Point2D {
        Point2D(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    public var length: Double { sqrt(x * x + y * y) }

    public var normalized: Point2D {
        let magnitude = length
        guard magnitude > 1e-9 else { return Point2D(x: 1, y: 0) }
        return Point2D(x: x / magnitude, y: y / magnitude)
    }

    public func dot(_ other: Point2D) -> Double { x * other.x + y * other.y }
}

public enum CaptureConfidence: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
    case unknown
}

public struct PlanOpsisProject: Codable, Hashable, Sendable, Identifiable {
    /// Schema v2 stores project-owned survey observations and evidence references.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    /// RoomPlan `CapturedStructure.identifier` provenance only. Never architectural identity.
    public var sourceStructureRoomPlanID: UUID?
    public var rooms: [PlanOpsisRoom]
    public var survey: SurveyRecord
    /// v12.2 user-facing project name; nil for projects that were never named.
    public var name: String?
    /// v12.4 drawing set settings (title block, paper, scales, section lines); nil until first edited.
    public var documentation: DocumentationSettings?
    /// v12.7 the drawing kept under the plan and where it sits; nil when the project has none.
    public var underlay: ProjectUnderlay?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        sourceStructureRoomPlanID: UUID? = nil,
        rooms: [PlanOpsisRoom],
        survey: SurveyRecord = .empty,
        name: String? = nil,
        documentation: DocumentationSettings? = nil
    ) {
        self.documentation = documentation
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceStructureRoomPlanID = sourceStructureRoomPlanID
        self.rooms = rooms
        self.survey = survey
        self.name = name
    }

    /// Name shown in the project list: the project name, else the first named room, else "Untitled project".
    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        for room in rooms {
            if let roomName = survey.roomNames[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !roomName.isEmpty { return roomName }
        }
        return "Untitled project"
    }
}

extension PlanOpsisProject {
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, sourceStructureRoomPlanID, rooms, survey, name, documentation, underlay }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        sourceStructureRoomPlanID = try c.decodeIfPresent(UUID.self, forKey: .sourceStructureRoomPlanID)
        rooms = try c.decode([PlanOpsisRoom].self, forKey: .rooms)
        if schemaVersion == 1 { survey = .empty }
        else { survey = try c.decode(SurveyRecord.self, forKey: .survey) }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        documentation = try c.decodeIfPresent(DocumentationSettings.self, forKey: .documentation)
        underlay = try? c.decodeIfPresent(ProjectUnderlay.self, forKey: .underlay)
    }
}

public struct PlanOpsisComponent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case column
        case beam
        case bed
        case table
        case chair
        case sofa
        case wc
        case sink
        // v12.8 every object RoomPlan recognises has a kind of its own.
        case storage
        case fireplace
        case bathtub
        case refrigerator
        case stove
        case oven
        case dishwasher
        case washerDryer
        case television
        case stairs

        public var displayName: String {
            switch self {
            case .column: return "Column"
            case .beam: return "Beam"
            case .bed: return "Bed"
            case .table: return "Table"
            case .chair: return "Chair"
            case .sofa: return "Sofa"
            case .wc: return "WC"
            case .sink: return "Sink"
            case .storage: return "Storage"
            case .fireplace: return "Fireplace"
            case .bathtub: return "Bathtub"
            case .refrigerator: return "Refrigerator"
            case .stove: return "Stove"
            case .oven: return "Oven"
            case .dishwasher: return "Dishwasher"
            case .washerDryer: return "Washer / dryer"
            case .television: return "Television"
            case .stairs: return "Stairs"
            }
        }

        public var defaultSize: (width: Double, depth: Double, height: Double) {
            switch self {
            case .column: return (300, 300, 2_800)
            case .beam: return (3_000, 250, 350)
            case .bed: return (1_600, 2_000, 500)
            case .table: return (1_200, 750, 750)
            case .chair: return (500, 500, 850)
            case .sofa: return (1_800, 850, 800)
            case .wc: return (380, 700, 780)
            case .sink: return (600, 500, 850)
            case .storage: return (1_000, 600, 2_000)
            case .fireplace: return (1_200, 450, 1_100)
            case .bathtub: return (1_700, 750, 550)
            case .refrigerator: return (600, 650, 1_850)
            case .stove: return (600, 600, 900)
            case .oven: return (600, 600, 900)
            case .dishwasher: return (600, 600, 850)
            case .washerDryer: return (600, 600, 850)
            case .television: return (1_250, 80, 720)
            case .stairs: return (1_000, 3_000, 2_800)
            }
        }

        /// Groups for menus and colours.
        public enum Group: String, CaseIterable, Sendable { case structure, furniture, sanitary, appliance, building }

        public var group: Group {
            switch self {
            case .column, .beam: return .structure
            case .bed, .table, .chair, .sofa, .storage, .fireplace: return .furniture
            case .wc, .sink, .bathtub: return .sanitary
            case .refrigerator, .stove, .oven, .dishwasher, .washerDryer, .television: return .appliance
            case .stairs: return .building
            }
        }

        /// v12.8 the kind for a RoomPlan object category (`CapturedRoom.Object.Category` case name);
        /// nil for categories PlanOpsis does not know yet.
        public init?(roomPlanCategory: String) {
            switch roomPlanCategory {
            case "toilet": self = .wc
            case "sink": self = .sink
            case "bathtub": self = .bathtub
            case "bed": self = .bed
            case "table": self = .table
            case "chair": self = .chair
            case "sofa": self = .sofa
            case "storage": self = .storage
            case "fireplace": self = .fireplace
            case "refrigerator": self = .refrigerator
            case "stove": self = .stove
            case "oven": self = .oven
            case "dishwasher": self = .dishwasher
            case "washerDryer": self = .washerDryer
            case "television": self = .television
            case "stairs": self = .stairs
            default: return nil
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var position: Point2D
    public var width: Double
    public var depth: Double
    public var height: Double
    /// Optional base elevation above the room floor. Existing v1 projects decode nil as floor-based.
    /// Structural beams use this to retain their measured overhead placement.
    public var elevationMM: Double?
    public var rotationRadians: Double
    /// v12.8 provenance for objects RoomPlan detected: its identifier and how sure it was. Nil for
    /// objects placed by hand.
    public var sourceRoomPlanID: UUID?
    public var confidence: CaptureConfidence?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        position: Point2D,
        width: Double? = nil,
        depth: Double? = nil,
        height: Double? = nil,
        elevationMM: Double? = nil,
        rotationRadians: Double = 0,
        sourceRoomPlanID: UUID? = nil,
        confidence: CaptureConfidence? = nil
    ) {
        let defaults = kind.defaultSize
        self.sourceRoomPlanID = sourceRoomPlanID
        self.confidence = confidence
        self.id = id
        self.kind = kind
        self.position = position
        self.width = max(1, width ?? defaults.width)
        self.depth = max(1, depth ?? defaults.depth)
        self.height = max(1, height ?? defaults.height)
        self.elevationMM = elevationMM.map { max(0, $0) }
        self.rotationRadians = rotationRadians
    }

    public var baseElevationMM: Double { elevationMM ?? 0 }

    public var direction: Point2D {
        Point2D(x: cos(rotationRadians), y: sin(rotationRadians))
    }

    public var normal: Point2D {
        Point2D(x: -sin(rotationRadians), y: cos(rotationRadians))
    }

    public var footprint: [Point2D] {
        let x = direction * (width * 0.5)
        let y = normal * (depth * 0.5)
        return [position - x - y, position + x - y, position + x + y, position - x + y]
    }
}

public struct PlanOpsisRoom: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRoomPlanID: UUID?
    public var walls: [PlanOpsisWall]
    public var openings: [PlanOpsisOpening]
    /// v9.6 independent semantic interior/structural components. These are not RoomPlan evidence.
    public var components: [PlanOpsisComponent]
    /// v12.1 provenance: elevation of this room's floor in the capture coordinate space (mm).
    /// Semantic heights and sills are already relative to this floor; nil for drawn/imported rooms.
    public var captureFloorElevationMM: Double?

    public init(
        id: UUID = UUID(),
        sourceRoomPlanID: UUID? = nil,
        walls: [PlanOpsisWall] = [],
        openings: [PlanOpsisOpening] = [],
        components: [PlanOpsisComponent] = [],
        captureFloorElevationMM: Double? = nil
    ) {
        self.id = id
        self.sourceRoomPlanID = sourceRoomPlanID
        self.walls = walls
        self.openings = openings
        self.components = components
        self.captureFloorElevationMM = captureFloorElevationMM
    }
}

extension PlanOpsisRoom: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceRoomPlanID, walls, openings, components, captureFloorElevationMM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceRoomPlanID = try container.decodeIfPresent(UUID.self, forKey: .sourceRoomPlanID)
        walls = try container.decodeIfPresent([PlanOpsisWall].self, forKey: .walls) ?? []
        openings = try container.decodeIfPresent([PlanOpsisOpening].self, forKey: .openings) ?? []
        // Backward-compatible with every v1 project saved before v9.6.
        components = try container.decodeIfPresent([PlanOpsisComponent].self, forKey: .components) ?? []
        captureFloorElevationMM = try container.decodeIfPresent(Double.self, forKey: .captureFloorElevationMM)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sourceRoomPlanID, forKey: .sourceRoomPlanID)
        try container.encode(walls, forKey: .walls)
        try container.encode(openings, forKey: .openings)
        try container.encode(components, forKey: .components)
        try container.encodeIfPresent(captureFloorElevationMM, forKey: .captureFloorElevationMM)
    }
}
