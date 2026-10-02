import Foundation

public enum PhysicalEditOpeningPolicy: String, Codable, Hashable, Sendable {
    /// Preserve each hosted opening's normalized center location along its source wall.
    /// This keeps openings attached to the wall as a physical partition changes length/orientation.
    case preserveNormalizedCenter
}

public struct PhysicalPartitionEditDraft: Codable, Hashable, Sendable {
    public var partitionID: String
    public var targetGeometry: CanonicalPartitionGeometry
    public var openingPolicy: PhysicalEditOpeningPolicy

    public init(
        partitionID: String,
        targetGeometry: CanonicalPartitionGeometry,
        openingPolicy: PhysicalEditOpeningPolicy = .preserveNormalizedCenter
    ) {
        self.partitionID = partitionID
        self.targetGeometry = targetGeometry
        self.openingPolicy = openingPolicy
    }
}

public struct PhysicalWallMutationPreview: Codable, Hashable, Sendable, Identifiable {
    public var roomID: UUID
    public var wallID: UUID
    public var before: PlanOpsisWall
    public var after: PlanOpsisWall

    public var id: String { "wall:\(roomID.uuidString):\(wallID.uuidString)" }

    public init(roomID: UUID, wallID: UUID, before: PlanOpsisWall, after: PlanOpsisWall) {
        self.roomID = roomID
        self.wallID = wallID
        self.before = before
        self.after = after
    }
}

public struct PhysicalOpeningMutationPreview: Codable, Hashable, Sendable, Identifiable {
    public var roomID: UUID
    public var openingID: UUID
    public var before: HostedOpeningParameters
    public var after: HostedOpeningParameters

    public var id: String { "opening:\(roomID.uuidString):\(openingID.uuidString)" }

    public init(roomID: UUID, openingID: UUID, before: HostedOpeningParameters, after: HostedOpeningParameters) {
        self.roomID = roomID
        self.openingID = openingID
        self.before = before
        self.after = after
    }
}

public struct PhysicalEditValidationIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case partitionNotFound
        case unresolvedPartition
        case invalidTargetLength
        case invalidTargetHeight
        case invalidTargetThickness
        case missingSourceWall
        case openingDoesNotFitLength
        case openingExceedsWallHeight
        case staleSemanticState
    }

    public var code: Code
    public var partitionID: String
    public var sourceID: UUID?
    public var magnitudeMM: Double?

    public var id: String {
        "physical-edit:\(code.rawValue):\(partitionID):\(sourceID?.uuidString ?? "none")"
    }

    public init(code: Code, partitionID: String, sourceID: UUID? = nil, magnitudeMM: Double? = nil) {
        self.code = code
        self.partitionID = partitionID
        self.sourceID = sourceID
        self.magnitudeMM = magnitudeMM
    }
}

public struct PhysicalPartitionEditPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var draft: PhysicalPartitionEditDraft
    public var wallMutations: [PhysicalWallMutationPreview]
    public var openingMutations: [PhysicalOpeningMutationPreview]
    public var issues: [PhysicalEditValidationIssue]

    public var canApply: Bool { issues.isEmpty && !wallMutations.isEmpty }

    public init(
        id: String,
        draft: PhysicalPartitionEditDraft,
        wallMutations: [PhysicalWallMutationPreview],
        openingMutations: [PhysicalOpeningMutationPreview],
        issues: [PhysicalEditValidationIssue]
    ) {
        self.id = id
        self.draft = draft
        self.wallMutations = wallMutations
        self.openingMutations = openingMutations
        self.issues = issues
    }
}

public struct PhysicalEditTransactionReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var partitionID: String
    public var wallMutations: [PhysicalWallMutationPreview]
    public var openingMutations: [PhysicalOpeningMutationPreview]

    public init(plan: PhysicalPartitionEditPlan) {
        id = "receipt:\(plan.id)"
        partitionID = plan.draft.partitionID
        wallMutations = plan.wallMutations
        openingMutations = plan.openingMutations
    }
}

public enum PhysicalEditTransactionError: Error, Equatable, Sendable {
    case invalidPlan
    case staleSemanticState
}

