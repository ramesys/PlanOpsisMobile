import Foundation

public enum GeometryRepresentationMode: String, Codable, Hashable, Sendable, CaseIterable {
    case semanticObservations
    case reconciledPhysical
}

public enum DisplayOpeningKind: String, Codable, Hashable, Sendable {
    case opening
    case door
    case window
    case mixedPassage
}

public struct DisplayWallPlanSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var partitionID: String
    public var sourceRoomIDs: [UUID]
    public var sourceWallIDs: [UUID]
    public var startOffset: Double
    public var length: Double
    public var thickness: Double
    public var footprint: [Point2D]

    public init(id: String, partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], startOffset: Double, length: Double, thickness: Double, footprint: [Point2D]) {
        self.id = id
        self.partitionID = partitionID
        self.sourceRoomIDs = sourceRoomIDs
        self.sourceWallIDs = sourceWallIDs
        self.startOffset = startOffset
        self.length = length
        self.thickness = thickness
        self.footprint = footprint
    }

    public func contains(roomID: UUID) -> Bool { sourceRoomIDs.contains(roomID) }
    public func contains(selectionID: UUID?) -> Bool { selectionID.map(sourceWallIDs.contains) ?? false }
    public var primarySelectionID: UUID? { sourceWallIDs.sorted { $0.uuidString < $1.uuidString }.first }
}

public struct DisplayWallSolidSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var partitionID: String
    public var sourceRoomIDs: [UUID]
    public var sourceWallIDs: [UUID]
    public var kind: WallSolidSegment.SegmentKind
    public var startOffset: Double
    public var length: Double
    public var bottom: Double
    public var height: Double
    public var thickness: Double
    public var center: Point2D
    public var angleRadians: Double
    public var renderLength: Double
    public var renderCenter: Point2D
    public var renderAngleRadians: Double

    public init(id: String, partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], kind: WallSolidSegment.SegmentKind, startOffset: Double, length: Double, bottom: Double, height: Double, thickness: Double, center: Point2D, angleRadians: Double, renderLength: Double? = nil, renderCenter: Point2D? = nil, renderAngleRadians: Double? = nil) {
        self.id = id
        self.partitionID = partitionID
        self.sourceRoomIDs = sourceRoomIDs
        self.sourceWallIDs = sourceWallIDs
        self.kind = kind
        self.startOffset = startOffset
        self.length = length
        self.bottom = bottom
        self.height = height
        self.thickness = thickness
        self.center = center
        self.angleRadians = angleRadians
        self.renderLength = renderLength ?? length
        self.renderCenter = renderCenter ?? center
        self.renderAngleRadians = renderAngleRadians ?? angleRadians
    }

    public func contains(roomID: UUID) -> Bool { sourceRoomIDs.contains(roomID) }
    public func contains(selectionID: UUID?) -> Bool { selectionID.map(sourceWallIDs.contains) ?? false }
    public var primarySelectionID: UUID? { sourceWallIDs.sorted { $0.uuidString < $1.uuidString }.first }
}

public struct DisplayOpeningGeometry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var hostPartitionID: String
    public var sourceRoomIDs: [UUID]
    public var sourceOpeningIDs: [UUID]
    public var kind: DisplayOpeningKind
    public var center: Point2D
    public var width: Double
    public var height: Double
    public var sillHeight: Double
    public var angleRadians: Double
    public var thickness: Double
    public var doorSwing: PlanOpsisDoor.Swing
    public var doorOperation: PlanOpsisDoor.Operation?
    public var windowOperation: PlanOpsisWindow.Operation?
    /// True only when this evidence is sufficiently resolved to remove material from the displayed partition.
    public var cutsWall: Bool

    public init(id: String, hostPartitionID: String, sourceRoomIDs: [UUID], sourceOpeningIDs: [UUID], kind: DisplayOpeningKind, center: Point2D, width: Double, height: Double, sillHeight: Double, angleRadians: Double, thickness: Double, doorSwing: PlanOpsisDoor.Swing = .unspecified, doorOperation: PlanOpsisDoor.Operation? = nil, windowOperation: PlanOpsisWindow.Operation? = nil, cutsWall: Bool) {
        self.id = id
        self.hostPartitionID = hostPartitionID
        self.sourceRoomIDs = sourceRoomIDs
        self.sourceOpeningIDs = sourceOpeningIDs
        self.kind = kind
        self.center = center
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
        self.angleRadians = angleRadians
        self.thickness = thickness
        self.doorSwing = doorSwing
        self.doorOperation = doorOperation
        self.windowOperation = windowOperation
        self.cutsWall = cutsWall
    }

    public func contains(roomID: UUID) -> Bool { sourceRoomIDs.contains(roomID) }
    public func contains(selectionID: UUID?) -> Bool { selectionID.map(sourceOpeningIDs.contains) ?? false }
    public var primarySelectionID: UUID? { sourceOpeningIDs.sorted { $0.uuidString < $1.uuidString }.first }
}

