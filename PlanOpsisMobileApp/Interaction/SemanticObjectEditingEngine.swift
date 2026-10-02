import Foundation

public enum PlanObjectKind: String, Codable, Hashable, Sendable, CaseIterable {
    case wall
    case door
    case window
    case opening
}

public struct SemanticDeleteResult: Sendable {
    public var project: PlanOpsisProject
    public var deletedIDs: [UUID]
    public init(project: PlanOpsisProject, deletedIDs: [UUID]) {
        self.project = project
        self.deletedIDs = deletedIDs
    }
}


public enum PlanAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case centerX
    case right
    case bottom
    case centerY
    case top
}

public enum PlanDistributionAxis: String, Codable, Hashable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

public enum PlanArrayAxis: String, Codable, Hashable, Sendable, CaseIterable {
    case horizontal
    case vertical
}


public enum PlanMirrorAxis: String, Codable, Hashable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

public struct ArchitecturalTransformResult: Sendable {
    public var project: PlanOpsisProject
    public var affectedIDs: [UUID]
    public var createdIDs: [UUID]

    public init(project: PlanOpsisProject, affectedIDs: [UUID], createdIDs: [UUID] = []) {
        self.project = project
        self.affectedIDs = affectedIDs
        self.createdIDs = createdIDs
    }
}

public struct SemanticBatchEditResult: Sendable {
    public var project: PlanOpsisProject
    public var affectedIDs: [UUID]
    public var createdIDs: [UUID]

    public init(project: PlanOpsisProject, affectedIDs: [UUID], createdIDs: [UUID] = []) {
        self.project = project
        self.affectedIDs = affectedIDs
        self.createdIDs = createdIDs
    }
}

public struct EditorHistorySnapshot: Hashable, Sendable {
    public var project: PlanOpsisProject
    public var selectionIDs: Set<UUID>
    public var primarySelectionID: UUID?

    public init(project: PlanOpsisProject, selectionIDs: Set<UUID> = [], primarySelectionID: UUID? = nil) {
        self.project = project
        self.selectionIDs = selectionIDs
        self.primarySelectionID = primarySelectionID
    }
}

public struct PlanOpsisEditHistory: Sendable {
    public struct Entry: Hashable, Sendable {
        public var snapshot: EditorHistorySnapshot
        public var label: String

        public init(snapshot: EditorHistorySnapshot, label: String) {
            self.snapshot = snapshot
            self.label = label
        }
    }

    public var maxDepth: Int
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    public init(maxDepth: Int = 100) {
        self.maxDepth = max(1, maxDepth)
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoLabel: String? { undoEntries.last?.label }
    public var redoLabel: String? { redoEntries.last?.label }

    public mutating func record(_ snapshot: EditorHistorySnapshot, label: String) {
        undoEntries.append(Entry(snapshot: snapshot, label: label))
        if undoEntries.count > maxDepth { undoEntries.removeFirst(undoEntries.count - maxDepth) }
        redoEntries.removeAll(keepingCapacity: true)
    }

    public mutating func undo(current: EditorHistorySnapshot, currentLabel: String = "Redo") -> EditorHistorySnapshot? {
        guard let previous = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(snapshot: current, label: previous.label.isEmpty ? currentLabel : previous.label))
        if redoEntries.count > maxDepth { redoEntries.removeFirst(redoEntries.count - maxDepth) }
        return previous.snapshot
    }

    public mutating func redo(current: EditorHistorySnapshot, currentLabel: String = "Undo") -> EditorHistorySnapshot? {
        guard let next = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(snapshot: current, label: next.label.isEmpty ? currentLabel : next.label))
        if undoEntries.count > maxDepth { undoEntries.removeFirst(undoEntries.count - maxDepth) }
        return next.snapshot
    }

    public mutating func clear() {
        undoEntries.removeAll(keepingCapacity: true)
        redoEntries.removeAll(keepingCapacity: true)
    }
}

public struct SemanticObjectEditingEngine {
    public init() {}

    public func addWall(
        to roomID: UUID,
        start: Point2D,
        end: Point2D,
        project: PlanOpsisProject,
        defaults: ArchitecturalDraftingConvention.Defaults = .init()
    ) -> (PlanOpsisProject, UUID)? {
        let vector = end - start
        guard vector.length > 1 else { return nil }
        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        let wall = PlanOpsisWall(
            start: start,
            length: vector.length,
            angleRadians: atan2(vector.y, vector.x),
            height: defaults.wallHeight,
            thickness: defaults.wallThickness,
            confidence: .unknown
        )
        next.rooms[roomIndex].walls.append(wall)
        return (next, wall.id)
    }