public struct PhysicalEditApplyResult: Hashable, Sendable {
    public var project: PlanOpsisProject
    public var receipt: PhysicalEditTransactionReceipt

    public init(project: PlanOpsisProject, receipt: PhysicalEditTransactionReceipt) {
        self.project = project
        self.receipt = receipt
    }
}

/// Approval-gated adapter between derived physical partitions and authoritative semantic state.
///
/// The engine never mutates reconciliation or display geometry. A physical edit is first expanded into
/// explicit semantic wall/opening mutations. The caller must inspect/approve the preview and then call
/// `apply`. Apply verifies the semantic project still equals the preview's `before` state and commits all
/// mutations to a copy, making the operation atomic from the caller's perspective.
public struct PhysicalPartitionEditTransactionEngine {
    private let epsilon: Double = 1e-8

    public init() {}

    public func draft(
        for partition: PhysicalPartition
    ) -> PhysicalPartitionEditDraft? {
        guard let geometry = partition.geometry, partition.resolution != .conflicted else { return nil }
        return PhysicalPartitionEditDraft(partitionID: partition.id, targetGeometry: geometry)
    }

    public func preview(
        draft: PhysicalPartitionEditDraft,
        project: PlanOpsisProject,
        reconciliation: StructureReconciliationSnapshot? = nil
    ) -> PhysicalPartitionEditPlan {
        let reconciliation = reconciliation ?? StructureReconciliationEngine().generate(from: project)
        guard let partition = reconciliation.partitions.first(where: { $0.id == draft.partitionID }) else {
            return invalidPlan(draft: draft, code: .partitionNotFound)
        }
        guard partition.geometry != nil, partition.resolution != .conflicted else {
            return invalidPlan(draft: draft, code: .unresolvedPartition)
        }

        let target = draft.targetGeometry
        var issues: [PhysicalEditValidationIssue] = []
        if target.length <= epsilon {
            issues.append(issue(.invalidTargetLength, draft.partitionID, magnitude: target.length))
        }
        if target.height <= epsilon {
            issues.append(issue(.invalidTargetHeight, draft.partitionID, magnitude: target.height))
        }
        if target.thickness <= epsilon {
            issues.append(issue(.invalidTargetThickness, draft.partitionID, magnitude: target.thickness))
        }
        guard issues.isEmpty else {
            return makePlan(draft: draft, walls: [], openings: [], issues: issues)
        }

        let targetDirection = (target.end - target.start).normalized
        var wallMutations: [PhysicalWallMutationPreview] = []
        var openingMutations: [PhysicalOpeningMutationPreview] = []

        for reference in partition.sourceWalls.sorted(by: referenceLessThan) {
            guard let location = locateWall(project: project, roomID: reference.roomID, wallID: reference.wallID) else {
                issues.append(issue(.missingSourceWall, draft.partitionID, sourceID: reference.wallID))
                continue
            }

            let before = location.wall
            var after = before
            let aligned = before.direction.dot(targetDirection) >= 0
            if aligned {
                after.start = target.start
                after.length = target.length
                after.angleRadians = target.angleRadians
            } else {
                after.start = target.end
                after.length = target.length
                after.angleRadians = normalizedAngle(target.angleRadians + .pi)
            }
            after.height = target.height
            after.thickness = target.thickness
            wallMutations.append(PhysicalWallMutationPreview(roomID: reference.roomID, wallID: before.id, before: before, after: after))

            for opening in location.room.openings
                .filter({ $0.parameters.hostWallID == before.id })
                .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let beforeParameters = opening.parameters
                var afterParameters = beforeParameters
                switch draft.openingPolicy {
                case .preserveNormalizedCenter:
                    let normalizedCenter = before.length > epsilon
                        ? min(1, max(0, beforeParameters.offsetAlongWall / before.length))
                        : 0.5
                    afterParameters.offsetAlongWall = normalizedCenter * after.length
                }

                let halfWidth = afterParameters.width * 0.5
                let leftClearance = afterParameters.offsetAlongWall - halfWidth
                let rightClearance = after.length - (afterParameters.offsetAlongWall + halfWidth)
                if leftClearance < -epsilon || rightClearance < -epsilon {
                    issues.append(issue(
                        .openingDoesNotFitLength,
                        draft.partitionID,
                        sourceID: opening.id,
                        magnitude: max(0, max(-leftClearance, -rightClearance))
                    ))
                }

                let verticalOverflow = afterParameters.sillHeight + afterParameters.height - after.height
                if verticalOverflow > epsilon {
                    issues.append(issue(
                        .openingExceedsWallHeight,
                        draft.partitionID,
                        sourceID: opening.id,
                        magnitude: verticalOverflow
                    ))
                }

                openingMutations.append(PhysicalOpeningMutationPreview(
                    roomID: reference.roomID,
                    openingID: opening.id,
                    before: beforeParameters,
                    after: afterParameters
                ))
            }
        }

