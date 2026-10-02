import Foundation

public struct ArchitecturalGeometrySnapshot: Codable, Hashable, Sendable {
    public var planWallSegments: [WallPlanSegment]
    public var wallSolids: [WallSolidSegment]
    public var hostedOpenings: [HostedOpeningGeometry]
    public var roomFloors: [RoomFloorGeometry]
    /// Derived structure-level evidence. Never persisted as architectural state.
    public var topology: StructureTopologySnapshot
    /// Derived reversible physical reconciliation. Never persisted as architectural state.
    public var reconciliation: StructureReconciliationSnapshot

    public init(
        planWallSegments: [WallPlanSegment],
        wallSolids: [WallSolidSegment],
        hostedOpenings: [HostedOpeningGeometry],
        roomFloors: [RoomFloorGeometry] = [],
        topology: StructureTopologySnapshot = .empty,
        reconciliation: StructureReconciliationSnapshot = .empty
    ) {
        self.planWallSegments = planWallSegments
        self.wallSolids = wallSolids
        self.hostedOpenings = hostedOpenings
        self.roomFloors = roomFloors
        self.topology = topology
        self.reconciliation = reconciliation
    }

    /// Whole-structure bounds used only for framing/navigation.
    public var floor: FloorGeometry? {
        guard let first = roomFloors.first?.bounds else { return nil }
        var minX = first.min.x
        var minY = first.min.y
        var maxX = first.max.x
        var maxY = first.max.y
        for floor in roomFloors.dropFirst().map(\.bounds) {
            minX = min(minX, floor.min.x)
            minY = min(minY, floor.min.y)
            maxX = max(maxX, floor.max.x)
            maxY = max(maxY, floor.max.y)
        }
        return FloorGeometry(min: Point2D(x: minX, y: minY), max: Point2D(x: maxX, y: maxY))
    }

    public func filtered(to roomID: UUID?) -> ArchitecturalGeometrySnapshot {
        guard let roomID else { return self }
        return ArchitecturalGeometrySnapshot(
            planWallSegments: planWallSegments.filter { $0.roomID == roomID },
            wallSolids: wallSolids.filter { $0.roomID == roomID },
            hostedOpenings: hostedOpenings.filter { $0.roomID == roomID },
            roomFloors: roomFloors.filter { $0.roomID == roomID },
            topology: topology.filtered(to: roomID),
            reconciliation: reconciliation.filtered(to: roomID)
        )
    }
}

public struct RoomFloorGeometry: Codable, Hashable, Sendable, Identifiable {
    public var roomID: UUID
    /// Ordered room-centerline polygon when a closed wall loop can be proven.
    /// Empty means the floor currently falls back to its bounds only.
    public var polygon: [Point2D]
    public var bounds: FloorGeometry

    public var id: UUID { roomID }

    public init(roomID: UUID, bounds: FloorGeometry, polygon: [Point2D] = []) {
        self.roomID = roomID
        self.polygon = polygon
        self.bounds = bounds
    }
}

public struct WallPlanSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(roomID.uuidString):\(hostWallID.uuidString):\(startOffset):\(length)" }
    public var roomID: UUID
    public var hostWallID: UUID
    public var startOffset: Double
    public var length: Double
    public var thickness: Double
    public var footprint: [Point2D]

    public init(roomID: UUID, hostWallID: UUID, startOffset: Double, length: Double, thickness: Double, footprint: [Point2D]) {
        self.roomID = roomID
        self.hostWallID = hostWallID
        self.startOffset = startOffset
        self.length = length
        self.thickness = thickness
        self.footprint = footprint
    }
}

public struct WallSolidSegment: Codable, Hashable, Sendable, Identifiable {
    public enum SegmentKind: String, Codable, Hashable, Sendable {
        case fullHeight
        case sill
        case header
        case verticalBand
    }

    public var id: String { "\(roomID.uuidString):\(hostWallID.uuidString):\(kind.rawValue):\(startOffset):\(bottom):\(length):\(height)" }
    public var roomID: UUID
    public var hostWallID: UUID
    public var kind: SegmentKind
    public var startOffset: Double
    public var length: Double
    public var bottom: Double
    public var height: Double
    public var thickness: Double
    /// Canonical segment center/angle/length remain tied to semantic offsets for validation.
    public var center: Point2D
    public var angleRadians: Double
    /// v8 joined-wall presentation axis. These may extend/snap only in derived display geometry.
    public var renderLength: Double
    public var renderCenter: Point2D
    public var renderAngleRadians: Double

    public init(
        roomID: UUID,
        hostWallID: UUID,
        kind: SegmentKind,
        startOffset: Double,
        length: Double,
        bottom: Double,
        height: Double,
        thickness: Double,
        center: Point2D,
        angleRadians: Double,
        renderLength: Double? = nil,
        renderCenter: Point2D? = nil,
        renderAngleRadians: Double? = nil
    ) {
        self.roomID = roomID
        self.hostWallID = hostWallID
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
}

public struct HostedOpeningGeometry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var roomID: UUID
    public var hostWallID: UUID
    public var kind: PlanOpsisOpening.Kind
    public var center: Point2D
    public var startOffset: Double
    public var width: Double
    public var height: Double
    public var sillHeight: Double
    public var angleRadians: Double
    public var thickness: Double
    public var doorSwing: PlanOpsisDoor.Swing
    public var doorOperation: PlanOpsisDoor.Operation?
    public var windowOperation: PlanOpsisWindow.Operation?

    public init(
        id: UUID,
        roomID: UUID,
        hostWallID: UUID,
        kind: PlanOpsisOpening.Kind,
        center: Point2D,
        startOffset: Double,
        width: Double,
        height: Double,
        sillHeight: Double,
        angleRadians: Double,
        thickness: Double,
        doorSwing: PlanOpsisDoor.Swing = .unspecified,
        doorOperation: PlanOpsisDoor.Operation? = nil,
        windowOperation: PlanOpsisWindow.Operation? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.hostWallID = hostWallID
        self.kind = kind
        self.center = center
        self.startOffset = startOffset
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
        self.angleRadians = angleRadians
        self.thickness = thickness
        self.doorSwing = doorSwing
        self.doorOperation = doorOperation
        self.windowOperation = windowOperation
    }
}

public struct FloorGeometry: Codable, Hashable, Sendable {
    public var min: Point2D
    public var max: Point2D

    public init(min: Point2D, max: Point2D) {
        self.min = min
        self.max = max
    }

    public var center: Point2D {
        Point2D(x: (min.x + max.x) * 0.5, y: (min.y + max.y) * 0.5)
    }

    public var width: Double { max.x - min.x }
    public var depth: Double { max.y - min.y }
}
