import Foundation

public struct SemanticWallReference: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var wallID: UUID

    public init(roomID: UUID, wallID: UUID) {
        self.roomID = roomID
        self.wallID = wallID
    }
}

public struct SemanticOpeningReference: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var openingID: UUID

    public init(roomID: UUID, openingID: UUID) {
        self.roomID = roomID
        self.openingID = openingID
    }
}

public enum ReconciliationResolution: String, Codable, Hashable, Sendable {
    case singleSided
    case consensus
    case preferredHigherConfidence
    case conflicted
}

public struct CanonicalPartitionGeometry: Codable, Hashable, Sendable {
    public var start: Point2D
    public var end: Point2D
    public var height: Double
    public var thickness: Double

    public init(start: Point2D, end: Point2D, height: Double, thickness: Double) {
        self.start = start
        self.end = end
        self.height = height
        self.thickness = thickness
    }

    public var length: Double { (end - start).length }
    public var angleRadians: Double {
        let vector = end - start
        guard vector.length > 1e-9 else { return 0 }
        return atan2(vector.y, vector.x)
    }
}

public struct PhysicalPartition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceWalls: [SemanticWallReference]
    public var sourceSharedBoundaryID: String?
    public var resolution: ReconciliationResolution
    public var geometry: CanonicalPartitionGeometry?

    public init(
        id: String,
        sourceWalls: [SemanticWallReference],
        sourceSharedBoundaryID: String?,
        resolution: ReconciliationResolution,
        geometry: CanonicalPartitionGeometry?
    ) {
        self.id = id
        self.sourceWalls = sourceWalls
        self.sourceSharedBoundaryID = sourceSharedBoundaryID
        self.resolution = resolution
        self.geometry = geometry
    }

    public func contains(roomID: UUID) -> Bool {
        sourceWalls.contains { $0.roomID == roomID }
    }

    public func contains(wallID: UUID) -> Bool {
        sourceWalls.contains { $0.wallID == wallID }
    }
}

public struct CanonicalPassageGeometry: Codable, Hashable, Sendable {
    public var center: Point2D
    public var width: Double
    public var height: Double
    public var sillHeight: Double

    public init(center: Point2D, width: Double, height: Double, sillHeight: Double) {
        self.center = center
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
    }
}

public struct PhysicalPassage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var partitionID: String
    public var sourceOpenings: [SemanticOpeningReference]
    public var kind: RoomPassageConnection.Kind
    public var resolution: ReconciliationResolution
    public var geometry: CanonicalPassageGeometry?

    public init(
        id: String,
        partitionID: String,
        sourceOpenings: [SemanticOpeningReference],
        kind: RoomPassageConnection.Kind,
        resolution: ReconciliationResolution,
        geometry: CanonicalPassageGeometry?
    ) {
        self.id = id
        self.partitionID = partitionID
        self.sourceOpenings = sourceOpenings
        self.kind = kind
        self.resolution = resolution
        self.geometry = geometry
    }

    public func contains(roomID: UUID) -> Bool {
        sourceOpenings.contains { $0.roomID == roomID }
    }

    public func contains(openingID: UUID) -> Bool {
        sourceOpenings.contains { $0.openingID == openingID }
    }
}

public struct ReconciliationConflict: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case partitionEndpointMismatch
        case partitionHeightMismatch
        case partitionThicknessMismatch
        case ambiguousSharedBoundary
        case candidateSharedBoundary
        case passageWithoutResolvedPartition
        case passageCenterMismatch
        case passageWidthMismatch
        case passageHeightMismatch
        case passageSillMismatch
    }

    public var code: Code
    public var entityID: String
    public var magnitudeMM: Double?
    public var sourceIDs: [UUID]

    public var id: String {
        let ids = sourceIDs.map(\.uuidString).sorted().joined(separator: ":")
        return "reconcile:\(code.rawValue):\(entityID):\(ids)"
    }

    public init(code: Code, entityID: String, magnitudeMM: Double? = nil, sourceIDs: [UUID] = []) {
        self.code = code
        self.entityID = entityID
        self.magnitudeMM = magnitudeMM
        self.sourceIDs = sourceIDs
    }
}

public struct StructureReconciliationSnapshot: Codable, Hashable, Sendable {
    public var partitions: [PhysicalPartition]
    public var passages: [PhysicalPassage]
    public var conflicts: [ReconciliationConflict]

