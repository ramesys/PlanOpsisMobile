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

    public init(
        orthoEnabled: Bool = false,
        gridEnabled: Bool = false,
        gridSpacing: Double = 250,
        endpointSnapTolerance: Double = 140,
        connectedEndpointTolerance: Double = 1
    ) {
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
