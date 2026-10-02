import Foundation

public enum WallEndpointKind: String, Codable, Hashable, Sendable {
    case start
    case end
}

public struct WallEndpointReference: Codable, Hashable, Sendable, Identifiable {
    public var wallID: UUID
    public var endpoint: WallEndpointKind
    public var point: Point2D

    public var id: String { "\(wallID.uuidString):\(endpoint.rawValue)" }

    public init(wallID: UUID, endpoint: WallEndpointKind, point: Point2D) {
        self.wallID = wallID
        self.endpoint = endpoint
        self.point = point
    }
}

public struct PlanEditingSettings: Codable, Hashable, Sendable {
    public var orthoEnabled: Bool
    public var gridEnabled: Bool
    public var gridSpacing: Double
    public var endpointSnapTolerance: Double
    public var connectedEndpointTolerance: Double
    /// v12.3 polar tracking: when ortho is off, directions within a few degrees of a multiple of this
    /// angle snap to it. Nil turns polar tracking off.
    public var polarIncrementDegrees: Double?

    public init(
        orthoEnabled: Bool = false,
        gridEnabled: Bool = false,
        gridSpacing: Double = 250,
        endpointSnapTolerance: Double = GeometryTolerances.endpointSnapMM,
        connectedEndpointTolerance: Double = GeometryTolerances.coincidenceMM,
        polarIncrementDegrees: Double? = nil
    ) {
        self.polarIncrementDegrees = polarIncrementDegrees
        self.orthoEnabled = orthoEnabled
        self.gridEnabled = gridEnabled
        self.gridSpacing = max(1, gridSpacing)
        self.endpointSnapTolerance = max(0, endpointSnapTolerance)
        self.connectedEndpointTolerance = max(0, connectedEndpointTolerance)
    }
}

public struct EndpointConstraintResult: Codable, Hashable, Sendable {
    public var point: Point2D
    public var snappedEndpoint: WallEndpointReference?
    public var usedGrid: Bool
    public var usedOrtho: Bool

    public init(point: Point2D, snappedEndpoint: WallEndpointReference?, usedGrid: Bool, usedOrtho: Bool) {
        self.point = point
        self.snappedEndpoint = snappedEndpoint
        self.usedGrid = usedGrid
        self.usedOrtho = usedOrtho
    }
}

/// Pure interaction constraint engine used by the iOS editor and unit tests.
/// It never mutates project state. The caller decides which semantic wall endpoints
/// are updated after the constrained point has been calculated.

public struct EndpointMoveResult: Codable, Hashable, Sendable {
    public var walls: [PlanOpsisWall]
    public var constraint: EndpointConstraintResult
    public var propagatedEndpointIDs: [String]

    public init(walls: [PlanOpsisWall], constraint: EndpointConstraintResult, propagatedEndpointIDs: [String]) {
        self.walls = walls
        self.constraint = constraint
        self.propagatedEndpointIDs = propagatedEndpointIDs
    }
}

public struct PlanEditingConstraintEngine: Sendable {
    public init() {}

    public func moveEndpoint(
        wallID: UUID,
        endpoint: WallEndpointKind,
        proposed: Point2D,
        in walls: [PlanOpsisWall],
        settings: PlanEditingSettings,
        applyConstraints: Bool = true
    ) -> EndpointMoveResult? {
        guard let wallIndex = walls.firstIndex(where: { $0.id == wallID }) else { return nil }
        var resultWalls = walls
        let wall = walls[wallIndex]
        let oldPoint = endpoint == .start ? wall.start : wall.end
        let anchor = endpoint == .start ? wall.end : wall.start
        let edited = WallEndpointReference(wallID: wallID, endpoint: endpoint, point: oldPoint)
        let connected = connectedEndpoints(
            at: oldPoint,
            in: walls,
            excluding: edited,
            tolerance: settings.connectedEndpointTolerance
        )

        let constraint: EndpointConstraintResult
        if applyConstraints {
            constraint = constrainedPoint(
                proposed: proposed,
                anchor: anchor,
                edited: edited,
                walls: walls,
                ignoredEndpointIDs: Set(connected.map(\.id)),
                settings: settings
            )
        } else {
            constraint = EndpointConstraintResult(
                point: proposed,
                snappedEndpoint: nil,
                usedGrid: false,
                usedOrtho: false
            )
        }

        applyEndpoint(constraint.point, endpoint: endpoint, to: &resultWalls[wallIndex])
        for reference in connected {
            guard let index = resultWalls.firstIndex(where: { $0.id == reference.wallID }) else { continue }
            applyEndpoint(constraint.point, endpoint: reference.endpoint, to: &resultWalls[index])
        }

        return EndpointMoveResult(
            walls: resultWalls,
            constraint: constraint,
            propagatedEndpointIDs: connected.map(\.id)
        )
    }