    public init(
        partitions: [PhysicalPartition] = [],
        passages: [PhysicalPassage] = [],
        conflicts: [ReconciliationConflict] = []
    ) {
        self.partitions = partitions
        self.passages = passages
        self.conflicts = conflicts
    }

    public static let empty = StructureReconciliationSnapshot()

    public func filtered(to roomID: UUID?) -> StructureReconciliationSnapshot {
        guard let roomID else { return self }
        let partitions = partitions.filter { $0.contains(roomID: roomID) }
        let partitionIDs = Set(partitions.map(\.id))
        return StructureReconciliationSnapshot(
            partitions: partitions,
            passages: passages.filter { $0.contains(roomID: roomID) || partitionIDs.contains($0.partitionID) },
            conflicts: conflicts.filter { conflict in
                !Set(conflict.sourceIDs).isDisjoint(with: sourceIDs(for: roomID))
            }
        )
    }

    private func sourceIDs(for roomID: UUID) -> Set<UUID> {
        let wallIDs = partitions.flatMap { partition in
            partition.sourceWalls.filter { $0.roomID == roomID }.map(\.wallID)
        }
        let openingIDs = passages.flatMap { passage in
            passage.sourceOpenings.filter { $0.roomID == roomID }.map(\.openingID)
        }
        return Set(wallIDs + openingIDs)
    }
}

/// Derived, reversible physical reconciliation over the semantic project and v4 topology evidence.
///
/// Rules:
/// - semantic PlanOpsis walls/openings remain authoritative and are never rewritten;
/// - only strong, unambiguous shared-boundary evidence is eligible for physical fusion;
/// - close measurements are fused by deterministic confidence-weighted consensus;
/// - material disagreements prefer higher-confidence evidence when confidence differs;
/// - equal-confidence material disagreements remain explicit conflicts with no canonical geometry.
public struct StructureReconciliationEngine {
    public struct Configuration: Hashable, Sendable {
        public var partitionEndpointToleranceMM: Double
        public var partitionHeightToleranceMM: Double
        public var partitionThicknessToleranceMM: Double
        public var passageCenterToleranceMM: Double
        public var passageWidthToleranceMM: Double
        public var passageHeightToleranceMM: Double
        public var passageSillToleranceMM: Double