public struct PhysicalDisplayIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case conflictedPartitionSemanticFallback
        case conflictedPassageEvidenceOnly
        case sourceOpeningCouldNotProject
    }

    public var code: Code
    public var entityID: String
    public var sourceIDs: [UUID]

    public var id: String {
        "physical-display:\(code.rawValue):\(entityID):\(sourceIDs.map(\.uuidString).sorted().joined(separator: ":"))"
    }

    public init(code: Code, entityID: String, sourceIDs: [UUID] = []) {
        self.code = code
        self.entityID = entityID
        self.sourceIDs = sourceIDs
    }
}

public struct DisplayGeometrySnapshot: Codable, Hashable, Sendable {
    public var representation: GeometryRepresentationMode
    public var planWallSegments: [DisplayWallPlanSegment]
    public var wallSolids: [DisplayWallSolidSegment]
    public var hostedOpenings: [DisplayOpeningGeometry]
    public var roomFloors: [RoomFloorGeometry]
    public var topology: StructureTopologySnapshot
    public var reconciliation: StructureReconciliationSnapshot
    public var issues: [PhysicalDisplayIssue]

    public init(
        representation: GeometryRepresentationMode,
        planWallSegments: [DisplayWallPlanSegment] = [],
        wallSolids: [DisplayWallSolidSegment] = [],
        hostedOpenings: [DisplayOpeningGeometry] = [],
        roomFloors: [RoomFloorGeometry] = [],
        topology: StructureTopologySnapshot = .empty,
        reconciliation: StructureReconciliationSnapshot = .empty,
        issues: [PhysicalDisplayIssue] = []
    ) {
        self.representation = representation
        self.planWallSegments = planWallSegments
        self.wallSolids = wallSolids
        self.hostedOpenings = hostedOpenings
        self.roomFloors = roomFloors
        self.topology = topology
        self.reconciliation = reconciliation
        self.issues = issues
    }

    public static let empty = DisplayGeometrySnapshot(representation: .semanticObservations)

    public var floor: FloorGeometry? {
        guard let first = roomFloors.first?.bounds else { return nil }
        var minX = first.min.x
        var minY = first.min.y
        var maxX = first.max.x
        var maxY = first.max.y
        for bounds in roomFloors.dropFirst().map(\.bounds) {
            minX = min(minX, bounds.min.x)
            minY = min(minY, bounds.min.y)
            maxX = max(maxX, bounds.max.x)
            maxY = max(maxY, bounds.max.y)
        }
        return FloorGeometry(min: Point2D(x: minX, y: minY), max: Point2D(x: maxX, y: maxY))
    }

    public var physicalPartitionIDs: Set<String> { Set(planWallSegments.map(\.partitionID) + wallSolids.map(\.partitionID)) }

    public func filtered(to roomID: UUID?) -> DisplayGeometrySnapshot {
        guard let roomID else { return self }
        let relevantSourceIDs = Set(
            planWallSegments.filter { $0.contains(roomID: roomID) }.flatMap(\.sourceWallIDs) +
            hostedOpenings.filter { $0.contains(roomID: roomID) }.flatMap(\.sourceOpeningIDs)
        )
        return DisplayGeometrySnapshot(
            representation: representation,
            planWallSegments: planWallSegments.filter { $0.contains(roomID: roomID) },
            wallSolids: wallSolids.filter { $0.contains(roomID: roomID) },
            hostedOpenings: hostedOpenings.filter { $0.contains(roomID: roomID) },
            roomFloors: roomFloors.filter { $0.roomID == roomID },
            topology: topology.filtered(to: roomID),
            reconciliation: reconciliation.filtered(to: roomID),
            issues: issues.filter { !Set($0.sourceIDs).isDisjoint(with: relevantSourceIDs) }
        )
    }
}

