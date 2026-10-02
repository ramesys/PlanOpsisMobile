import Foundation

public struct RoomPlanAdapter {
    public struct Configuration {
        public var defaultWallThicknessMM: Double
        /// Openings whose bottom lies this far or less below the floor datum are treated as resting on
        /// the floor (capture noise). Deeper ones are clamped and diagnosed.
        public var floorNoiseToleranceMM: Double
        /// v12.1: close wall junctions within `GeometryTolerances.junctionJoinMM` in the semantic model.
        public var normalizeJunctions: Bool
        public var uuidProvider: () -> UUID

        public init(
            defaultWallThicknessMM: Double = 120,
            floorNoiseToleranceMM: Double = 30,
            normalizeJunctions: Bool = true,
            uuidProvider: @escaping () -> UUID = UUID.init
        ) {
            self.defaultWallThicknessMM = defaultWallThicknessMM
            self.floorNoiseToleranceMM = floorNoiseToleranceMM
            self.normalizeJunctions = normalizeJunctions
            self.uuidProvider = uuidProvider
        }
    }

    public enum Diagnostic: Hashable, Sendable {
        case missingHost(surfaceSourceID: UUID, parentSourceID: UUID?)
        case invalidWallDirection(surfaceSourceID: UUID)
        case invalidWallDimensions(surfaceSourceID: UUID)
        case invalidOpeningDimensions(surfaceSourceID: UUID)
        /// v12.2: imported as its straight chord; review the drawing.
        case unsupportedCurvedWall(surfaceSourceID: UUID)
        /// v12.2: a non-rectangular wall (e.g. under a sloped ceiling) imported at its full width and height.
        case unsupportedComplexWall(surfaceSourceID: UUID, polygonCornerCount: Int)
        case openingExtendsBeyondHost(surfaceSourceID: UUID, hostWallID: UUID)
        case openingVerticalExtentOutsideHost(surfaceSourceID: UUID, hostWallID: UUID)
        /// v12.1: less than half of the observed opening lies on its host wall; it was not imported.
        case openingMostlyOutsideHost(surfaceSourceID: UUID, hostWallID: UUID)
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

        var project = PlanOpsisProject(
            id: configuration.uuidProvider(),
            sourceStructureRoomPlanID: snapshot.sourceStructureRoomPlanID,
            rooms: rooms
        )
        if configuration.normalizeJunctions {
            project = JunctionNormalizer().normalize(project).project
        }
        return Result(project: project, diagnostics: diagnostics)
    }