        public init(
            partitionEndpointToleranceMM: Double = 180,
            partitionHeightToleranceMM: Double = 120,
            partitionThicknessToleranceMM: Double = 60,
            passageCenterToleranceMM: Double = 180,
            passageWidthToleranceMM: Double = 120,
            passageHeightToleranceMM: Double = 150,
            passageSillToleranceMM: Double = 120
        ) {
            self.partitionEndpointToleranceMM = partitionEndpointToleranceMM
            self.partitionHeightToleranceMM = partitionHeightToleranceMM
            self.partitionThicknessToleranceMM = partitionThicknessToleranceMM
            self.passageCenterToleranceMM = passageCenterToleranceMM
            self.passageWidthToleranceMM = passageWidthToleranceMM
            self.passageHeightToleranceMM = passageHeightToleranceMM
            self.passageSillToleranceMM = passageSillToleranceMM
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func generate(
        from project: PlanOpsisProject,
        topology: StructureTopologySnapshot? = nil
    ) -> StructureReconciliationSnapshot {
        let topology = topology ?? StructureTopologyEngine().generate(from: project)
        let ambiguousWallIDs = Set(topology.issues.compactMap { issue in
            issue.code == .ambiguousSharedBoundary ? issue.wallID : nil
        })

        var partitions: [PhysicalPartition] = []
        var conflicts: [ReconciliationConflict] = []
        var usedWalls = Set<UUID>()
        var partitionIDByBoundaryID: [String: String] = [:]

        for boundary in topology.sharedBoundaries.sorted(by: { $0.id < $1.id }) {
            guard boundary.strength == .strong else {
                conflicts.append(ReconciliationConflict(
                    code: .candidateSharedBoundary,
                    entityID: boundary.id,
                    magnitudeMM: boundary.centerlineSeparation,
                    sourceIDs: [boundary.wallAID, boundary.wallBID]
                ))
                continue
            }

            guard !ambiguousWallIDs.contains(boundary.wallAID), !ambiguousWallIDs.contains(boundary.wallBID) else {
                conflicts.append(ReconciliationConflict(
                    code: .ambiguousSharedBoundary,
                    entityID: boundary.id,
                    sourceIDs: [boundary.wallAID, boundary.wallBID]
                ))
                continue
            }

            guard
                let wallA = findWall(project: project, roomID: boundary.roomAID, wallID: boundary.wallAID),
                let wallB = findWall(project: project, roomID: boundary.roomBID, wallID: boundary.wallBID)
            else { continue }

            guard !usedWalls.contains(wallA.id), !usedWalls.contains(wallB.id) else {
                conflicts.append(ReconciliationConflict(
                    code: .ambiguousSharedBoundary,
                    entityID: boundary.id,
                    sourceIDs: [boundary.wallAID, boundary.wallBID]
                ))
                continue
            }

            let result = reconcilePartition(boundary: boundary, wallA: wallA, wallB: wallB)
            partitions.append(result.partition)
            conflicts.append(contentsOf: result.conflicts)
            usedWalls.insert(wallA.id)
            usedWalls.insert(wallB.id)
            partitionIDByBoundaryID[boundary.id] = result.partition.id
        }

        for room in project.rooms {
            for wall in room.walls where !usedWalls.contains(wall.id) {
                partitions.append(singleSidedPartition(roomID: room.id, wall: wall))
            }
        }

        var passages: [PhysicalPassage] = []
        for connection in topology.passageConnections.sorted(by: { $0.id < $1.id }) {
            guard let partitionID = partitionIDByBoundaryID[connection.sharedBoundaryID] else {
                conflicts.append(ReconciliationConflict(
                    code: .passageWithoutResolvedPartition,
                    entityID: connection.id,
                    sourceIDs: [connection.openingAID, connection.openingBID]
                ))
                continue
            }

            guard let partition = partitions.first(where: { $0.id == partitionID }), partition.geometry != nil else {
                conflicts.append(ReconciliationConflict(
                    code: .passageWithoutResolvedPartition,
                    entityID: connection.id,
                    sourceIDs: [connection.openingAID, connection.openingBID]
                ))
                continue
            }

            guard
                let openingA = findOpening(project: project, roomID: connection.roomAID, openingID: connection.openingAID),
                let openingB = findOpening(project: project, roomID: connection.roomBID, openingID: connection.openingBID),
                let wallA = findWall(project: project, roomID: connection.roomAID, wallID: openingA.parameters.hostWallID),
                let wallB = findWall(project: project, roomID: connection.roomBID, wallID: openingB.parameters.hostWallID)
            else { continue }

            let result = reconcilePassage(
                connection: connection,
                partitionID: partitionID,
                openingA: openingA,
                wallA: wallA,
                openingB: openingB,
                wallB: wallB
            )
            passages.append(result.passage)
            conflicts.append(contentsOf: result.conflicts)
        }

        return StructureReconciliationSnapshot(
            partitions: partitions.sorted { $0.id < $1.id },
            passages: passages.sorted { $0.id < $1.id },
            conflicts: conflicts.sorted { $0.id < $1.id }
        )
    }

    private struct PartitionResult {
        var partition: PhysicalPartition
        var conflicts: [ReconciliationConflict]
    }

    private func reconcilePartition(boundary: SharedBoundary, wallA: PlanOpsisWall, wallB: PlanOpsisWall) -> PartitionResult {
        let id = partitionID(wallA.id, wallB.id)
        let refs = [
            SemanticWallReference(roomID: boundary.roomAID, wallID: wallA.id),
            SemanticWallReference(roomID: boundary.roomBID, wallID: wallB.id)
        ]

        let bDirectionAligned = wallA.direction.dot(wallB.direction) >= 0
        let bStart = bDirectionAligned ? wallB.start : wallB.end
        let bEnd = bDirectionAligned ? wallB.end : wallB.start

        let startResult = resolvePoint(
            wallA.start,
            confidenceA: wallA.confidence,
            bStart,
            confidenceB: wallB.confidence,
            tolerance: configuration.partitionEndpointToleranceMM
        )
        let endResult = resolvePoint(
            wallA.end,
            confidenceA: wallA.confidence,
            bEnd,
            confidenceB: wallB.confidence,
            tolerance: configuration.partitionEndpointToleranceMM
        )
        let heightResult = resolveScalar(
            wallA.height,
            confidenceA: wallA.confidence,
            wallB.height,
            confidenceB: wallB.confidence,
            tolerance: configuration.partitionHeightToleranceMM
        )
        let thicknessResult = resolveScalar(
            wallA.thickness,
            confidenceA: wallA.confidence,
            wallB.thickness,
            confidenceB: wallB.confidence,
            tolerance: configuration.partitionThicknessToleranceMM
        )

        var conflicts: [ReconciliationConflict] = []
        if startResult.value == nil || endResult.value == nil {
            conflicts.append(ReconciliationConflict(
                code: .partitionEndpointMismatch,
                entityID: id,
                magnitudeMM: max((wallA.start - bStart).length, (wallA.end - bEnd).length),
                sourceIDs: [wallA.id, wallB.id]
            ))
        }
        if heightResult.value == nil {
            conflicts.append(ReconciliationConflict(
                code: .partitionHeightMismatch,
                entityID: id,
                magnitudeMM: abs(wallA.height - wallB.height),
                sourceIDs: [wallA.id, wallB.id]
            ))
        }
        if thicknessResult.value == nil {
            conflicts.append(ReconciliationConflict(
                code: .partitionThicknessMismatch,
                entityID: id,
                magnitudeMM: abs(wallA.thickness - wallB.thickness),
                sourceIDs: [wallA.id, wallB.id]
            ))
        }

        let geometry: CanonicalPartitionGeometry?
        if let start = startResult.value, let end = endResult.value, let height = heightResult.value, let thickness = thicknessResult.value {
            geometry = CanonicalPartitionGeometry(start: start, end: end, height: height, thickness: thickness)
        } else {
            geometry = nil
        }

        let usedPreference = startResult.usedHigherConfidence || endResult.usedHigherConfidence || heightResult.usedHigherConfidence || thicknessResult.usedHigherConfidence
        let resolution: ReconciliationResolution = geometry == nil
            ? .conflicted
            : (usedPreference ? .preferredHigherConfidence : .consensus)

        return PartitionResult(
            partition: PhysicalPartition(
                id: id,
                sourceWalls: refs,
                sourceSharedBoundaryID: boundary.id,
                resolution: resolution,
                geometry: geometry
            ),
            conflicts: conflicts
        )
    }

    private func singleSidedPartition(roomID: UUID, wall: PlanOpsisWall) -> PhysicalPartition {
        PhysicalPartition(
            id: "partition:wall:\(wall.id.uuidString)",
            sourceWalls: [SemanticWallReference(roomID: roomID, wallID: wall.id)],
            sourceSharedBoundaryID: nil,
            resolution: .singleSided,
            geometry: CanonicalPartitionGeometry(start: wall.start, end: wall.end, height: wall.height, thickness: wall.thickness)
        )
    }

    private struct PassageResult {
        var passage: PhysicalPassage
        var conflicts: [ReconciliationConflict]
    }

    private func reconcilePassage(
        connection: RoomPassageConnection,
        partitionID: String,
        openingA: PlanOpsisOpening,
        wallA: PlanOpsisWall,
        openingB: PlanOpsisOpening,
        wallB: PlanOpsisWall
    ) -> PassageResult {
        let id = "physical:\(connection.id)"
        let pA = openingA.parameters
        let pB = openingB.parameters
        let centerA = wallA.start + wallA.direction * pA.offsetAlongWall
        let centerB = wallB.start + wallB.direction * pB.offsetAlongWall

        let centerResult = resolvePoint(centerA, confidenceA: pA.confidence, centerB, confidenceB: pB.confidence, tolerance: configuration.passageCenterToleranceMM)
        let widthResult = resolveScalar(pA.width, confidenceA: pA.confidence, pB.width, confidenceB: pB.confidence, tolerance: configuration.passageWidthToleranceMM)
        let heightResult = resolveScalar(pA.height, confidenceA: pA.confidence, pB.height, confidenceB: pB.confidence, tolerance: configuration.passageHeightToleranceMM)
        let sillResult = resolveScalar(pA.sillHeight, confidenceA: pA.confidence, pB.sillHeight, confidenceB: pB.confidence, tolerance: configuration.passageSillToleranceMM)

        var conflicts: [ReconciliationConflict] = []
        if centerResult.value == nil {
            conflicts.append(ReconciliationConflict(code: .passageCenterMismatch, entityID: id, magnitudeMM: (centerA - centerB).length, sourceIDs: [openingA.id, openingB.id]))
        }
        if widthResult.value == nil {
            conflicts.append(ReconciliationConflict(code: .passageWidthMismatch, entityID: id, magnitudeMM: abs(pA.width - pB.width), sourceIDs: [openingA.id, openingB.id]))
        }
        if heightResult.value == nil {
            conflicts.append(ReconciliationConflict(code: .passageHeightMismatch, entityID: id, magnitudeMM: abs(pA.height - pB.height), sourceIDs: [openingA.id, openingB.id]))
        }
        if sillResult.value == nil {
            conflicts.append(ReconciliationConflict(code: .passageSillMismatch, entityID: id, magnitudeMM: abs(pA.sillHeight - pB.sillHeight), sourceIDs: [openingA.id, openingB.id]))
        }

        let geometry: CanonicalPassageGeometry?
        if let center = centerResult.value, let width = widthResult.value, let height = heightResult.value, let sill = sillResult.value {
            geometry = CanonicalPassageGeometry(center: center, width: width, height: height, sillHeight: sill)
        } else {
            geometry = nil
        }

        let usedPreference = centerResult.usedHigherConfidence || widthResult.usedHigherConfidence || heightResult.usedHigherConfidence || sillResult.usedHigherConfidence
        let resolution: ReconciliationResolution = geometry == nil
            ? .conflicted
            : (usedPreference ? .preferredHigherConfidence : .consensus)

        return PassageResult(
            passage: PhysicalPassage(
                id: id,
                partitionID: partitionID,
                sourceOpenings: [
                    SemanticOpeningReference(roomID: connection.roomAID, openingID: openingA.id),
                    SemanticOpeningReference(roomID: connection.roomBID, openingID: openingB.id)
                ],
                kind: connection.kind,
                resolution: resolution,
                geometry: geometry
            ),
            conflicts: conflicts
        )
    }

    private struct Resolution<T> {
        var value: T?
        var usedHigherConfidence: Bool
    }

    private func resolvePoint(
        _ a: Point2D,
        confidenceA: CaptureConfidence,
        _ b: Point2D,
        confidenceB: CaptureConfidence,
        tolerance: Double
    ) -> Resolution<Point2D> {
        let delta = (a - b).length
        if delta <= tolerance {
            let weights = (confidenceWeight(confidenceA), confidenceWeight(confidenceB))
            let total = weights.0 + weights.1
            return Resolution(
                value: Point2D(
                    x: (a.x * weights.0 + b.x * weights.1) / total,
                    y: (a.y * weights.0 + b.y * weights.1) / total
                ),
                usedHigherConfidence: false
            )
        }
        let rankA = confidenceRank(confidenceA)
        let rankB = confidenceRank(confidenceB)
        if rankA > rankB { return Resolution(value: a, usedHigherConfidence: true) }
        if rankB > rankA { return Resolution(value: b, usedHigherConfidence: true) }
        return Resolution(value: nil, usedHigherConfidence: false)
    }

    private func resolveScalar(
        _ a: Double,
        confidenceA: CaptureConfidence,
        _ b: Double,
        confidenceB: CaptureConfidence,
        tolerance: Double
    ) -> Resolution<Double> {
        let delta = abs(a - b)
        if delta <= tolerance {
            let weightA = confidenceWeight(confidenceA)
            let weightB = confidenceWeight(confidenceB)
            return Resolution(value: (a * weightA + b * weightB) / (weightA + weightB), usedHigherConfidence: false)
        }
        let rankA = confidenceRank(confidenceA)
        let rankB = confidenceRank(confidenceB)
        if rankA > rankB { return Resolution(value: a, usedHigherConfidence: true) }
        if rankB > rankA { return Resolution(value: b, usedHigherConfidence: true) }
        return Resolution(value: nil, usedHigherConfidence: false)
    }

    private func confidenceRank(_ confidence: CaptureConfidence) -> Int {
        switch confidence {
        case .unknown: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    private func confidenceWeight(_ confidence: CaptureConfidence) -> Double {
        switch confidence {
        case .unknown, .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    private func partitionID(_ a: UUID, _ b: UUID) -> String {
        let ids = [a.uuidString, b.uuidString].sorted()
        return "partition:shared:\(ids[0]):\(ids[1])"
    }

    private func findWall(project: PlanOpsisProject, roomID: UUID, wallID: UUID) -> PlanOpsisWall? {
        project.rooms.first(where: { $0.id == roomID })?.walls.first(where: { $0.id == wallID })
    }

    private func findOpening(project: PlanOpsisProject, roomID: UUID, openingID: UUID) -> PlanOpsisOpening? {
        project.rooms.first(where: { $0.id == roomID })?.openings.first(where: { $0.id == openingID })
    }
}