public extension ArchitecturalGeometrySnapshot {
    func semanticDisplaySnapshot() -> DisplayGeometrySnapshot {
        DisplayGeometrySnapshot(
            representation: .semanticObservations,
            planWallSegments: planWallSegments.map { segment in
                DisplayWallPlanSegment(
                    id: "semantic:\(segment.id)",
                    partitionID: "semantic:wall:\(segment.hostWallID.uuidString)",
                    sourceRoomIDs: [segment.roomID],
                    sourceWallIDs: [segment.hostWallID],
                    startOffset: segment.startOffset,
                    length: segment.length,
                    thickness: segment.thickness,
                    footprint: segment.footprint
                )
            },
            wallSolids: wallSolids.map { solid in
                DisplayWallSolidSegment(
                    id: "semantic:\(solid.id)",
                    partitionID: "semantic:wall:\(solid.hostWallID.uuidString)",
                    sourceRoomIDs: [solid.roomID],
                    sourceWallIDs: [solid.hostWallID],
                    kind: solid.kind,
                    startOffset: solid.startOffset,
                    length: solid.length,
                    bottom: solid.bottom,
                    height: solid.height,
                    thickness: solid.thickness,
                    center: solid.center,
                    angleRadians: solid.angleRadians,
                    renderLength: solid.renderLength,
                    renderCenter: solid.renderCenter,
                    renderAngleRadians: solid.renderAngleRadians
                )
            },
            hostedOpenings: hostedOpenings.map { opening in
                DisplayOpeningGeometry(
                    id: "semantic:opening:\(opening.id.uuidString)",
                    hostPartitionID: "semantic:wall:\(opening.hostWallID.uuidString)",
                    sourceRoomIDs: [opening.roomID],
                    sourceOpeningIDs: [opening.id],
                    kind: DisplayOpeningKind(opening.kind),
                    center: opening.center,
                    width: opening.width,
                    height: opening.height,
                    sillHeight: opening.sillHeight,
                    angleRadians: opening.angleRadians,
                    thickness: opening.thickness,
                    doorSwing: opening.doorSwing,
                    doorOperation: opening.doorOperation,
                    windowOperation: opening.windowOperation,
                    cutsWall: true
                )
            },
            roomFloors: roomFloors,
            topology: topology,
            reconciliation: reconciliation
        )
    }
}

private extension DisplayOpeningKind {
    init(_ kind: PlanOpsisOpening.Kind) {
        switch kind {
        case .opening: self = .opening
        case .door: self = .door
        case .window: self = .window
        }
    }

    init(_ kind: RoomPassageConnection.Kind) {
        switch kind {
        case .door: self = .door
        case .genericOpening: self = .opening
        case .mixed: self = .mixedPassage
        }
    }
}

/// v6 display-only consolidation.
///
/// This engine never mutates `PlanOpsisProject` and never persists physical geometry. Resolved
/// reconciliation is allowed to replace duplicate *presentation* geometry. Conflicted evidence
/// falls back to semantic geometry or evidence-only markers instead of fabricating certainty.
private struct PhysicalPartitionJoinFlags: Hashable, Sendable {
    var joinedAtStart: Bool
    var joinedAtEnd: Bool
}

public struct PhysicalDisplayGeometryEngine {
    public struct Configuration: Hashable, Sendable {
        /// Maximum perpendicular distance for projecting a single-sided opening observation onto
        /// an already-resolved physical partition.
        public var openingProjectionToleranceMM: Double

        public init(openingProjectionToleranceMM: Double = 250) {
            self.openingProjectionToleranceMM = openingProjectionToleranceMM
        }
    }

