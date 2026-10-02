import Foundation

public enum SurveyReadinessSeverity: String, Codable, Hashable, Sendable, CaseIterable {
    case info
    case warning
    case error
}

public struct SurveyReadinessIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case noRooms
        case roomHasTooFewWalls
        case openRoomBoundary
        case invalidOpeningHost
        case openingOutsideHost
        case lowConfidenceGeometry
        case unsupportedCapturedWall
        case captureRelationshipError
        case reconciliationConflict
    }

    public var code: Code
    public var severity: SurveyReadinessSeverity
    public var roomID: UUID?
    public var entityID: UUID?
    public var message: String

    public var id: String {
        "survey:\(code.rawValue):\(severity.rawValue):\(roomID?.uuidString ?? "none"):\(entityID?.uuidString ?? "none"):\(message)"
    }

    public init(
        code: Code,
        severity: SurveyReadinessSeverity,
        roomID: UUID? = nil,
        entityID: UUID? = nil,
        message: String
    ) {
        self.code = code
        self.severity = severity
        self.roomID = roomID
        self.entityID = entityID
        self.message = message
    }
}

public struct ArchitecturalSurveyReadinessReport: Codable, Hashable, Sendable {
    public var roomCount: Int
    public var wallCount: Int
    public var openingCount: Int
    public var closedRoomCount: Int
    public var lowConfidenceElementCount: Int
    public var issues: [SurveyReadinessIssue]

    public init(
        roomCount: Int,
        wallCount: Int,
        openingCount: Int,
        closedRoomCount: Int,
        lowConfidenceElementCount: Int,
        issues: [SurveyReadinessIssue]
    ) {
        self.roomCount = roomCount
        self.wallCount = wallCount
        self.openingCount = openingCount
        self.closedRoomCount = closedRoomCount
        self.lowConfidenceElementCount = lowConfidenceElementCount
        self.issues = issues
    }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public var canExportDXF: Bool { roomCount > 0 && wallCount > 0 && errorCount == 0 }
    public var isProfessionalReady: Bool { canExportDXF && warningCount == 0 }

    public static let empty = ArchitecturalSurveyReadinessReport(
        roomCount: 0,
        wallCount: 0,
        openingCount: 0,
        closedRoomCount: 0,
        lowConfidenceElementCount: 0,
        issues: [
            SurveyReadinessIssue(
                code: .noRooms,
                severity: .error,
                message: "No architectural rooms are available for DXF export."
            )
        ]
    )
}

/// Deterministic pre-export QA for the LiDAR -> PlanOpsis -> DXF workflow.
///
/// This engine never modifies architecture. It classifies whether the semantic project can be
/// exported safely and whether it is clean enough to be treated as a professional drawing without
/// further review. Warnings never fabricate missing geometry; errors block the one-tap DXF export.
public struct ArchitecturalSurveyReadinessEngine {
    public init() {}