    public func endpoints(in walls: [PlanOpsisWall]) -> [WallEndpointReference] {
        walls.flatMap { wall in
            [
                WallEndpointReference(wallID: wall.id, endpoint: .start, point: wall.start),
                WallEndpointReference(wallID: wall.id, endpoint: .end, point: wall.end)
            ]
        }
    }

    public func connectedEndpoints(
        at point: Point2D,
        in walls: [PlanOpsisWall],
        excluding edited: WallEndpointReference,
        tolerance: Double
    ) -> [WallEndpointReference] {
        endpoints(in: walls)
            .filter { candidate in
                candidate.id != edited.id && (candidate.point - point).length <= tolerance
            }
            .sorted { $0.id < $1.id }
    }

    public func constrainedPoint(
        proposed: Point2D,
        anchor: Point2D,
        edited: WallEndpointReference,
        walls: [PlanOpsisWall],
        ignoredEndpointIDs: Set<String> = [],
        settings: PlanEditingSettings
    ) -> EndpointConstraintResult {
        var point = proposed
        var usedGrid = false
        var usedOrtho = false

        if settings.gridEnabled {
            point = snapToGrid(point, spacing: settings.gridSpacing)
            usedGrid = true
        }

        if settings.orthoEnabled {
            point = orthoPoint(point, anchor: anchor)
            usedOrtho = true
        } else if let increment = settings.polarIncrementDegrees, let polar = polarPoint(point, anchor: anchor, incrementDegrees: increment) {
            point = polar
        }

        let snapCandidate = nearestCompatibleEndpoint(
            to: point,
            anchor: anchor,
            edited: edited,
            walls: walls,
            ignoredEndpointIDs: ignoredEndpointIDs,
            settings: settings
        )

        if let snapCandidate {
            point = snapCandidate.point
        }

        return EndpointConstraintResult(
            point: point,
            snappedEndpoint: snapCandidate,
            usedGrid: usedGrid,
            usedOrtho: usedOrtho
        )
    }

    public func snapToGrid(_ point: Point2D, spacing: Double) -> Point2D {
        let s = max(1, spacing)
        return Point2D(
            x: (point.x / s).rounded() * s,
            y: (point.y / s).rounded() * s
        )
    }

    public func orthoPoint(_ point: Point2D, anchor: Point2D) -> Point2D {
        let delta = point - anchor
        if abs(delta.x) >= abs(delta.y) {
            return Point2D(x: point.x, y: anchor.y)
        }
        return Point2D(x: anchor.x, y: point.y)
    }

    private func applyEndpoint(_ point: Point2D, endpoint: WallEndpointKind, to wall: inout PlanOpsisWall) {
        switch endpoint {
        case .start:
            wall.editStartKeepingEnd(point)
        case .end:
            wall.editEnd(point)
        }
    }

    private func nearestCompatibleEndpoint(
        to point: Point2D,
        anchor: Point2D,
        edited: WallEndpointReference,
        walls: [PlanOpsisWall],
        ignoredEndpointIDs: Set<String>,
        settings: PlanEditingSettings
    ) -> WallEndpointReference? {
        endpoints(in: walls)
            .filter { candidate in
                guard candidate.id != edited.id,
                      !ignoredEndpointIDs.contains(candidate.id),
                      (candidate.point - point).length <= settings.endpointSnapTolerance else {
                    return false
                }
                if settings.orthoEnabled {
                    let delta = candidate.point - anchor
                    let orthogonalError = min(abs(delta.x), abs(delta.y))
                    return orthogonalError <= settings.endpointSnapTolerance * 0.25
                }
                return true
            }
            .sorted { lhs, rhs in
                let ld = (lhs.point - point).length
                let rd = (rhs.point - point).length
                if abs(ld - rd) > 1e-9 { return ld < rd }
                return lhs.id < rhs.id
            }
            .first
    }
}