    private let configuration: Configuration
    private let epsilon = 1e-9

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func generate(from project: PlanOpsisProject, semanticGeometry: ArchitecturalGeometrySnapshot? = nil) -> DisplayGeometrySnapshot {
        let semanticGeometry = semanticGeometry ?? ParametricGeometryEngine().generate(from: project)
        let reconciliation = semanticGeometry.reconciliation
        var planSegments: [DisplayWallPlanSegment] = []
        var solids: [DisplayWallSolidSegment] = []
        var openings: [DisplayOpeningGeometry] = []
        var issues: [PhysicalDisplayIssue] = []
        let joinFlags = partitionJoinFlags(reconciliation.partitions)

        for partition in reconciliation.partitions.sorted(by: { $0.id < $1.id }) {
            guard let geometry = partition.geometry else {
                appendSemanticFallback(
                    partition: partition,
                    semanticGeometry: semanticGeometry,
                    planSegments: &planSegments,
                    solids: &solids,
                    openings: &openings
                )
                issues.append(PhysicalDisplayIssue(
                    code: .conflictedPartitionSemanticFallback,
                    entityID: partition.id,
                    sourceIDs: partition.sourceWalls.map(\.wallID)
                ))
                continue
            }

            let sourceRoomIDs = sortedUnique(partition.sourceWalls.map(\.roomID))
            let sourceWallIDs = sortedUnique(partition.sourceWalls.map(\.wallID))
            let direction = (geometry.end - geometry.start).normalized
            let normal = Point2D(x: -direction.y, y: direction.x)
            let joins = joinFlags[partition.id] ?? PhysicalPartitionJoinFlags(joinedAtStart: false, joinedAtEnd: false)

            var cutVoids: [PhysicalVoid] = []
            var consumedOpeningIDs = Set<UUID>()

            let partitionPassages = reconciliation.passages.filter { $0.partitionID == partition.id }.sorted { $0.id < $1.id }
            for passage in partitionPassages {
                if let passageGeometry = passage.geometry,
                   let projected = projectedVoid(
                    center: passageGeometry.center,
                    width: passageGeometry.width,
                    height: passageGeometry.height,
                    sillHeight: passageGeometry.sillHeight,
                    partition: geometry,
                    enforceProjectionTolerance: false
                   ) {
                    consumedOpeningIDs.formUnion(passage.sourceOpenings.map(\.openingID))
                    cutVoids.append(projected)
                    openings.append(DisplayOpeningGeometry(
                        id: passage.id,
                        hostPartitionID: partition.id,
                        sourceRoomIDs: sortedUnique(passage.sourceOpenings.map(\.roomID)),
                        sourceOpeningIDs: sortedUnique(passage.sourceOpenings.map(\.openingID)),
                        kind: DisplayOpeningKind(passage.kind),
                        center: geometry.start + direction * projected.centerOffset,
                        width: projected.endOffset - projected.startOffset,
                        height: projected.top - projected.bottom,
                        sillHeight: projected.bottom,
                        angleRadians: geometry.angleRadians,
                        thickness: geometry.thickness,
                        doorSwing: resolvedDoorSwing(for: passage.sourceOpenings, in: project),
                        doorOperation: resolvedDoorOperation(for: passage.sourceOpenings, in: project),
                        windowOperation: resolvedWindowOperation(for: passage.sourceOpenings, in: project),
                        cutsWall: true
                    ))
                } else {
                    consumedOpeningIDs.formUnion(passage.sourceOpenings.map(\.openingID))
                    issues.append(PhysicalDisplayIssue(
                        code: .conflictedPassageEvidenceOnly,
                        entityID: passage.id,
                        sourceIDs: passage.sourceOpenings.map(\.openingID)
                    ))
                    for reference in passage.sourceOpenings {
                        if let evidence = semanticOpeningGeometry(reference: reference, semanticGeometry: semanticGeometry) {
                            openings.append(DisplayOpeningGeometry(
                                id: "evidence:\(passage.id):\(reference.openingID.uuidString)",
                                hostPartitionID: partition.id,
                                sourceRoomIDs: [reference.roomID],
                                sourceOpeningIDs: [reference.openingID],
                                kind: DisplayOpeningKind(evidence.kind),
                                center: evidence.center,
                                width: evidence.width,
                                height: evidence.height,
                                sillHeight: evidence.sillHeight,
                                angleRadians: geometry.angleRadians,
                                thickness: geometry.thickness,
                                doorSwing: evidence.doorSwing,
                                doorOperation: evidence.doorOperation,
                                windowOperation: evidence.windowOperation,
                                cutsWall: false
                            ))
                        }
                    }
                }
            }

            // Preserve single-sided opening evidence on a reconciled wall. It may cut the physical
            // display only when it can be projected close to the canonical partition.
            for reference in partition.sourceWalls {
                guard let room = project.rooms.first(where: { $0.id == reference.roomID }) else { continue }
                for opening in room.openings where opening.parameters.hostWallID == reference.wallID && !consumedOpeningIDs.contains(opening.id) {
                    guard let sourceWall = room.walls.first(where: { $0.id == reference.wallID }) else { continue }
                    let sourceCenter = sourceWall.start + sourceWall.direction * opening.parameters.offsetAlongWall
                    guard let projected = projectedVoid(
                        center: sourceCenter,
                        width: opening.parameters.width,
                        height: opening.parameters.height,
                        sillHeight: opening.parameters.sillHeight,
                        partition: geometry,
                        enforceProjectionTolerance: true
                    ) else {
                        issues.append(PhysicalDisplayIssue(
                            code: .sourceOpeningCouldNotProject,
                            entityID: partition.id,
                            sourceIDs: [opening.id, reference.wallID]
                        ))
                        if let evidence = semanticGeometry.hostedOpenings.first(where: { $0.id == opening.id }) {
                            openings.append(DisplayOpeningGeometry(
                                id: "evidence:unprojected:\(opening.id.uuidString)",
                                hostPartitionID: partition.id,
                                sourceRoomIDs: [reference.roomID],
                                sourceOpeningIDs: [opening.id],
                                kind: DisplayOpeningKind(evidence.kind),
                                center: evidence.center,
                                width: evidence.width,
                                height: evidence.height,
                                sillHeight: evidence.sillHeight,
                                angleRadians: evidence.angleRadians,
                                thickness: evidence.thickness,
                                doorSwing: evidence.doorSwing,
                                doorOperation: evidence.doorOperation,
                                windowOperation: evidence.windowOperation,
                                cutsWall: false
                            ))
                        }
                        continue
                    }
                    cutVoids.append(projected)
                    openings.append(DisplayOpeningGeometry(
                        id: "physical:source-opening:\(opening.id.uuidString)",
                        hostPartitionID: partition.id,
                        sourceRoomIDs: [reference.roomID],
                        sourceOpeningIDs: [opening.id],
                        kind: DisplayOpeningKind(opening.kind),
                        center: geometry.start + direction * projected.centerOffset,
                        width: projected.endOffset - projected.startOffset,
                        height: projected.top - projected.bottom,
                        sillHeight: projected.bottom,
                        angleRadians: geometry.angleRadians,
                        thickness: geometry.thickness,
                        doorSwing: opening.doorSwing ?? .unspecified,
                        doorOperation: opening.doorOperation,
                        windowOperation: opening.windowOperation,
                        cutsWall: true
                    ))
                }
            }

            let horizontalVoids = mergeIntervals(cutVoids.map { ($0.startOffset, $0.endOffset) })
            appendPlanSegmentsOutside(
                partitionID: partition.id,
                sourceRoomIDs: sourceRoomIDs,
                sourceWallIDs: sourceWallIDs,
                geometry: geometry,
                horizontalVoids: horizontalVoids,
                direction: direction,
                normal: normal,
                joins: joins,
                output: &planSegments
            )
            appendSolidSegments(
                partitionID: partition.id,
                sourceRoomIDs: sourceRoomIDs,
                sourceWallIDs: sourceWallIDs,
                geometry: geometry,
                voids: cutVoids,
                direction: direction,
                joins: joins,
                output: &solids
            )
        }

        return DisplayGeometrySnapshot(
            representation: .reconciledPhysical,
            planWallSegments: planSegments.sorted { $0.id < $1.id },
            wallSolids: solids.sorted { $0.id < $1.id },
            hostedOpenings: openings.sorted { $0.id < $1.id },
            roomFloors: semanticGeometry.roomFloors,
            topology: semanticGeometry.topology,
            reconciliation: reconciliation,
            issues: issues.sorted { $0.id < $1.id }
        )
    }

