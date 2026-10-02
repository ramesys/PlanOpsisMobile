import Foundation

public enum SurveyError: Error, Equatable, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public enum SurveyUnit: String, Codable, CaseIterable, Sendable {
    case mm, cm, m
    public var factor: Double { self == .m ? 1000 : (self == .cm ? 10 : 1) }
}
public struct SurveyPoint: Codable, Hashable, Sendable {
    public enum Location: Codable, Hashable, Sendable {
        case start, end
        case openingEdge(openingID:UUID,side:Int)
        case face(stationMM: Double, side: Int)
    }
    public var roomID: UUID
    public var wallID: UUID
    public var location: Location
}
public enum SurveyProjectionAxis:String,Codable,Hashable,Sendable { case horizontal,vertical }
public enum SurveyMeasurementTarget: Codable, Hashable, Sendable {
    case wallLength(roomID: UUID, wallID: UUID)
    case wallThickness(roomID: UUID, wallID: UUID)
    case openingWidth(roomID: UUID, openingID: UUID)
    case distance(from: SurveyPoint, to: SurveyPoint)
    case projectedDistance(from:SurveyPoint,to:SurveyPoint,axis:SurveyProjectionAxis)
    public var entityIDs: [UUID] {
        switch self {
        case .wallLength(_, let id), .wallThickness(_, let id), .openingWidth(_, let id): return [id]
        case .distance(let a, let b),.projectedDistance(let a,let b,_): return [a.wallID, b.wallID]
        }
    }
    /// Every semantic object whose deletion invalidates this target, including openings referenced
    /// by opening-edge points (which `entityIDs` omits).
    public var referencedEntityIDs: Set<UUID> {
        var ids = Set(entityIDs)
        if case .distance(let a, let b) = self { ids.formUnion([a, b].compactMap(\.openingID)) }
        if case .projectedDistance(let a, let b, _) = self { ids.formUnion([a, b].compactMap(\.openingID)) }
        return ids
    }
}
extension SurveyPoint {
    var openingID: UUID? {
        if case .openingEdge(let id, _) = location { return id }
        return nil
    }
}
public struct SurveyObservation: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var target: SurveyMeasurementTarget
    public var observedMM: Double
    public var unit: SurveyUnit = .mm
    public var method = "Manual measurement"
    public var toleranceMM: Double?
    public var timestamp = Date()
    public var note = ""
    public var verificationFingerprint: String?
    public var locked = false
}
public enum SurveyEvidenceKind: String, Codable, Sendable {
    case photo, plyComparison, sourcePLY
    /// v12.1: the platform-neutral RoomPlan capture (`StructureCaptureSnapshot`) the project was built from.
    case roomPlanCapture
}
public struct SurveyEvidenceReference: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var relativePath: String
    public var sha256: String
    public var sourceName: String
    public var kind: SurveyEvidenceKind
    public var entityID: UUID?
}
public struct SurveyDimensionDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var target: SurveyMeasurementTarget
    public var offsetMM: Double = 350
    public var textPosition: Point2D?
}
public struct SurveyDrawingSettings: Codable, Hashable, Sendable {
    public var scale = 50
    public var precision = 0
    public var showDimensions = true
    public var showRoomNames = true
    public var showOpeningWidths = true
    public var showChains = false
    public var showOverall = false
    public var paperTextHeightMM: Double = 2.5
    public var modelTextHeightMM: Double { paperTextHeightMM * Double(scale) }
    public init() {}
}
public struct SurveyRecord: Codable, Hashable, Sendable {
    public var roomNames: [UUID: String] = [:]
    public var observations: [SurveyObservation] = []
    public var evidence: [SurveyEvidenceReference] = []
    public var dimensions: [SurveyDimensionDefinition] = []
    public var settings = SurveyDrawingSettings()
    public var notes = ""
    public static let empty = SurveyRecord()
    public init() {}
}