    public func addOpening(
        kind: PlanObjectKind,
        to roomID: UUID,
        hostWallID: UUID,
        center: Point2D,
        project: PlanOpsisProject,
        doorOperation: PlanOpsisDoor.Operation = .singleHinged,
        windowOperation: PlanOpsisWindow.Operation = .fixed,
        defaults: ArchitecturalDraftingConvention.Defaults = .init()
    ) -> (PlanOpsisProject, UUID)? {
        guard kind != .wall else { return nil }
        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == roomID }),
              let wall = next.rooms[roomIndex].walls.first(where: { $0.id == hostWallID }) else { return nil }

        let projected = max(0, min(wall.length, (center - wall.start).dot(wall.direction)))
        let width: Double
        let height: Double
        let sill: Double
        switch kind {
        case .door:
            switch doorOperation {
            case .singleHinged: width = defaults.doorWidth
            case .doubleHinged: width = max(1_400, defaults.doorWidth * 1.8)
            case .sliding: width = max(1_200, defaults.doorWidth * 1.5)
            case .pocket: width = defaults.doorWidth
            }
            height = defaults.doorHeight
            sill = 0
        case .window:
            switch windowOperation {
            case .fixed: width = defaults.windowWidth
            case .singleCasement: width = min(defaults.windowWidth, 1_000)
            case .doubleCasement: width = max(defaults.windowWidth, 1_200)
            case .sliding: width = max(defaults.windowWidth, 1_500)
            }
            height = defaults.windowHeight
            sill = defaults.windowSill
        case .opening:
            width = defaults.openingWidth; height = defaults.openingHeight; sill = 0
        case .wall:
            return nil
        }
        guard wall.length >= width + 20 else { return nil }
        let clampedOffset = max(width * 0.5, min(wall.length - width * 0.5, projected))
        let parameters = HostedOpeningParameters(
            hostWallID: hostWallID,
            offsetAlongWall: clampedOffset,
            width: width,
            height: min(height, wall.height),
            sillHeight: min(sill, max(0, wall.height - min(height, wall.height))),
            confidence: .unknown
        )
        let opening: PlanOpsisOpening
        switch kind {
        case .door:
            let swing: PlanOpsisDoor.Swing = (doorOperation == .sliding || doorOperation == .pocket) ? .unspecified : .leftIn
            opening = .door(PlanOpsisDoor(parameters: parameters, swing: swing, operation: doorOperation))
        case .window:
            opening = .window(PlanOpsisWindow(parameters: parameters, operation: windowOperation))
        case .opening:
            opening = .opening(parameters)
        case .wall:
            return nil
        }
        next.rooms[roomIndex].openings.append(opening)
        return (next, opening.id)
    }

    public func addComponent(
        kind: PlanOpsisComponent.Kind,
        to roomID: UUID,
        position: Point2D,
        project: PlanOpsisProject,
        rotationRadians: Double = 0
    ) -> (PlanOpsisProject, UUID)? {
        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        let component = PlanOpsisComponent(
            kind: kind,
            position: position,
            elevationMM: kind == .beam ? 2_450 : nil,
            rotationRadians: rotationRadians
        )
        next.rooms[roomIndex].components.append(component)
        return (next, component.id)
    }


    /// v9.7 precision duplication. Creates independent semantic UUIDs and never reuses capture provenance.
    /// Walls duplicate their hosted openings atomically onto the new host wall.
    public func duplicate(
        entityID: UUID,
        in project: PlanOpsisProject,
        offsetMM: Double = 250
    ) -> (PlanOpsisProject, UUID)? {
        var next = project
        for roomIndex in next.rooms.indices {
            if let wall = next.rooms[roomIndex].walls.first(where: { $0.id == entityID }) {
                let shift = wall.normal * max(20, offsetMM)
                let copy = PlanOpsisWall(
                    start: wall.start + shift,
                    length: wall.length,
                    angleRadians: wall.angleRadians,
                    height: wall.height,
                    thickness: wall.thickness,
                    confidence: .unknown
                )
                next.rooms[roomIndex].walls.append(copy)
                let hosted = next.rooms[roomIndex].openings.filter { $0.parameters.hostWallID == wall.id }
                for opening in hosted {
                    next.rooms[roomIndex].openings.append(clone(opening, hostWallID: copy.id, offsetAlongWall: opening.parameters.offsetAlongWall))
                }
                return (next, copy.id)
            }

            if let opening = next.rooms[roomIndex].openings.first(where: { $0.id == entityID }),
               let wall = next.rooms[roomIndex].walls.first(where: { $0.id == opening.parameters.hostWallID }) {
                let width = opening.parameters.width
                guard wall.length >= width + 20 else { return nil }
                let gap = max(20, offsetMM)
                let forward = opening.parameters.offsetAlongWall + width + gap
                let backward = opening.parameters.offsetAlongWall - width - gap
                let candidate: Double?
                if forward + width * 0.5 <= wall.length {
                    candidate = forward
                } else if backward - width * 0.5 >= 0 {
                    candidate = backward
                } else {
                    candidate = nil
                }
                guard let candidate else { return nil }
                let copy = clone(opening, hostWallID: wall.id, offsetAlongWall: candidate)
                next.rooms[roomIndex].openings.append(copy)
                return (next, copy.id)
            }

            if let component = next.rooms[roomIndex].components.first(where: { $0.id == entityID }) {
                let delta = max(20, offsetMM)
                let copy = PlanOpsisComponent(
                    kind: component.kind,
                    position: component.position + Point2D(x: delta, y: delta),
                    width: component.width,
                    depth: component.depth,
                    height: component.height,
                    elevationMM: component.elevationMM,
                    rotationRadians: component.rotationRadians
                )
                next.rooms[roomIndex].components.append(copy)
                return (next, copy.id)
            }
        }
        return nil
    }

    public func moveComponent(
        entityID: UUID,
        to position: Point2D,
        in project: PlanOpsisProject,
        gridSpacing: Double? = nil
    ) -> PlanOpsisProject? {
        var next = project
        let target: Point2D
        if let gridSpacing {
            let spacing = max(1, gridSpacing)
            target = Point2D(
                x: (position.x / spacing).rounded() * spacing,
                y: (position.y / spacing).rounded() * spacing
            )
        } else {
            target = position
        }
        for roomIndex in next.rooms.indices {
            guard let index = next.rooms[roomIndex].components.firstIndex(where: { $0.id == entityID }) else { continue }
            next.rooms[roomIndex].components[index].position = target
            return next
        }
        return nil
    }

    public func nudgeComponent(
        entityID: UUID,
        delta: Point2D,
        in project: PlanOpsisProject
    ) -> PlanOpsisProject? {
        var next = project
        for roomIndex in next.rooms.indices {
            guard let index = next.rooms[roomIndex].components.firstIndex(where: { $0.id == entityID }) else { continue }
            next.rooms[roomIndex].components[index].position = next.rooms[roomIndex].components[index].position + delta
            return next
        }
        return nil
    }

    public func rotateComponent(
        entityID: UUID,
        byDegrees degrees: Double,
        in project: PlanOpsisProject,
        snapIncrementDegrees: Double? = nil
    ) -> PlanOpsisProject? {
        var next = project
        for roomIndex in next.rooms.indices {
            guard let index = next.rooms[roomIndex].components.firstIndex(where: { $0.id == entityID }) else { continue }
            let currentDegrees = next.rooms[roomIndex].components[index].rotationRadians * 180 / .pi
            var target = currentDegrees + degrees
            if let snapIncrementDegrees {
                let increment = max(0.1, abs(snapIncrementDegrees))
                target = (target / increment).rounded() * increment
            }
            next.rooms[roomIndex].components[index].rotationRadians = target * .pi / 180
            return next
        }
        return nil
    }

    public func snapComponentToGrid(
        entityID: UUID,
        spacing: Double,
        in project: PlanOpsisProject
    ) -> PlanOpsisProject? {
        guard let component = project.rooms.flatMap(\.components).first(where: { $0.id == entityID }) else { return nil }
        return moveComponent(entityID: entityID, to: component.position, in: project, gridSpacing: spacing)
    }

    /// v9.8 atomic multi-delete. Selected walls cascade their hosted openings exactly once.
    public func delete(
        entityIDs: Set<UUID>,
        from project: PlanOpsisProject
    ) -> SemanticDeleteResult? {
        guard !entityIDs.isEmpty else { return nil }
        var next = project
        var deleted = Set<UUID>()

        for roomIndex in next.rooms.indices {
            let selectedWallIDs = Set(next.rooms[roomIndex].walls.map(\.id)).intersection(entityIDs)
            if !selectedWallIDs.isEmpty {
                let hosted = next.rooms[roomIndex].openings
                    .filter { selectedWallIDs.contains($0.parameters.hostWallID) }
                    .map(\.id)
                deleted.formUnion(selectedWallIDs)
                deleted.formUnion(hosted)
                next.rooms[roomIndex].walls.removeAll { selectedWallIDs.contains($0.id) }
                next.rooms[roomIndex].openings.removeAll { selectedWallIDs.contains($0.parameters.hostWallID) }
            }

            let openingIDs = Set(next.rooms[roomIndex].openings.map(\.id)).intersection(entityIDs)
            if !openingIDs.isEmpty {
                deleted.formUnion(openingIDs)
                next.rooms[roomIndex].openings.removeAll { openingIDs.contains($0.id) }
            }

            let componentIDs = Set(next.rooms[roomIndex].components.map(\.id)).intersection(entityIDs)
            if !componentIDs.isEmpty {
                deleted.formUnion(componentIDs)
                next.rooms[roomIndex].components.removeAll { componentIDs.contains($0.id) }
            }
        }

        guard !deleted.isEmpty else { return nil }
        return SemanticDeleteResult(
            project: next,
            deletedIDs: deleted.sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// Aligns selected independent components using the axis-aligned bounds of their rotated footprints.
    /// Hosted openings and walls are intentionally excluded so host/topology invariants cannot be broken.
    public func alignComponents(
        entityIDs: Set<UUID>,
        alignment: PlanAlignment,
        in project: PlanOpsisProject
    ) -> SemanticBatchEditResult? {
        let selected = project.rooms.flatMap(\.components).filter { entityIDs.contains($0.id) }
        guard selected.count >= 2 else { return nil }
        let bounds = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, componentBounds($0)) })
        let all = bounds.values
        guard let minX = all.map(\.minX).min(), let maxX = all.map(\.maxX).max(),
              let minY = all.map(\.minY).min(), let maxY = all.map(\.maxY).max() else { return nil }
        let centerX = (minX + maxX) * 0.5
        let centerY = (minY + maxY) * 0.5

        var next = project
        for roomIndex in next.rooms.indices {
            for componentIndex in next.rooms[roomIndex].components.indices {
                let id = next.rooms[roomIndex].components[componentIndex].id
                guard entityIDs.contains(id), let box = bounds[id] else { continue }
                var delta = Point2D.zero
                switch alignment {
                case .left: delta.x = minX - box.minX
                case .centerX: delta.x = centerX - box.centerX
                case .right: delta.x = maxX - box.maxX
                case .bottom: delta.y = minY - box.minY
                case .centerY: delta.y = centerY - box.centerY
                case .top: delta.y = maxY - box.maxY
                }
                next.rooms[roomIndex].components[componentIndex].position = next.rooms[roomIndex].components[componentIndex].position + delta
            }
        }
        return SemanticBatchEditResult(project: next, affectedIDs: selected.map(\.id))
    }

    /// Distributes three or more components with equal clear gaps while preserving the two outer objects.
    public func distributeComponents(
        entityIDs: Set<UUID>,
        axis: PlanDistributionAxis,
        in project: PlanOpsisProject
    ) -> SemanticBatchEditResult? {
        let selected = project.rooms.flatMap(\.components).filter { entityIDs.contains($0.id) }
        guard selected.count >= 3 else { return nil }
        let bounds = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, componentBounds($0)) })
        let ordered = selected.sorted { lhs, rhs in
            guard let a = bounds[lhs.id], let b = bounds[rhs.id] else { return lhs.id.uuidString < rhs.id.uuidString }
            switch axis {
            case .horizontal:
                if abs(a.minX - b.minX) > 1e-9 { return a.minX < b.minX }
            case .vertical:
                if abs(a.minY - b.minY) > 1e-9 { return a.minY < b.minY }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard let firstComponent = ordered.first,
              let lastComponent = ordered.last,
              let firstBox = bounds[firstComponent.id],
              let lastBox = bounds[lastComponent.id] else { return nil }
        let totalSize: Double = ordered.reduce(0) { partial, component in
            guard let box = bounds[component.id] else { return partial }
            return partial + (axis == .horizontal ? box.width : box.height)
        }
        let span = axis == .horizontal ? (lastBox.maxX - firstBox.minX) : (lastBox.maxY - firstBox.minY)
        let gap = (span - totalSize) / Double(ordered.count - 1)
        var targetPosition: [UUID: Point2D] = [:]
        var cursor = axis == .horizontal ? firstBox.minX : firstBox.minY
        for (index, component) in ordered.enumerated() {
            guard let box = bounds[component.id] else { continue }
            if index == 0 || index == ordered.count - 1 {
                targetPosition[component.id] = component.position
            } else {
                let delta = axis == .horizontal
                    ? Point2D(x: cursor - box.minX, y: 0)
                    : Point2D(x: 0, y: cursor - box.minY)
                targetPosition[component.id] = component.position + delta
            }
            cursor += (axis == .horizontal ? box.width : box.height) + gap
        }

        var next = project
        for roomIndex in next.rooms.indices {
            for componentIndex in next.rooms[roomIndex].components.indices {
                let id = next.rooms[roomIndex].components[componentIndex].id
                if let target = targetPosition[id] {
                    next.rooms[roomIndex].components[componentIndex].position = target
                }
            }
        }
        return SemanticBatchEditResult(project: next, affectedIDs: ordered.map(\.id))
    }

    /// Creates a deterministic linear array of one or more selected components.
    /// `count` is the total number of occurrences including the original selected set.
    /// `stepMM` is the translation between consecutive occurrences.
    public func linearArrayComponents(
        entityIDs: Set<UUID>,
        axis: PlanArrayAxis,
        count: Int,
        stepMM: Double,
        in project: PlanOpsisProject
    ) -> SemanticBatchEditResult? {
        guard count >= 2, stepMM.isFinite, abs(stepMM) > 1e-9 else { return nil }
        let selectedIDs = Set(project.rooms.flatMap(\.components).filter { entityIDs.contains($0.id) }.map(\.id))
        guard !selectedIDs.isEmpty else { return nil }
        var next = project
        var created: [UUID] = []

        for roomIndex in next.rooms.indices {
            let originals = next.rooms[roomIndex].components.filter { selectedIDs.contains($0.id) }
            guard !originals.isEmpty else { continue }
            for occurrence in 1..<count {
                let scalar = Double(occurrence) * stepMM
                let delta = axis == .horizontal ? Point2D(x: scalar, y: 0) : Point2D(x: 0, y: scalar)
                for component in originals {
                    let copy = PlanOpsisComponent(
                        kind: component.kind,
                        position: component.position + delta,
                        width: component.width,
                        depth: component.depth,
                        height: component.height,
                        elevationMM: component.elevationMM,
                        rotationRadians: component.rotationRadians
                    )
                    next.rooms[roomIndex].components.append(copy)
                    created.append(copy.id)
                }
            }
        }
        return SemanticBatchEditResult(
            project: next,
            affectedIDs: Array(selectedIDs).sorted { $0.uuidString < $1.uuidString },
            createdIDs: created
        )
    }


    // MARK: - v9.9 architectural transforms

    /// Moves selected walls and independent components as one semantic group.
    /// Hosted openings remain attached to their wall because their offsets are wall-local.
    /// The operation is rejected when a selected wall is connected to an unselected wall,
    /// preventing silent room-topology breakage.
    public func moveArchitecturalSelection(
        entityIDs: Set<UUID>,
        delta: Point2D,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        guard let scope = architecturalScope(entityIDs: entityIDs, in: project), !scope.affectedIDs.isEmpty else { return nil }
        guard !hasExternalJunctions(selectedWallIDs: scope.wallIDs, room: scope.room) else { return nil }

        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == scope.room.id }) else { return nil }
        for index in next.rooms[roomIndex].walls.indices where scope.wallIDs.contains(next.rooms[roomIndex].walls[index].id) {
            next.rooms[roomIndex].walls[index].start = next.rooms[roomIndex].walls[index].start + delta
        }
        for index in next.rooms[roomIndex].components.indices where scope.componentIDs.contains(next.rooms[roomIndex].components[index].id) {
            next.rooms[roomIndex].components[index].position = next.rooms[roomIndex].components[index].position + delta
        }
        return ArchitecturalTransformResult(project: next, affectedIDs: scope.affectedIDs)
    }

    /// Copies selected walls (including all hosted openings) and components by an exact translation.
    /// Copied semantics always receive new UUIDs and captured RoomPlan provenance is cleared.
    public func copyArchitecturalSelection(
        entityIDs: Set<UUID>,
        delta: Point2D,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        guard let scope = architecturalScope(entityIDs: entityIDs, in: project), !scope.affectedIDs.isEmpty else { return nil }
        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == scope.room.id }) else { return nil }
        let originalRoom = scope.room
        var wallMap: [UUID: UUID] = [:]
        var created: [UUID] = []

        for wall in originalRoom.walls where scope.wallIDs.contains(wall.id) {
            let copy = PlanOpsisWall(
                start: wall.start + delta,
                length: wall.length,
                angleRadians: wall.angleRadians,
                height: wall.height,
                thickness: wall.thickness,
                confidence: .unknown
            )
            next.rooms[roomIndex].walls.append(copy)
            wallMap[wall.id] = copy.id
            created.append(copy.id)
        }

        for opening in originalRoom.openings {
            if let host = wallMap[opening.parameters.hostWallID] {
                let copy = clone(opening, hostWallID: host, offsetAlongWall: opening.parameters.offsetAlongWall)
                next.rooms[roomIndex].openings.append(copy)
                created.append(copy.id)
            }
        }

        for component in originalRoom.components where scope.componentIDs.contains(component.id) {
            let copy = PlanOpsisComponent(
                kind: component.kind,
                position: component.position + delta,
                width: component.width,
                depth: component.depth,
                height: component.height,
                elevationMM: component.elevationMM,
                rotationRadians: component.rotationRadians
            )
            next.rooms[roomIndex].components.append(copy)
            created.append(copy.id)
        }

        guard !created.isEmpty else { return nil }
        return ArchitecturalTransformResult(project: next, affectedIDs: scope.affectedIDs, createdIDs: created)
    }

    /// Rotates a wall/component group around its geometric center. Wall lengths and hosted-opening
    /// offsets remain invariant. Connected wall subsets are rejected unless the entire junction moves.
    public func rotateArchitecturalSelection(
        entityIDs: Set<UUID>,
        degrees: Double,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard degrees.isFinite, abs(degrees) > 1e-12 else { return nil }
        guard let scope = architecturalScope(entityIDs: entityIDs, in: project), !scope.affectedIDs.isEmpty else { return nil }
        guard !hasExternalJunctions(selectedWallIDs: scope.wallIDs, room: scope.room) else { return nil }
        let pivot = selectionCenter(scope: scope)
        let angle = degrees * .pi / 180

        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == scope.room.id }) else { return nil }
        for index in next.rooms[roomIndex].walls.indices where scope.wallIDs.contains(next.rooms[roomIndex].walls[index].id) {
            let wall = next.rooms[roomIndex].walls[index]
            let start = rotate(point: wall.start, around: pivot, radians: angle)
            let end = rotate(point: wall.end, around: pivot, radians: angle)
            next.rooms[roomIndex].walls[index].start = start
            next.rooms[roomIndex].walls[index].editEnd(end)
        }
        for index in next.rooms[roomIndex].components.indices where scope.componentIDs.contains(next.rooms[roomIndex].components[index].id) {
            next.rooms[roomIndex].components[index].position = rotate(point: next.rooms[roomIndex].components[index].position, around: pivot, radians: angle)
            next.rooms[roomIndex].components[index].rotationRadians += angle
        }
        return ArchitecturalTransformResult(project: next, affectedIDs: scope.affectedIDs)
    }

    /// Mirrors walls/components about a horizontal or vertical axis through the current selection center.
    /// Door handedness is mirrored when its host wall participates in the operation.
    public func mirrorArchitecturalSelection(
        entityIDs: Set<UUID>,
        axis: PlanMirrorAxis,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard let scope = architecturalScope(entityIDs: entityIDs, in: project), !scope.affectedIDs.isEmpty else { return nil }
        guard !hasExternalJunctions(selectedWallIDs: scope.wallIDs, room: scope.room) else { return nil }
        let pivot = selectionCenter(scope: scope)

        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == scope.room.id }) else { return nil }
        for index in next.rooms[roomIndex].walls.indices where scope.wallIDs.contains(next.rooms[roomIndex].walls[index].id) {
            let wall = next.rooms[roomIndex].walls[index]
            let start = mirror(point: wall.start, axis: axis, pivot: pivot)
            let end = mirror(point: wall.end, axis: axis, pivot: pivot)
            // Reflection reverses the wall frame's orientation. Reverse the reflected
            // axis so local +normal also reflects; left/right handing can then swap once.
            next.rooms[roomIndex].walls[index].start = end
            next.rooms[roomIndex].walls[index].editEnd(start)
        }
        for index in next.rooms[roomIndex].components.indices where scope.componentIDs.contains(next.rooms[roomIndex].components[index].id) {
            var component = next.rooms[roomIndex].components[index]
            component.position = mirror(point: component.position, axis: axis, pivot: pivot)
            switch axis {
            case .vertical: component.rotationRadians = .pi - component.rotationRadians
            case .horizontal: component.rotationRadians = -component.rotationRadians
            }
            next.rooms[roomIndex].components[index] = component
        }
        for index in next.rooms[roomIndex].openings.indices {
            guard scope.wallIDs.contains(next.rooms[roomIndex].openings[index].parameters.hostWallID) else { continue }
            let hostID = next.rooms[roomIndex].openings[index].parameters.hostWallID
            if let host = scope.room.walls.first(where: { $0.id == hostID }) {
                next.rooms[roomIndex].openings[index].parameters.offsetAlongWall = host.length - next.rooms[roomIndex].openings[index].parameters.offsetAlongWall
            }
            if let swing = next.rooms[roomIndex].openings[index].doorSwing {
                next.rooms[roomIndex].openings[index].doorSwing = mirroredDoorSwing(swing)
            }
        }
        return ArchitecturalTransformResult(project: next, affectedIDs: scope.affectedIDs)
    }

    /// Offsets one wall parallel to itself, preserving all hosted-opening parameters.
    /// Connected walls are protected: a wall with endpoint junctions cannot be offset alone.
    public func offsetWall(
        wallID: UUID,
        distanceMM: Double,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard distanceMM.isFinite, abs(distanceMM) > 1e-12 else { return nil }
        guard let (room, wall) = roomAndWall(id: wallID, in: project) else { return nil }
        guard !hasExternalJunctions(selectedWallIDs: [wallID], room: room) else { return nil }
        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == room.id }),
              let wallIndex = next.rooms[roomIndex].walls.firstIndex(where: { $0.id == wallID }) else { return nil }
        next.rooms[roomIndex].walls[wallIndex].start = wall.start + wall.normal * distanceMM
        return ArchitecturalTransformResult(project: next, affectedIDs: [wallID])
    }

    /// Trims or extends a single isolated wall to the nearest infinite-line intersection with another wall.
    /// Existing hosted openings keep their world station when the start endpoint changes, and the operation
    /// is rejected if any opening would fall outside the resulting host wall.
    public func trimOrExtendWallToNearestIntersection(
        wallID: UUID,
        in project: PlanOpsisProject
    ) -> ArchitecturalTransformResult? {
        guard let (room, wall) = roomAndWall(id: wallID, in: project) else { return nil }
        guard !hasExternalJunctions(selectedWallIDs: [wallID], room: room) else { return nil }
        let others = room.walls.filter { $0.id != wallID }
        guard !others.isEmpty else { return nil }

        var best: (point: Point2D, endpoint: WallEndpointKind, displacement: Double)?
        for other in others {
            guard let point = lineIntersection(a0: wall.start, a1: wall.end, b0: other.start, b1: other.end) else { continue }
            let ds = (point - wall.start).length
            let de = (point - wall.end).length
            let candidate: (Point2D, WallEndpointKind, Double) = ds <= de ? (point, .start, ds) : (point, .end, de)
            if candidate.2 < (best?.displacement ?? .greatestFiniteMagnitude), candidate.2 > 1e-6 {
                best = (candidate.0, candidate.1, candidate.2)
            }
        }
        guard let best else { return nil }

        var edited = wall
        var newOpeningOffsets: [UUID: Double] = [:]
        switch best.endpoint {
        case .start:
            let oldStations = Dictionary(uniqueKeysWithValues: room.openings.filter { $0.parameters.hostWallID == wallID }.map { opening in
                (opening.id, wall.start + wall.direction * opening.parameters.offsetAlongWall)
            })
            edited.editStartKeepingEnd(best.point)
            guard edited.length > 20 else { return nil }
            for opening in room.openings where opening.parameters.hostWallID == wallID {
                guard let world = oldStations[opening.id] else { continue }
                let offset = (world - edited.start).dot(edited.direction)
                guard openingFits(offset: offset, width: opening.parameters.width, wallLength: edited.length) else { return nil }
                newOpeningOffsets[opening.id] = offset
            }
        case .end:
            edited.editEnd(best.point)
            guard edited.length > 20 else { return nil }
            for opening in room.openings where opening.parameters.hostWallID == wallID {
                guard openingFits(offset: opening.parameters.offsetAlongWall, width: opening.parameters.width, wallLength: edited.length) else { return nil }
            }
        }

        var next = project
        guard let roomIndex = next.rooms.firstIndex(where: { $0.id == room.id }),
              let wallIndex = next.rooms[roomIndex].walls.firstIndex(where: { $0.id == wallID }) else { return nil }
        next.rooms[roomIndex].walls[wallIndex] = edited
        if !newOpeningOffsets.isEmpty {
            for index in next.rooms[roomIndex].openings.indices {
                let id = next.rooms[roomIndex].openings[index].id
                guard let offset = newOpeningOffsets[id] else { continue }
                var parameters = next.rooms[roomIndex].openings[index].parameters
                parameters.offsetAlongWall = offset
                next.rooms[roomIndex].openings[index].parameters = parameters
            }
        }
        return ArchitecturalTransformResult(project: next, affectedIDs: [wallID])
    }

    private struct ArchitecturalScope {
        var room: PlanOpsisRoom
        var wallIDs: Set<UUID>
        var componentIDs: Set<UUID>
        var affectedIDs: [UUID]
    }

    private func architecturalScope(entityIDs: Set<UUID>, in project: PlanOpsisProject) -> ArchitecturalScope? {
        guard !entityIDs.isEmpty else { return nil }
        var matching: [(room: PlanOpsisRoom, walls: Set<UUID>, components: Set<UUID>)] = []
        for room in project.rooms {
            let walls = Set(room.walls.map(\.id)).intersection(entityIDs)
            let components = Set(room.components.map(\.id)).intersection(entityIDs)
            let directOpeningIDs = Set(room.openings.map(\.id)).intersection(entityIDs)
            // Hosted openings move only through their host wall; independent opening transforms are unsafe.
            if !directOpeningIDs.isEmpty && directOpeningIDs.contains(where: { id in
                guard let opening = room.openings.first(where: { $0.id == id }) else { return false }
                return !walls.contains(opening.parameters.hostWallID)
            }) { return nil }
            if !walls.isEmpty || !components.isEmpty { matching.append((room, walls, components)) }
        }
        guard matching.count == 1, let match = matching.first else { return nil }
        let ids = Array(match.walls.union(match.components)).sorted { $0.uuidString < $1.uuidString }
        return ArchitecturalScope(room: match.room, wallIDs: match.walls, componentIDs: match.components, affectedIDs: ids)
    }

    private func roomAndWall(id: UUID, in project: PlanOpsisProject) -> (PlanOpsisRoom, PlanOpsisWall)? {
        for room in project.rooms {
            if let wall = room.walls.first(where: { $0.id == id }) { return (room, wall) }
        }
        return nil
    }

    private func hasExternalJunctions(selectedWallIDs: Set<UUID>, room: PlanOpsisRoom, tolerance: Double = 2.0) -> Bool {
        guard !selectedWallIDs.isEmpty else { return false }
        let selected = room.walls.filter { selectedWallIDs.contains($0.id) }
        let unselected = room.walls.filter { !selectedWallIDs.contains($0.id) }
        for wall in selected {
            for point in [wall.start, wall.end] {
                for other in unselected where (other.start - point).length <= tolerance || (other.end - point).length <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func selectionCenter(scope: ArchitecturalScope) -> Point2D {
        var points: [Point2D] = []
        for wall in scope.room.walls where scope.wallIDs.contains(wall.id) { points += [wall.start, wall.end] }
        for component in scope.room.components where scope.componentIDs.contains(component.id) { points.append(component.position) }
        guard !points.isEmpty else { return .zero }
        return Point2D(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
    }

    private func rotate(point: Point2D, around pivot: Point2D, radians: Double) -> Point2D {
        let p = point - pivot
        let c = cos(radians), s = sin(radians)
        return pivot + Point2D(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
    }

    private func mirror(point: Point2D, axis: PlanMirrorAxis, pivot: Point2D) -> Point2D {
        switch axis {
        case .vertical: return Point2D(x: 2 * pivot.x - point.x, y: point.y)
        case .horizontal: return Point2D(x: point.x, y: 2 * pivot.y - point.y)
        }
    }

    private func mirroredDoorSwing(_ swing: PlanOpsisDoor.Swing) -> PlanOpsisDoor.Swing {
        switch swing {
        case .unspecified: return .unspecified
        case .leftIn: return .rightIn
        case .leftOut: return .rightOut
        case .rightIn: return .leftIn
        case .rightOut: return .leftOut
        }
    }

    private func lineIntersection(a0: Point2D, a1: Point2D, b0: Point2D, b1: Point2D) -> Point2D? {
        let r = a1 - a0, s = b1 - b0
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-9 else { return nil }
        let q = b0 - a0
        let t = (q.x * s.y - q.y * s.x) / denominator
        let point = a0 + r * t
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func openingFits(offset: Double, width: Double, wallLength: Double) -> Bool {
        let half = width * 0.5
        return offset.isFinite && offset - half >= -1e-6 && offset + half <= wallLength + 1e-6
    }

    private struct ComponentBounds {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
        var centerX: Double { (minX + maxX) * 0.5 }
        var centerY: Double { (minY + maxY) * 0.5 }
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
    }

    private func componentBounds(_ component: PlanOpsisComponent) -> ComponentBounds {
        let footprint = ArchitecturalSymbolLibrary.component(component).primitives.flatMap { $0.geometry.boundsPoints }
        return ComponentBounds(
            minX: footprint.map(\.x).min() ?? component.position.x,
            maxX: footprint.map(\.x).max() ?? component.position.x,
            minY: footprint.map(\.y).min() ?? component.position.y,
            maxY: footprint.map(\.y).max() ?? component.position.y
        )
    }

    private func clone(
        _ opening: PlanOpsisOpening,
        hostWallID: UUID,
        offsetAlongWall: Double
    ) -> PlanOpsisOpening {
        var parameters = opening.parameters
        parameters.id = UUID()
        parameters.sourceRoomPlanID = nil
        parameters.hostWallID = hostWallID
        parameters.offsetAlongWall = offsetAlongWall
        parameters.confidence = .unknown
        switch opening {
        case .opening:
            return .opening(parameters)
        case .door(let door):
            return .door(PlanOpsisDoor(parameters: parameters, swing: door.swing, operation: door.operation))
        case .window(let window):
            return .window(PlanOpsisWindow(parameters: parameters, operation: window.operation))
        }
    }

    /// Deletes one semantic object. Deleting a wall cascades to openings hosted by that wall,
    /// because orphaned openings are invalid architectural state.
    public func delete(entityID: UUID, from project: PlanOpsisProject) -> SemanticDeleteResult? {
        var next = project
        for roomIndex in next.rooms.indices {
            if let wallIndex = next.rooms[roomIndex].walls.firstIndex(where: { $0.id == entityID }) {
                let wallID = next.rooms[roomIndex].walls[wallIndex].id
                let hosted = next.rooms[roomIndex].openings.filter { $0.parameters.hostWallID == wallID }.map(\.id)
                next.rooms[roomIndex].walls.remove(at: wallIndex)
                next.rooms[roomIndex].openings.removeAll { $0.parameters.hostWallID == wallID }
                return SemanticDeleteResult(project: next, deletedIDs: [wallID] + hosted)
            }
            if let openingIndex = next.rooms[roomIndex].openings.firstIndex(where: { $0.id == entityID }) {
                let openingID = next.rooms[roomIndex].openings[openingIndex].id
                next.rooms[roomIndex].openings.remove(at: openingIndex)
                return SemanticDeleteResult(project: next, deletedIDs: [openingID])
            }
            if let componentIndex = next.rooms[roomIndex].components.firstIndex(where: { $0.id == entityID }) {
                let componentID = next.rooms[roomIndex].components[componentIndex].id
                next.rooms[roomIndex].components.remove(at: componentIndex)
                return SemanticDeleteResult(project: next, deletedIDs: [componentID])
            }
        }
        return nil
    }
}