    private func resolvedDoorSwing(for references: [SemanticOpeningReference], in project: PlanOpsisProject) -> PlanOpsisDoor.Swing {
        let swings: [PlanOpsisDoor.Swing] = references.compactMap { reference in
            guard let room = project.rooms.first(where: { $0.id == reference.roomID }),
                  let opening = room.openings.first(where: { $0.id == reference.openingID }),
                  opening.kind == .door else { return nil }
            return opening.doorSwing ?? .unspecified
        }
        let explicit = Set(swings.filter { $0 != .unspecified })
        return explicit.count == 1 ? (explicit.first ?? .unspecified) : .unspecified
    }

    private func resolvedDoorOperation(for references: [SemanticOpeningReference], in project: PlanOpsisProject) -> PlanOpsisDoor.Operation? {
        let values = references.compactMap { reference -> PlanOpsisDoor.Operation? in
            project.rooms.first(where: { $0.id == reference.roomID })?.openings.first(where: { $0.id == reference.openingID })?.doorOperation
        }
        let unique = Set(values)
        return unique.count == 1 ? unique.first : nil
    }

    private func resolvedWindowOperation(for references: [SemanticOpeningReference], in project: PlanOpsisProject) -> PlanOpsisWindow.Operation? {
        let values = references.compactMap { reference -> PlanOpsisWindow.Operation? in
            project.rooms.first(where: { $0.id == reference.roomID })?.openings.first(where: { $0.id == reference.openingID })?.windowOperation
        }
        let unique = Set(values)
        return unique.count == 1 ? unique.first : nil
    }

