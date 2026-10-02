import Foundation

public struct RoomPlanAdapter {
    public struct Configuration {
        public var defaultWallThicknessMM: Double
        /// Openings whose bottom lies this far or less below the floor datum are treated as resting on
        /// the floor (capture noise). Deeper ones are clamped and diagnosed.
        public var floorNoiseToleranceMM: Double
        public var uuidProvider: () -> UUID

        public init(
            defaultWallThicknessMM: Double = 120,
            floorNoiseToleranceMM: Double = 30,
            uuidProvider: @escaping () -> UUID = UUID.init
        ) {
            self.defaultWallThicknessMM = defaultWallThicknessMM
            self.floorNoiseToleranceMM = floorNoiseToleranceMM
            self.uuidProvider = uuidProvider
        }
    }

    public enum Diagnostic: Hashable, Sendable {
        case missingHost(surfaceSourceID: UUID, parentSourceID: UUID?)
        case invalidWallDirection(surfaceSourceID: UUID)
        case invalidWallDimensions(surfaceSourceID: UUID)
        case invalidOpeningDimensions(surfaceSourceID: UUID)
        case unsupportedCurvedWall(surfaceSourceID: UUID)
        case unsupportedComplexWall(surfaceSourceID: UUID, polygonCornerCount: Int)
        case openingExtendsBeyondHost(surfaceSourceID: UUID, hostWallID: UUID)
        case openingVerticalExtentOutsideHost(surfaceSourceID: UUID, hostWallID: UUID)
    }

    public struct Result {
        public var project: PlanOpsisProject
        public var diagnostics: [Diagnostic]

        public init(project: PlanOpsisProject, diagnostics: [Diagnostic]) {
            self.project = project
            self.diagnostics = diagnostics
        }
    }

    private let configuration: Configuration
    private let coordinates = RoomPlanCoordinateConverter()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Single-room compatibility path. Both real and mock single-room capture still use the same room adapter.
    public func adapt(_ snapshot: RoomCaptureSnapshot) -> Result {
        adapt(StructureCaptureSnapshot(room: snapshot))
    }

    /// Multi-room path.
    ///
    /// Coordinate convention:
    /// - RoomPlan remains in metres in capture snapshots.
    /// - All rooms are expected to occupy one compatible RoomPlan/AR world space.
    /// - At this adapter boundary all lengths become millimetres.
    /// - PlanOpsis plan X = RoomPlan world X.
    /// - PlanOpsis plan Y = -RoomPlan world Z.
    /// - Vertical height = RoomPlan world Y.
    public func adapt(_ snapshot: StructureCaptureSnapshot) -> Result {
        var diagnostics: [Diagnostic] = []
        var rooms: [PlanOpsisRoom] = []
        rooms.reserveCapacity(snapshot.rooms.count)

        for roomSnapshot in snapshot.rooms {
            let result = adaptRoom(roomSnapshot)
            rooms.append(result.room)
            diagnostics.append(contentsOf: result.diagnostics)
        }

        let project = PlanOpsisProject(
            id: configuration.uuidProvider(),
            sourceStructureRoomPlanID: snapshot.sourceStructureRoomPlanID,
            rooms: rooms
        )
        return Result(project: project, diagnostics: diagnostics)
    }