        return makePlan(
            draft: draft,
            walls: wallMutations,
            openings: openingMutations,
            issues: issues.sorted { $0.id < $1.id }
        )
    }

    /// Materialize the approved preview into a value-copy of the semantic project without committing anything.
    /// UI layers can regenerate 2D/3D from this copy to show a truthful pre-commit preview.
    public func simulate(_ plan: PhysicalPartitionEditPlan, on project: PlanOpsisProject) throws -> PlanOpsisProject {
        guard plan.canApply else { throw PhysicalEditTransactionError.invalidPlan }
        guard semanticStateMatchesPreview(plan, project: project, expectAfter: false) else {
            throw PhysicalEditTransactionError.staleSemanticState
        }

        var next = project
        for mutation in plan.wallMutations {
            guard replaceWall(&next, roomID: mutation.roomID, wallID: mutation.wallID, expected: mutation.before, replacement: mutation.after) else {
                throw PhysicalEditTransactionError.staleSemanticState
            }
        }
        for mutation in plan.openingMutations {
            guard replaceOpeningParameters(&next, roomID: mutation.roomID, openingID: mutation.openingID, expected: mutation.before, replacement: mutation.after) else {
                throw PhysicalEditTransactionError.staleSemanticState
            }
        }
        return next
    }

    public func apply(_ plan: PhysicalPartitionEditPlan, to project: PlanOpsisProject) throws -> PhysicalEditApplyResult {
        let next = try simulate(plan, on: project)
        return PhysicalEditApplyResult(project: next, receipt: PhysicalEditTransactionReceipt(plan: plan))
    }

    public func undo(_ receipt: PhysicalEditTransactionReceipt, from project: PlanOpsisProject) throws -> PlanOpsisProject {
        guard receipt.wallMutations.allSatisfy({ mutation in
            locateWall(project: project, roomID: mutation.roomID, wallID: mutation.wallID)?.wall == mutation.after
        }), receipt.openingMutations.allSatisfy({ mutation in
            locateOpening(project: project, roomID: mutation.roomID, openingID: mutation.openingID)?.parameters == mutation.after
        }) else {
            throw PhysicalEditTransactionError.staleSemanticState
        }

        var next = project
        for mutation in receipt.wallMutations {
            guard replaceWall(&next, roomID: mutation.roomID, wallID: mutation.wallID, expected: mutation.after, replacement: mutation.before) else {
                throw PhysicalEditTransactionError.staleSemanticState
            }
        }
        for mutation in receipt.openingMutations {
            guard replaceOpeningParameters(&next, roomID: mutation.roomID, openingID: mutation.openingID, expected: mutation.after, replacement: mutation.before) else {
                throw PhysicalEditTransactionError.staleSemanticState
            }
        }
        return next
    }

    private func semanticStateMatchesPreview(_ plan: PhysicalPartitionEditPlan, project: PlanOpsisProject, expectAfter: Bool) -> Bool {
        let wallsMatch = plan.wallMutations.allSatisfy { mutation in
            guard let wall = locateWall(project: project, roomID: mutation.roomID, wallID: mutation.wallID)?.wall else { return false }
            return wall == (expectAfter ? mutation.after : mutation.before)
        }
        let openingsMatch = plan.openingMutations.allSatisfy { mutation in
            guard let opening = locateOpening(project: project, roomID: mutation.roomID, openingID: mutation.openingID) else { return false }
            return opening.parameters == (expectAfter ? mutation.after : mutation.before)
        }
        return wallsMatch && openingsMatch
    }

    private func invalidPlan(draft: PhysicalPartitionEditDraft, code: PhysicalEditValidationIssue.Code) -> PhysicalPartitionEditPlan {
        makePlan(draft: draft, walls: [], openings: [], issues: [issue(code, draft.partitionID)])
    }

    private func makePlan(
        draft: PhysicalPartitionEditDraft,
        walls: [PhysicalWallMutationPreview],
        openings: [PhysicalOpeningMutationPreview],
        issues: [PhysicalEditValidationIssue]
    ) -> PhysicalPartitionEditPlan {
        let target = draft.targetGeometry
        let signature = [
            draft.partitionID,
            fixed(target.start.x), fixed(target.start.y),
            fixed(target.end.x), fixed(target.end.y),
            fixed(target.height), fixed(target.thickness),
            draft.openingPolicy.rawValue,
            walls.map(\.id).sorted().joined(separator: ","),
            openings.map(\.id).sorted().joined(separator: ",")
        ].joined(separator: "|")
        return PhysicalPartitionEditPlan(
            id: "physical-edit:\(stableHash(signature))",
            draft: draft,
            wallMutations: walls.sorted { $0.id < $1.id },
            openingMutations: openings.sorted { $0.id < $1.id },
            issues: issues
        )
    }

    private func issue(
        _ code: PhysicalEditValidationIssue.Code,
        _ partitionID: String,
        sourceID: UUID? = nil,
        magnitude: Double? = nil
    ) -> PhysicalEditValidationIssue {
        PhysicalEditValidationIssue(code: code, partitionID: partitionID, sourceID: sourceID, magnitudeMM: magnitude)
    }

    private func referenceLessThan(_ lhs: SemanticWallReference, _ rhs: SemanticWallReference) -> Bool {
        if lhs.roomID == rhs.roomID { return lhs.wallID.uuidString < rhs.wallID.uuidString }
        return lhs.roomID.uuidString < rhs.roomID.uuidString
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle
        while value <= -.pi { value += 2 * .pi }
        while value > .pi { value -= 2 * .pi }
        return value
    }

    private func locateWall(project: PlanOpsisProject, roomID: UUID, wallID: UUID) -> (room: PlanOpsisRoom, wall: PlanOpsisWall)? {
        guard let room = project.rooms.first(where: { $0.id == roomID }), let wall = room.walls.first(where: { $0.id == wallID }) else { return nil }
        return (room, wall)
    }

    private func locateOpening(project: PlanOpsisProject, roomID: UUID, openingID: UUID) -> PlanOpsisOpening? {
        project.rooms.first(where: { $0.id == roomID })?.openings.first(where: { $0.id == openingID })
    }

    private func replaceWall(
        _ project: inout PlanOpsisProject,
        roomID: UUID,
        wallID: UUID,
        expected: PlanOpsisWall,
        replacement: PlanOpsisWall
    ) -> Bool {
        guard let roomIndex = project.rooms.firstIndex(where: { $0.id == roomID }),
              let wallIndex = project.rooms[roomIndex].walls.firstIndex(where: { $0.id == wallID }),
              project.rooms[roomIndex].walls[wallIndex] == expected else { return false }
        project.rooms[roomIndex].walls[wallIndex] = replacement
        return true
    }

    private func replaceOpeningParameters(
        _ project: inout PlanOpsisProject,
        roomID: UUID,
        openingID: UUID,
        expected: HostedOpeningParameters,
        replacement: HostedOpeningParameters
    ) -> Bool {
        guard let roomIndex = project.rooms.firstIndex(where: { $0.id == roomID }),
              let openingIndex = project.rooms[roomIndex].openings.firstIndex(where: { $0.id == openingID }),
              project.rooms[roomIndex].openings[openingIndex].parameters == expected else { return false }
        project.rooms[roomIndex].openings[openingIndex].parameters = replacement
        return true
    }

    private func fixed(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Deterministic FNV-1a identifier. This is for plan identity/debugging only, not cryptographic integrity.
    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