    private struct PhysicalVoid {
        var startOffset: Double
        var endOffset: Double
        var bottom: Double
        var top: Double
        var centerOffset: Double { (startOffset + endOffset) * 0.5 }
    }

    private func projectedVoid(center: Point2D, width: Double, height: Double, sillHeight: Double, partition: CanonicalPartitionGeometry, enforceProjectionTolerance: Bool) -> PhysicalVoid? {
        guard partition.length > epsilon, partition.height > epsilon, width > epsilon, height > epsilon else { return nil }
        let direction = (partition.end - partition.start).normalized
        let delta = center - partition.start
        let offset = delta.dot(direction)
        let projectedPoint = partition.start + direction * offset
        let perpendicularDistance = (center - projectedPoint).length
        if enforceProjectionTolerance && perpendicularDistance > configuration.openingProjectionToleranceMM { return nil }

        let half = width * 0.5
        let start = max(0, min(partition.length, offset - half))
        let end = max(0, min(partition.length, offset + half))
        let bottom = max(0, min(partition.height, sillHeight))
        let top = max(0, min(partition.height, sillHeight + height))
        guard end > start + epsilon, top > bottom + epsilon else { return nil }
        return PhysicalVoid(startOffset: start, endOffset: end, bottom: bottom, top: top)
    }

    private func appendSemanticFallback(partition: PhysicalPartition, semanticGeometry: ArchitecturalGeometrySnapshot, planSegments: inout [DisplayWallPlanSegment], solids: inout [DisplayWallSolidSegment], openings: inout [DisplayOpeningGeometry]) {
        let wallIDs = Set(partition.sourceWalls.map(\.wallID))
        let roomIDs = Dictionary(uniqueKeysWithValues: partition.sourceWalls.map { ($0.wallID, $0.roomID) })

        for segment in semanticGeometry.planWallSegments where wallIDs.contains(segment.hostWallID) {
            planSegments.append(DisplayWallPlanSegment(
                id: "fallback:\(partition.id):\(segment.id)",
                partitionID: "\(partition.id):fallback:\(segment.hostWallID.uuidString)",
                sourceRoomIDs: [roomIDs[segment.hostWallID] ?? segment.roomID],
                sourceWallIDs: [segment.hostWallID],
                startOffset: segment.startOffset,
                length: segment.length,
                thickness: segment.thickness,
                footprint: segment.footprint
            ))
        }
        for solid in semanticGeometry.wallSolids where wallIDs.contains(solid.hostWallID) {
            solids.append(DisplayWallSolidSegment(
                id: "fallback:\(partition.id):\(solid.id)",
                partitionID: "\(partition.id):fallback:\(solid.hostWallID.uuidString)",
                sourceRoomIDs: [roomIDs[solid.hostWallID] ?? solid.roomID],
                sourceWallIDs: [solid.hostWallID],
                kind: solid.kind,
                startOffset: solid.startOffset,
                length: solid.length,
                bottom: solid.bottom,
                height: solid.height,
                thickness: solid.thickness,
                center: solid.center,
                angleRadians: solid.angleRadians,
                renderLength: solid.renderLength,
                renderCenter: solid.renderCenter,
                renderAngleRadians: solid.renderAngleRadians
            ))
        }
        for opening in semanticGeometry.hostedOpenings where wallIDs.contains(opening.hostWallID) {
            openings.append(DisplayOpeningGeometry(
                id: "fallback:\(partition.id):opening:\(opening.id.uuidString)",
                hostPartitionID: "\(partition.id):fallback:\(opening.hostWallID.uuidString)",
                sourceRoomIDs: [opening.roomID],
                sourceOpeningIDs: [opening.id],
                kind: DisplayOpeningKind(opening.kind),
                center: opening.center,
                width: opening.width,
                height: opening.height,
                sillHeight: opening.sillHeight,
                angleRadians: opening.angleRadians,
                thickness: opening.thickness,
                doorSwing: opening.doorSwing,
                doorOperation: opening.doorOperation,
                windowOperation: opening.windowOperation,
                cutsWall: true
            ))
        }
    }