public enum SurveyValidation {
    public static func validate(_ project: PlanOpsisProject) throws {
        var ids = [project.id]
        for room in project.rooms {
            ids.append(room.id)
            ids.append(contentsOf: room.walls.map(\.id))
            ids.append(contentsOf: room.openings.map(\.id))
            ids.append(contentsOf: room.components.map(\.id))
        }
        guard Set(ids).count == ids.count else { throw SurveyError.invalid("Duplicate architectural identity.") }
        let record = project.survey
        let surveyIDs = record.observations.map(\.id) + record.dimensions.map(\.id) + record.evidence.map(\.id)
        guard Set(surveyIDs).count == surveyIDs.count, Set(surveyIDs).isDisjoint(with: Set(ids)) else { throw SurveyError.invalid("Duplicate survey identity.") }
        guard record.roomNames.keys.allSatisfy({ id in project.rooms.contains { $0.id == id } }) else { throw SurveyError.invalid("Room name refers to a missing room.") }
        guard [20,50,100].contains(record.settings.scale), (0...3).contains(record.settings.precision), record.settings.paperTextHeightMM.isFinite, record.settings.paperTextHeightMM > 0 else { throw SurveyError.invalid("Invalid drawing settings.") }
        for o in record.observations {
            guard o.observedMM.isFinite, o.observedMM > 0, o.toleranceMM.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw SurveyError.invalid("Measurement and tolerance must be finite and valid.") }
            try validate(o.target, in: project)
        }
        for d in record.dimensions {
            try validate(d.target, in: project)
            guard d.offsetMM.isFinite, d.textPosition.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { throw SurveyError.invalid("Invalid dimension placement.") }
        }
        for e in record.evidence {
            guard e.projectID == project.id, e.entityID.map({ ids.contains($0) }) ?? true else { throw SurveyError.invalid("Evidence belongs to a different project or missing entity.") }
            guard e.sha256.count == 64, e.sha256.allSatisfy({ $0.isHexDigit }), e.relativePath == "assets/\(project.id.uuidString)/\(e.sha256).asset" else { throw SurveyError.invalid("Invalid evidence path or hash.") }
        }
    }
    public static func validate(_ target: SurveyMeasurementTarget, in project: PlanOpsisProject) throws {
        func wall(_ room: UUID, _ id: UUID) throws -> PlanOpsisWall {
            guard let w = project.rooms.first(where: { $0.id == room })?.walls.first(where: { $0.id == id }), w.length.isFinite, w.length > 0, w.thickness.isFinite, w.thickness > 0, w.start.x.isFinite, w.start.y.isFinite, w.angleRadians.isFinite else { throw SurveyError.invalid("Measurement wall is missing or invalid.") }
            return w
        }
        switch target {
        case .wallLength(let r, let w), .wallThickness(let r, let w): _ = try wall(r,w)
        case .openingWidth(let r, let id):
            guard let room = project.rooms.first(where: { $0.id == r }), let o = room.openings.first(where: { $0.id == id }), o.parameters.width.isFinite, o.parameters.width > 0, room.walls.contains(where: { $0.id == o.parameters.hostWallID }) else { throw SurveyError.invalid("Measurement opening is missing or invalid.") }
        case .distance(let a, let b),.projectedDistance(let a,let b,_):
            for p in [a,b] {
                let w = try wall(p.roomID,p.wallID)
                if case .openingEdge(let id,let side)=p.location {
                    guard side == -1 || side == 1,let o=project.rooms.first(where:{$0.id==p.roomID})?.openings.first(where:{$0.id==id}),o.parameters.hostWallID==w.id else { throw SurveyError.invalid("Dimension opening reference is missing or has another host.") }
                }
                if case .face(let station, let side) = p.location {
                    guard station.isFinite, (0...w.length).contains(station), side == -1 || side == 1 else { throw SurveyError.invalid("Invalid wall-face station.") }
                }
            }
        }
    }
}

extension SurveyRecord {
    private enum CodingKeys:String,CodingKey { case roomNames,observations,evidence,dimensions,settings,notes }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        if let names=try? c.decode([String:String].self,forKey:.roomNames) {
            roomNames=[:]
            for (key,value) in names {
                guard let id=UUID(uuidString:key),roomNames[id]==nil else { throw SurveyError.invalid("Invalid or duplicate room-name identity.") }
                roomNames[id]=value
            }
        } else { roomNames=try c.decode([UUID:String].self,forKey:.roomNames) }
        observations=try c.decode([SurveyObservation].self,forKey:.observations)
        evidence=try c.decode([SurveyEvidenceReference].self,forKey:.evidence)
        dimensions=try c.decode([SurveyDimensionDefinition].self,forKey:.dimensions)
        settings=try c.decode(SurveyDrawingSettings.self,forKey:.settings)
        notes=try c.decode(String.self,forKey:.notes)
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues:roomNames.map{($0.key.uuidString,$0.value)}),forKey:.roomNames)
        try c.encode(observations,forKey:.observations);try c.encode(evidence,forKey:.evidence)
        try c.encode(dimensions,forKey:.dimensions);try c.encode(settings,forKey:.settings);try c.encode(notes,forKey:.notes)
    }
}

extension SurveyDrawingSettings {
    private enum CodingKeys:String,CodingKey { case scale,precision,showDimensions,showRoomNames,showOpeningWidths,showChains,showOverall,paperTextHeightMM }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        scale=try c.decode(Int.self,forKey:.scale);precision=try c.decode(Int.self,forKey:.precision)
        showDimensions=try c.decode(Bool.self,forKey:.showDimensions);showRoomNames=try c.decode(Bool.self,forKey:.showRoomNames)
        showOpeningWidths=try c.decode(Bool.self,forKey:.showOpeningWidths)
        paperTextHeightMM=try c.decode(Double.self,forKey:.paperTextHeightMM)
        showChains=try c.decodeIfPresent(Bool.self,forKey:.showChains) ?? false
        showOverall=try c.decodeIfPresent(Bool.self,forKey:.showOverall) ?? false
    }
}
