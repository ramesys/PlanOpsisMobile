import Foundation

public struct HostedOpeningParameters: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRoomPlanID: UUID?
    public var hostWallID: UUID
    public var offsetAlongWall: Double
    public var width: Double
    public var height: Double
    public var sillHeight: Double
    public var confidence: CaptureConfidence

    public init(
        id: UUID = UUID(),
        sourceRoomPlanID: UUID? = nil,
        hostWallID: UUID,
        offsetAlongWall: Double,
        width: Double,
        height: Double,
        sillHeight: Double,
        confidence: CaptureConfidence = .unknown
    ) {
        self.id = id
        self.sourceRoomPlanID = sourceRoomPlanID
        self.hostWallID = hostWallID
        self.offsetAlongWall = offsetAlongWall
        self.width = max(0, width)
        self.height = max(0, height)
        self.sillHeight = max(0, sillHeight)
        self.confidence = confidence
    }
}

public struct PlanOpsisDoor: Codable, Hashable, Sendable, Identifiable {
    public enum Swing: String, Codable, Hashable, Sendable, CaseIterable {
        case unspecified
        case leftIn
        case leftOut
        case rightIn
        case rightOut
    }

    /// v9.6 semantic door family. This is architectural type data, not a drawing symbol choice.
    public enum Operation: String, Codable, Hashable, Sendable, CaseIterable {
        case singleHinged
        case doubleHinged
        case sliding
        case pocket
    }

    public var parameters: HostedOpeningParameters
    public var swing: Swing = .unspecified
    public var operation: Operation = .singleHinged
    public var id: UUID { parameters.id }

    public init(
        parameters: HostedOpeningParameters,
        swing: Swing = .unspecified,
        operation: Operation = .singleHinged
    ) {
        self.parameters = parameters
        self.swing = swing
        self.operation = operation
    }
}

public struct PlanOpsisWindow: Codable, Hashable, Sendable, Identifiable {
    /// v9.6 semantic window family.
    public enum Operation: String, Codable, Hashable, Sendable, CaseIterable {
        case fixed
        case singleCasement
        case doubleCasement
        case sliding
    }

    public var parameters: HostedOpeningParameters
    public var operation: Operation = .fixed
    public var id: UUID { parameters.id }

    public init(parameters: HostedOpeningParameters, operation: Operation = .fixed) {
        self.parameters = parameters
        self.operation = operation
    }
}

public enum PlanOpsisOpening: Hashable, Sendable, Identifiable {
    case opening(HostedOpeningParameters)
    case door(PlanOpsisDoor)
    case window(PlanOpsisWindow)

    public enum Kind: String, Codable, Hashable, Sendable {
        case opening
        case door
        case window
    }

    public var id: UUID { parameters.id }

    public var kind: Kind {
        switch self {
        case .opening: return .opening
        case .door: return .door
        case .window: return .window
        }
    }

    public var parameters: HostedOpeningParameters {
        get {
            switch self {
            case .opening(let value): return value
            case .door(let value): return value.parameters
            case .window(let value): return value.parameters
            }
        }
        set {
            switch self {
            case .opening:
                self = .opening(newValue)
            case .door(let value):
                self = .door(PlanOpsisDoor(parameters: newValue, swing: value.swing, operation: value.operation))
            case .window(let value):
                self = .window(PlanOpsisWindow(parameters: newValue, operation: value.operation))
            }
        }
    }

    public var doorSwing: PlanOpsisDoor.Swing? {
        get {
            guard case .door(let door) = self else { return nil }
            return door.swing
        }
        set {
            guard case .door(let door) = self, let newValue else { return }
            self = .door(PlanOpsisDoor(parameters: door.parameters, swing: newValue, operation: door.operation))
        }
    }

    public var doorOperation: PlanOpsisDoor.Operation? {
        get {
            guard case .door(let door) = self else { return nil }
            return door.operation
        }
        set {
            guard case .door(let door) = self, let newValue else { return }
            self = .door(PlanOpsisDoor(parameters: door.parameters, swing: door.swing, operation: newValue))
        }
    }

    public var windowOperation: PlanOpsisWindow.Operation? {
        get {
            guard case .window(let window) = self else { return nil }
            return window.operation
        }
        set {
            guard case .window(let window) = self, let newValue else { return }
            self = .window(PlanOpsisWindow(parameters: window.parameters, operation: newValue))
        }
    }
}

extension PlanOpsisOpening: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case parameters
        case swing
        case doorOperation
        case windowOperation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let parameters = try container.decode(HostedOpeningParameters.self, forKey: .parameters)
        switch kind {
        case .opening:
            self = .opening(parameters)
        case .door:
            let swing = try container.decodeIfPresent(PlanOpsisDoor.Swing.self, forKey: .swing) ?? .unspecified
            let operation = try container.decodeIfPresent(PlanOpsisDoor.Operation.self, forKey: .doorOperation) ?? .singleHinged
            self = .door(PlanOpsisDoor(parameters: parameters, swing: swing, operation: operation))
        case .window:
            let operation = try container.decodeIfPresent(PlanOpsisWindow.Operation.self, forKey: .windowOperation) ?? .fixed
            self = .window(PlanOpsisWindow(parameters: parameters, operation: operation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(parameters, forKey: .parameters)
        if case .door(let door) = self {
            try container.encode(door.swing, forKey: .swing)
            try container.encode(door.operation, forKey: .doorOperation)
        }
        if case .window(let window) = self {
            try container.encode(window.operation, forKey: .windowOperation)
        }
    }
}