    private func adaptRoom(_ snapshot: RoomCaptureSnapshot) -> (room: PlanOpsisRoom, diagnostics: [Diagnostic]) {
        var diagnostics: [Diagnostic] = []
        var walls: [PlanOpsisWall] = []
        // v12.1: capture-space Y=0 is the device's start height, not the floor. Every semantic
        // elevation is measured from this room's floor datum instead.
        let floorElevationMM = coordinates.floorElevationMM(walls: snapshot.surfaces.filter { $0.category == .wall })
        var wallIDBySourceID: [UUID: UUID] = [:]
        var roomSideNormalByWallID: [UUID: Point2D] = [:]

        for surface in snapshot.surfaces where surface.category == .wall {
            // v12.2: irregular walls are imported as straight walls rather than dropped. Dropping them opened
            // the room and blocked export; a diagnosed straight wall keeps the plan usable and reviewable.
            if surface.shapeHints.hasCurve {
                diagnostics.append(.unsupportedCurvedWall(surfaceSourceID: surface.sourceRoomPlanID))
            } else if surface.shapeHints.hasComplexPolygon {
                diagnostics.append(.unsupportedComplexWall(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    polygonCornerCount: surface.shapeHints.polygonCornerCount
                ))
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
            roomSideNormalByWallID[wallID] = coordinates.planNormal(from: surface.transform)
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

        if snapshot.wallReference == .interiorFace {
            walls = Self.registerInteriorFaces(walls, roomSideNormals: roomSideNormalByWallID)
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
            // v12.1 overhang policy: the semantic opening is the part of the observation that lies on its
            // host wall. Exporters reject openings outside their host, so clamping here keeps real scans
            // exportable; an observation mostly off its host is evidence of a wrong host, not an opening.
            let observedStart = offset - widthMM * 0.5
            let observedEnd = offset + widthMM * 0.5
            let clampedStart = max(0, observedStart)
            let clampedEnd = min(hostWall.length, observedEnd)
            let clampedTop = min(hostWall.height, sillMM + heightMM)
            let clampedWidth = clampedEnd - clampedStart
            let clampedHeight = clampedTop - sillMM
            guard clampedWidth >= widthMM * 0.5, clampedHeight >= heightMM * 0.5 else {
                diagnostics.append(.openingMostlyOutsideHost(
                    surfaceSourceID: surface.sourceRoomPlanID,
                    hostWallID: hostWallID
                ))
                continue
            }

            if observedStart < -1e-6 || observedEnd > hostWall.length + 1e-6 {
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
                offsetAlongWall: (clampedStart + clampedEnd) * 0.5,
                width: clampedWidth,
                height: clampedHeight,
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

    /// v12.2: RoomPlan wall surfaces are the scanned room-side faces, so the semantic wall axis lies
    /// half a thickness behind each face (opposite the surface's room-side normal). Corners that met on
    /// the faces are re-joined on the axes: each corner moves to the point closest to all of its walls'
    /// offset axes (the exact mitre for a two-wall corner), keeping the observed faces in place.
    static func registerInteriorFaces(_ walls: [PlanOpsisWall], roomSideNormals: [UUID: Point2D]) -> [PlanOpsisWall] {
        struct End { var wall: Int; var isStart: Bool; var face: Point2D }
        let axisLines: [(point: Point2D, direction: Point2D)] = walls.map { wall in
            let normal = roomSideNormals[wall.id] ?? .zero
            return (wall.start - normal * (wall.thickness * 0.5), wall.direction)
        }
        func offsetEnd(_ end: End) -> Point2D {
            let wall = walls[end.wall]
            let normal = roomSideNormals[wall.id] ?? .zero
            return end.face - normal * (wall.thickness * 0.5)
        }

        // Cluster face corners deterministically (by source order) within the capture join radius.
        var clusters: [[End]] = []
        var centers: [Point2D] = []
        for (index, wall) in walls.enumerated() {
            let radius = GeometryTolerances.joinRadius(GeometryTolerances.junctionJoinMM, wallLength: wall.length)
            var startCluster: Int?
            for end in [End(wall: index, isStart: true, face: wall.start), End(wall: index, isStart: false, face: wall.end)] {
                if let k = centers.indices
                    .filter({ $0 != startCluster && (centers[$0] - end.face).length <= radius })
                    .min(by: { (centers[$0] - end.face).length < (centers[$1] - end.face).length }) {
                    if end.isStart { startCluster = k }
                    clusters[k].append(end)
                    let n = Double(clusters[k].count)
                    centers[k] = centers[k] * ((n - 1) / n) + end.face * (1 / n)
                } else {
                    clusters.append([end])
                    centers.append(end.face)
                    if end.isStart { startCluster = clusters.count - 1 }
                }
            }
        }

        var starts = walls.map(\.start), ends = walls.map(\.end)
        for (k, members) in clusters.enumerated() {
            let offsets = members.map(offsetEnd)
            var point = offsets.reduce(.zero, +) * (1 / Double(offsets.count))
            if members.count >= 2 {
                // Least-squares point closest to every member's offset axis.
                var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
                for end in members {
                    let line = axisLines[end.wall]
                    let n = Point2D(x: -line.direction.y, y: line.direction.x)
                    let c = n.dot(line.point)
                    a11 += n.x * n.x; a12 += n.x * n.y; a22 += n.y * n.y
                    b1 += n.x * c; b2 += n.y * c
                }
                let det = a11 * a22 - a12 * a12
                let maxThickness = members.map { walls[$0.wall].thickness }.max() ?? 0
                // Nearly parallel members (straight continuations) keep the averaged offset ends.
                if det > 0.03 * 0.03 * Double(members.count * members.count) {
                    let solved = Point2D(x: (b1 * a22 - b2 * a12) / det, y: (a11 * b2 - a12 * b1) / det)
                    if solved.x.isFinite, solved.y.isFinite, (solved - centers[k]).length <= max(600, maxThickness * 6) {
                        point = solved
                    }
                }
            }
            for end in members {
                if end.isStart { starts[end.wall] = point } else { ends[end.wall] = point }
            }
        }

        return walls.indices.map { index in
            var wall = walls[index]
            guard (ends[index] - starts[index]).length > GeometryTolerances.coincidenceMM else { return wall }
            wall.editStart(starts[index])
            wall.editEnd(ends[index])
            return wall
        }
    }
}