    private func semanticOpeningGeometry(reference: SemanticOpeningReference, semanticGeometry: ArchitecturalGeometrySnapshot) -> HostedOpeningGeometry? {
        semanticGeometry.hostedOpenings.first { $0.roomID == reference.roomID && $0.id == reference.openingID }
    }

    private func appendPlanSegmentsOutside(partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], geometry: CanonicalPartitionGeometry, horizontalVoids: [(Double, Double)], direction: Point2D, normal: Point2D, joins: PhysicalPartitionJoinFlags, output: inout [DisplayWallPlanSegment]) {
        var cursor = 0.0
        for interval in horizontalVoids {
            if interval.0 > cursor + epsilon {
                output.append(planSegment(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, startOffset: cursor, length: interval.0 - cursor, direction: direction, normal: normal, joins: joins))
            }
            cursor = max(cursor, interval.1)
        }
        if cursor < geometry.length - epsilon {
            output.append(planSegment(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, startOffset: cursor, length: geometry.length - cursor, direction: direction, normal: normal, joins: joins))
        }
    }

    private func planSegment(partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], geometry: CanonicalPartitionGeometry, startOffset: Double, length: Double, direction: Point2D, normal: Point2D, joins: PhysicalPartitionJoinFlags) -> DisplayWallPlanSegment {
        var p0 = geometry.start + direction * startOffset
        var p1 = p0 + direction * length
        let cap = min(100, geometry.thickness * 0.5)
        if startOffset <= epsilon && joins.joinedAtStart { p0 = p0 - direction * cap }
        if startOffset + length >= geometry.length - epsilon && joins.joinedAtEnd { p1 = p1 + direction * cap }
        let n = normal * (geometry.thickness * 0.5)
        return DisplayWallPlanSegment(
            id: "physical:\(partitionID):plan:\(stable(startOffset)):\(stable(length))",
            partitionID: partitionID,
            sourceRoomIDs: sourceRoomIDs,
            sourceWallIDs: sourceWallIDs,
            startOffset: startOffset,
            length: length,
            thickness: geometry.thickness,
            footprint: [p0 + n, p1 + n, p1 - n, p0 - n]
        )
    }

    private func appendSolidSegments(partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], geometry: CanonicalPartitionGeometry, voids: [PhysicalVoid], direction: Point2D, joins: PhysicalPartitionJoinFlags, output: inout [DisplayWallSolidSegment]) {
        guard geometry.length > epsilon, geometry.height > epsilon else { return }
        var breaks = [0.0, geometry.length]
        for void in voids {
            breaks.append(void.startOffset)
            breaks.append(void.endOffset)
        }
        breaks = uniqueSorted(breaks)

        for index in 0..<(breaks.count - 1) {
            let x0 = breaks[index]
            let x1 = breaks[index + 1]
            guard x1 > x0 + epsilon else { continue }
            let active = voids.filter { $0.startOffset < x1 - epsilon && $0.endOffset > x0 + epsilon }
            if active.isEmpty {
                output.append(solid(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, kind: .fullHeight, startOffset: x0, length: x1 - x0, bottom: 0, height: geometry.height, direction: direction, joins: joins))
                continue
            }
            let verticalVoids = mergeIntervals(active.map { ($0.bottom, $0.top) })
            var cursor = 0.0
            for interval in verticalVoids {
                if interval.0 > cursor + epsilon {
                    appendVerticalSolid(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, startOffset: x0, length: x1 - x0, bottom: cursor, top: interval.0, direction: direction, joins: joins, output: &output)
                }
                cursor = max(cursor, interval.1)
            }
            if cursor < geometry.height - epsilon {
                appendVerticalSolid(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, startOffset: x0, length: x1 - x0, bottom: cursor, top: geometry.height, direction: direction, joins: joins, output: &output)
            }
        }
    }

    private func appendVerticalSolid(partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], geometry: CanonicalPartitionGeometry, startOffset: Double, length: Double, bottom: Double, top: Double, direction: Point2D, joins: PhysicalPartitionJoinFlags, output: inout [DisplayWallSolidSegment]) {
        guard top > bottom + epsilon else { return }
        let kind: WallSolidSegment.SegmentKind
        if bottom <= epsilon && top >= geometry.height - epsilon { kind = .fullHeight }
        else if bottom <= epsilon { kind = .sill }
        else if top >= geometry.height - epsilon { kind = .header }
        else { kind = .verticalBand }
        output.append(solid(partitionID: partitionID, sourceRoomIDs: sourceRoomIDs, sourceWallIDs: sourceWallIDs, geometry: geometry, kind: kind, startOffset: startOffset, length: length, bottom: bottom, height: top - bottom, direction: direction, joins: joins))
    }

    private func solid(partitionID: String, sourceRoomIDs: [UUID], sourceWallIDs: [UUID], geometry: CanonicalPartitionGeometry, kind: WallSolidSegment.SegmentKind, startOffset: Double, length: Double, bottom: Double, height: Double, direction: Point2D, joins: PhysicalPartitionJoinFlags) -> DisplayWallSolidSegment {
        let center = geometry.start + direction * (startOffset + length * 0.5)
        var renderStart = geometry.start + direction * startOffset
        var renderEnd = renderStart + direction * length
        let cap = min(100, geometry.thickness * 0.5)
        if startOffset <= epsilon && joins.joinedAtStart { renderStart = renderStart - direction * cap }
        if startOffset + length >= geometry.length - epsilon && joins.joinedAtEnd { renderEnd = renderEnd + direction * cap }
        let renderCenter = Point2D(x: (renderStart.x + renderEnd.x) * 0.5, y: (renderStart.y + renderEnd.y) * 0.5)
        let renderLength = (renderEnd - renderStart).length
        let renderAngle = atan2(renderEnd.y - renderStart.y, renderEnd.x - renderStart.x)
        return DisplayWallSolidSegment(
            id: "physical:\(partitionID):solid:\(kind.rawValue):\(stable(startOffset)):\(stable(bottom)):\(stable(length)):\(stable(height))",
            partitionID: partitionID,
            sourceRoomIDs: sourceRoomIDs,
            sourceWallIDs: sourceWallIDs,
            kind: kind,
            startOffset: startOffset,
            length: length,
            bottom: bottom,
            height: height,
            thickness: geometry.thickness,
            center: center,
            angleRadians: geometry.angleRadians,
            renderLength: renderLength,
            renderCenter: renderCenter,
            renderAngleRadians: renderAngle
        )
    }

    private func partitionJoinFlags(_ partitions: [PhysicalPartition]) -> [String: PhysicalPartitionJoinFlags] {
        struct Endpoint { var partitionID: String; var isStart: Bool; var point: Point2D }
        var endpoints: [Endpoint] = []
        for partition in partitions.sorted(by: { $0.id < $1.id }) {
            guard let geometry = partition.geometry else { continue }
            endpoints.append(Endpoint(partitionID: partition.id, isStart: true, point: geometry.start))
            endpoints.append(Endpoint(partitionID: partition.id, isStart: false, point: geometry.end))
        }

        let tolerance = GeometryTolerances.junctionJoinMM
        var flags: [String: PhysicalPartitionJoinFlags] = [:]
        for endpoint in endpoints {
            let joined = endpoints.contains { other in
                other.partitionID != endpoint.partitionID && (other.point - endpoint.point).length <= tolerance
            }
            var current = flags[endpoint.partitionID] ?? PhysicalPartitionJoinFlags(joinedAtStart: false, joinedAtEnd: false)
            if endpoint.isStart { current.joinedAtStart = joined } else { current.joinedAtEnd = joined }
            flags[endpoint.partitionID] = current
        }
        return flags
    }

    private func mergeIntervals(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = intervals.filter { $0.1 > $0.0 + epsilon }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard var current = sorted.first else { return [] }
        var result: [(Double, Double)] = []
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 + epsilon { current.1 = max(current.1, interval.1) }
            else { result.append(current); current = interval }
        }
        result.append(current)
        return result
    }

    private func uniqueSorted(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values.sorted() {
            if let last = result.last, abs(last - value) <= epsilon { continue }
            result.append(value)
        }
        return result
    }

    private func sortedUnique(_ values: [UUID]) -> [UUID] {
        Array(Set(values)).sorted { $0.uuidString < $1.uuidString }
    }

    private func stable(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