    public func evaluate(
        project: PlanOpsisProject,
        geometry: ArchitecturalGeometrySnapshot? = nil,
        captureDiagnostics: [RoomPlanAdapter.Diagnostic] = []
    ) -> ArchitecturalSurveyReadinessReport {
        let generated = geometry ?? ParametricGeometryEngine().generate(from: project)
        var issues: [SurveyReadinessIssue] = []

        if project.rooms.isEmpty {
            issues.append(.init(code: .noRooms, severity: .error, message: "No rooms were captured or drawn."))
        }

        for room in project.rooms {
            if room.walls.count < 3 {
                issues.append(.init(
                    code: .roomHasTooFewWalls,
                    severity: .error,
                    roomID: room.id,
                    message: "Room has fewer than three walls and cannot define an architectural enclosure."
                ))
            }

            if let boundary = generated.topology.roomBoundaries.first(where: { $0.roomID == room.id }), !boundary.isClosed {
                issues.append(.init(
                    code: .openRoomBoundary,
                    severity: .warning,
                    roomID: room.id,
                    message: "Room boundary is open. Review wall endpoints before issuing the DXF."
                ))
            }

            let wallsByID = Dictionary(uniqueKeysWithValues: room.walls.map { ($0.id, $0) })
            for opening in room.openings {
                guard let host = wallsByID[opening.parameters.hostWallID] else {
                    issues.append(.init(
                        code: .invalidOpeningHost,
                        severity: .error,
                        roomID: room.id,
                        entityID: opening.id,
                        message: "Opening has no valid host wall."
                    ))
                    continue
                }
                let p = opening.parameters
                if p.width <= 0 || p.height <= 0 || p.offsetAlongWall - p.width * 0.5 < -1e-6 || p.offsetAlongWall + p.width * 0.5 > host.length + 1e-6 || p.sillHeight < -1e-6 || p.sillHeight + p.height > host.height + 1e-6 {
                    issues.append(.init(
                        code: .openingOutsideHost,
                        severity: .error,
                        roomID: room.id,
                        entityID: opening.id,
                        message: "Opening dimensions extend outside the host wall."
                    ))
                }
            }
        }

        let lowWalls = project.rooms.flatMap(\.walls).filter { $0.confidence == .low || $0.confidence == .unknown }
        let lowOpenings = project.rooms.flatMap(\.openings).filter { $0.parameters.confidence == .low || $0.parameters.confidence == .unknown }
        let lowCount = lowWalls.count + lowOpenings.count
        if lowCount > 0 {
            issues.append(.init(
                code: .lowConfidenceGeometry,
                severity: .warning,
                message: "\(lowCount) element(s) have low or unknown capture confidence. Verify dimensions on site."
            ))
        }

        for diagnostic in captureDiagnostics {
            switch diagnostic {
            case .unsupportedCurvedWall(let sourceID):
                issues.append(.init(code: .unsupportedCapturedWall, severity: .warning, entityID: sourceID, message: "A curved RoomPlan wall was imported as a straight wall. Check it against the room."))
            case .unsupportedComplexWall(let sourceID, _):
                issues.append(.init(code: .unsupportedCapturedWall, severity: .warning, entityID: sourceID, message: "A non-rectangular RoomPlan wall (e.g. under a sloped ceiling) was imported as a full-height straight wall. Check its height."))
            case .missingHost(let sourceID, _):
                issues.append(.init(code: .captureRelationshipError, severity: .warning, entityID: sourceID, message: "RoomPlan opening evidence had no imported host wall."))
            case .invalidWallDirection(let sourceID), .invalidWallDimensions(let sourceID):
                issues.append(.init(code: .unsupportedCapturedWall, severity: .error, entityID: sourceID, message: "RoomPlan wall evidence was invalid and was skipped."))
            case .invalidOpeningDimensions(let sourceID):
                issues.append(.init(code: .captureRelationshipError, severity: .warning, entityID: sourceID, message: "RoomPlan opening evidence had invalid dimensions and was skipped."))
            case .openingExtendsBeyondHost(let sourceID, _), .openingVerticalExtentOutsideHost(let sourceID, _):
                issues.append(.init(code: .captureRelationshipError, severity: .warning, entityID: sourceID, message: "RoomPlan opening evidence required clipping to its host wall."))
            case .openingMostlyOutsideHost(let sourceID, _):
                issues.append(.init(code: .captureRelationshipError, severity: .warning, entityID: sourceID, message: "RoomPlan opening evidence lay mostly outside its host wall and was not imported."))
            }
        }

        if !generated.reconciliation.conflicts.isEmpty {
            issues.append(.init(
                code: .reconciliationConflict,
                severity: .warning,
                message: "\(generated.reconciliation.conflicts.count) multi-room reconciliation conflict(s) remain; the visible DXF will use safe fallback geometry."
            ))
        }

        let sortedIssues = issues.sorted {
            if severityRank($0.severity) != severityRank($1.severity) {
                return severityRank($0.severity) > severityRank($1.severity)
            }
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            return $0.message < $1.message
        }

        return ArchitecturalSurveyReadinessReport(
            roomCount: project.rooms.count,
            wallCount: project.rooms.reduce(0) { $0 + $1.walls.count },
            openingCount: project.rooms.reduce(0) { $0 + $1.openings.count },
            closedRoomCount: generated.topology.roomBoundaries.filter(\.isClosed).count,
            lowConfidenceElementCount: lowCount,
            issues: sortedIssues
        )
    }

    private func severityRank(_ severity: SurveyReadinessSeverity) -> Int {
        switch severity {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
}