    private func adaptRoom(_ snapshot: RoomCaptureSnapshot) -> (room: PlanOpsisRoom, diagnostics: [Diagnostic]) {
        var diagnostics: [Diagnostic] = []
        var walls: [PlanOpsisWall] = []
        // v12.1: capture-space Y=0 is the device's start height, not the floor. Every semantic
        // elevation is measured from this room's floor datum instead.
        let floorElevationMM = coordinates.floorElevationMM(walls: snapshot.surfaces.filter { $0.category == .wall })
        var wallIDBySourceID: [UUID: UUID] = [:]

        for surface in snapshot.surfaces where surface.category == .wall {
            if surface.shapeHints.hasCurve {
                diagnostics.append(.unsupportedCurvedWall(surfaceSourceID: surface.sourceRoomPlanID))
                continue
            }
            if surface.shapeHints.hasComplexPolygon {
                diagnostics.append(.unsupportedComplexWall(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    polygonCornerCount: surface.shapeHints.polygonCornerCount
                ))
                continue
            }
            guard surface.dimensions.x > 1e-6, surface.dimensions.y > 1e-6 else {
                diagnostics.append(.invalidWallDimensions(surfaceSourceID: surface.sourceRoomPlanID))
                continue
            }

            let rawDirection = Point2D(
                x: surface.transform.localXAxisX,
                y: -surface.transform.localXAxisZ
            )
            guard rawDirection.length > 1e-9 else {
                diagnostics.append(.invalidWallDirection(surfaceSourceID: surface.sourceRoomPlanID))
                continue
            }

            let normalizedDirection = coordinates.planDirection(from: surface.transform)
            let lengthMM = coordinates.millimetres(fromMetres: surface.dimensions.x)
            let center = coordinates.planPointMM(from: surface.transform)
            let start = center - normalizedDirection * (lengthMM * 0.5)
            let wallID = configuration.uuidProvider()
            wallIDBySourceID[surface.sourceRoomPlanID] = wallID
            walls.append(PlanOpsisWall(
                id: wallID,
                sourceRoomPlanID: surface.sourceRoomPlanID,
                start: start,
                length: lengthMM,
                angleRadians: atan2(normalizedDirection.y, normalizedDirection.x),
                height: coordinates.millimetres(fromMetres: surface.dimensions.y),
                thickness: max(0, configuration.defaultWallThicknessMM),
                confidence: surface.confidence
            ))
        }

        var openings: [PlanOpsisOpening] = []
        for surface in snapshot.surfaces where surface.category != .wall {
            guard surface.dimensions.x > 1e-6, surface.dimensions.y > 1e-6 else {
                diagnostics.append(.invalidOpeningDimensions(surfaceSourceID: surface.sourceRoomPlanID))
                continue
            }

            guard
                let parentSourceID = surface.parentIdentifier,
                let hostWallID = wallIDBySourceID[parentSourceID],
                let hostWall = walls.first(where: { $0.id == hostWallID })
            else {
                diagnostics.append(.missingHost(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    parentSourceID: surface.parentIdentifier
                ))
                continue
            }

            let center = coordinates.planPointMM(from: surface.transform)
            let relative = center - hostWall.start
            let offset = relative.dot(hostWall.direction)
            let widthMM = coordinates.millimetres(fromMetres: surface.dimensions.x)
            let heightMM = coordinates.millimetres(fromMetres: surface.dimensions.y)
            let rawSillMM = coordinates.bottomElevationMM(surface: surface) - (floorElevationMM ?? 0)
            let sillMM = max(0, rawSillMM)
            let halfWidth = widthMM * 0.5

            if offset - halfWidth < -1e-6 || offset + halfWidth > hostWall.length + 1e-6 {
                diagnostics.append(.openingExtendsBeyondHost(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    hostWallID: hostWallID
                ))
            }
            if rawSillMM < -configuration.floorNoiseToleranceMM || sillMM + heightMM > hostWall.height + 1e-6 {
                diagnostics.append(.openingVerticalExtentOutsideHost(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    hostWallID: hostWallID
                ))
            }

            let parameters = HostedOpeningParameters(
                id: configuration.uuidProvider(),
                sourceRoomPlanID: surface.sourceRoomPlanID,
                hostWallID: hostWallID,
                offsetAlongWall: offset,
                width: widthMM,
                height: heightMM,
                sillHeight: sillMM,
                confidence: surface.confidence
            )

            switch surface.category {
            case .door:
                openings.append(.door(PlanOpsisDoor(parameters: parameters)))
            case .window:
                openings.append(.window(PlanOpsisWindow(parameters: parameters)))
            case .opening:
                openings.append(.opening(parameters))
            case .wall:
                break
            }
        }

        return (
            PlanOpsisRoom(
                id: configuration.uuidProvider(),
                sourceRoomPlanID: snapshot.sourceRoomPlanID,
                walls: walls,
                openings: openings,
                captureFloorElevationMM: floorElevationMM
            ),
            diagnostics
        )
    }
}