public enum WallEndpointEditError: Error, Equatable, LocalizedError {
    case wallNotFound(UUID)
    case degenerateWall(UUID)
    case openingWouldNotFit(openingID: UUID, hostWallID: UUID)

    public var errorDescription: String? {
        switch self {
        case .wallNotFound: return "The edited wall no longer exists."
        case .degenerateWall: return "The edit would collapse a wall to zero length."
        case .openingWouldNotFit: return "A door, window, or opening would no longer fit on its wall. Move or resize it first."
        }
    }
}

public struct ProjectEndpointMoveResult: Sendable {
    public var project: PlanOpsisProject
    public var move: EndpointMoveResult
}

extension PlanEditingConstraintEngine {
    /// v12.1 single semantic path for every wall-endpoint edit (grips, numeric fields, measured
    /// corrections and reviewed CAD returns).
    ///
    /// `HostedOpeningParameters.offsetAlongWall` is measured from the wall start, so moving a start
    /// endpoint would otherwise slide every hosted opening in world space. Each opening on a wall whose
    /// start moved keeps its distance from the endpoint that stayed fixed; the edit is rejected
    /// atomically if any opening would leave its host.
    ///
    /// - Parameter roomID: limits junction propagation to one room; nil propagates across all rooms.
    public func moveEndpoint(
        wallID: UUID,
        endpoint: WallEndpointKind,
        proposed: Point2D,
        in project: PlanOpsisProject,
        roomID: UUID?,
        settings: PlanEditingSettings,
        applyConstraints: Bool = true
    ) throws -> ProjectEndpointMoveResult {
        let scoped = project.rooms.filter { roomID == nil || $0.id == roomID }
        let before = scoped.flatMap(\.walls)
        guard before.contains(where: { $0.id == wallID }),
              let move = moveEndpoint(wallID: wallID, endpoint: endpoint, proposed: proposed, in: before, settings: settings, applyConstraints: applyConstraints)
        else { throw WallEndpointEditError.wallNotFound(wallID) }

        let previous = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let edited = Dictionary(uniqueKeysWithValues: move.walls.map { ($0.id, $0) })
        var next = project
        for roomIndex in next.rooms.indices where roomID == nil || next.rooms[roomIndex].id == roomID {
            next.rooms[roomIndex].walls = next.rooms[roomIndex].walls.map { edited[$0.id] ?? $0 }
            for wall in next.rooms[roomIndex].walls where wall != previous[wall.id] && wall.length <= 1e-6 {
                throw WallEndpointEditError.degenerateWall(wall.id)
            }
            next.rooms[roomIndex].openings = try Self.reanchorHostedOpenings(
                next.rooms[roomIndex].openings,
                previousWalls: previous,
                editedWalls: edited
            )
        }
        return ProjectEndpointMoveResult(project: next, move: move)
    }

    /// Re-anchors openings hosted by edited walls. An opening keeps its distance from the wall end that
    /// did not move; when both ends moved it keeps its world station projected onto the new axis.
    public static func reanchorHostedOpenings(
        _ openings: [PlanOpsisOpening],
        previousWalls: [UUID: PlanOpsisWall],
        editedWalls: [UUID: PlanOpsisWall],
        coincidenceTolerance: Double = 1e-6
    ) throws -> [PlanOpsisOpening] {
        try openings.map { opening in
            var parameters = opening.parameters
            guard let old = previousWalls[parameters.hostWallID],
                  let new = editedWalls[parameters.hostWallID],
                  old != new else { return opening }
            let startMoved = (old.start - new.start).length > coincidenceTolerance
            let endMoved = (old.end - new.end).length > coincidenceTolerance
            if startMoved && !endMoved {
                parameters.offsetAlongWall = new.length - (old.length - parameters.offsetAlongWall)
            } else if startMoved && endMoved {
                let world = old.start + old.direction * parameters.offsetAlongWall
                parameters.offsetAlongWall = (world - new.start).dot(new.direction)
            }
            let half = parameters.width * 0.5
            guard parameters.offsetAlongWall - half >= -coincidenceTolerance,
                  parameters.offsetAlongWall + half <= new.length + coincidenceTolerance else {
                throw WallEndpointEditError.openingWouldNotFit(openingID: opening.id, hostWallID: new.id)
            }
            var updated = opening
            updated.parameters = parameters
            return updated
        }
    }
}
