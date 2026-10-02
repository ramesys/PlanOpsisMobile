import Foundation

public enum SharedBoundaryStrength: String, Codable, Hashable, Sendable {
    /// Near-coincident, near-parallel, almost full-length evidence. Safe to treat as the same
    /// physical partition for diagnostics/presentation, but semantic wall UUIDs remain independent.
    case strong
    /// Geometrically plausible shared partition that requires review/device evidence.
    case candidate
}

public struct SharedBoundary: Codable, Hashable, Sendable, Identifiable {
    public var roomAID: UUID
    public var wallAID: UUID
    public var roomBID: UUID
    public var wallBID: UUID
    public var overlapStart: Point2D
    public var overlapEnd: Point2D
    public var overlapLength: Double
    public var overlapRatio: Double
    public var centerlineSeparation: Double
    public var angleDifferenceRadians: Double
    public var strength: SharedBoundaryStrength

    public var id: String {
        let wallIDs = [wallAID.uuidString, wallBID.uuidString].sorted()
        return "shared:\(wallIDs[0]):\(wallIDs[1])"
    }

    public init(
        roomAID: UUID,
        wallAID: UUID,
        roomBID: UUID,
        wallBID: UUID,
        overlapStart: Point2D,
        overlapEnd: Point2D,
        overlapLength: Double,
        overlapRatio: Double,
        centerlineSeparation: Double,
        angleDifferenceRadians: Double,
        strength: SharedBoundaryStrength
    ) {
        self.roomAID = roomAID
        self.wallAID = wallAID
        self.roomBID = roomBID
        self.wallBID = wallBID
        self.overlapStart = overlapStart
        self.overlapEnd = overlapEnd
        self.overlapLength = overlapLength
        self.overlapRatio = overlapRatio
        self.centerlineSeparation = centerlineSeparation
        self.angleDifferenceRadians = angleDifferenceRadians
        self.strength = strength
    }

    public func contains(roomID: UUID) -> Bool {
        roomAID == roomID || roomBID == roomID
    }

    public func contains(wallID: UUID) -> Bool {
        wallAID == wallID || wallBID == wallID
    }
}

public struct RoomPassageConnection: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case door
        case genericOpening
        case mixed
    }

    public var roomAID: UUID
    public var openingAID: UUID
    public var roomBID: UUID
    public var openingBID: UUID
    public var sharedBoundaryID: String
    public var centerDistance: Double
    public var kind: Kind

    public var id: String {
        let openingIDs = [openingAID.uuidString, openingBID.uuidString].sorted()
        return "passage:\(openingIDs[0]):\(openingIDs[1])"
    }

    public init(
        roomAID: UUID,
        openingAID: UUID,
        roomBID: UUID,
        openingBID: UUID,
        sharedBoundaryID: String,
        centerDistance: Double,
        kind: Kind
    ) {
        self.roomAID = roomAID
        self.openingAID = openingAID
        self.roomBID = roomBID
        self.openingBID = openingBID
        self.sharedBoundaryID = sharedBoundaryID
        self.centerDistance = centerDistance
        self.kind = kind
    }
}

public struct RoomAdjacency: Codable, Hashable, Sendable, Identifiable {
    public var roomAID: UUID
    public var roomBID: UUID
    public var sharedBoundaryIDs: [String]
    public var passageConnectionIDs: [String]

    public var id: String {
        let ids = [roomAID.uuidString, roomBID.uuidString].sorted()
        return "adjacency:\(ids[0]):\(ids[1])"
    }

    public init(
        roomAID: UUID,
        roomBID: UUID,
        sharedBoundaryIDs: [String],
        passageConnectionIDs: [String]
    ) {
        self.roomAID = roomAID
        self.roomBID = roomBID
        self.sharedBoundaryIDs = sharedBoundaryIDs.sorted()
        self.passageConnectionIDs = passageConnectionIDs.sorted()
    }

    public func contains(roomID: UUID) -> Bool {
        roomAID == roomID || roomBID == roomID
    }
}

public struct RoomBoundary: Codable, Hashable, Sendable, Identifiable {
    public var roomID: UUID
    /// Ordered centerline vertices. The first vertex is not duplicated at the end.
    public var polygon: [Point2D]
    public var isClosed: Bool
    public var unmatchedEndpointCount: Int

    public var id: UUID { roomID }

    public init(roomID: UUID, polygon: [Point2D], isClosed: Bool, unmatchedEndpointCount: Int) {
        self.roomID = roomID
        self.polygon = polygon
        self.isClosed = isClosed
        self.unmatchedEndpointCount = unmatchedEndpointCount
    }
}

public struct StructureTopologyIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case openRoomBoundary
        case ambiguousSharedBoundary
    }

    public var code: Code
    public var roomID: UUID?
    public var wallID: UUID?
    public var relatedCount: Int

    public var id: String {
        "issue:\(code.rawValue):\(roomID?.uuidString ?? "none"):\(wallID?.uuidString ?? "none"):\(relatedCount)"
    }

    public init(code: Code, roomID: UUID? = nil, wallID: UUID? = nil, relatedCount: Int = 0) {
        self.code = code
        self.roomID = roomID
        self.wallID = wallID
        self.relatedCount = relatedCount
    }
}

public struct StructureTopologySnapshot: Codable, Hashable, Sendable {
    public var roomBoundaries: [RoomBoundary]
    public var sharedBoundaries: [SharedBoundary]
    public var passageConnections: [RoomPassageConnection]
    public var adjacencies: [RoomAdjacency]
    public var issues: [StructureTopologyIssue]

    public init(
        roomBoundaries: [RoomBoundary] = [],
        sharedBoundaries: [SharedBoundary] = [],
        passageConnections: [RoomPassageConnection] = [],
        adjacencies: [RoomAdjacency] = [],
        issues: [StructureTopologyIssue] = []
    ) {
        self.roomBoundaries = roomBoundaries
        self.sharedBoundaries = sharedBoundaries
        self.passageConnections = passageConnections
        self.adjacencies = adjacencies
        self.issues = issues
    }

    public static let empty = StructureTopologySnapshot()

    public func filtered(to roomID: UUID?) -> StructureTopologySnapshot {
        guard let roomID else { return self }
        let shared = sharedBoundaries.filter { $0.contains(roomID: roomID) }
        let sharedIDs = Set(shared.map(\.id))
        let passages = passageConnections.filter { connection in
            connection.roomAID == roomID || connection.roomBID == roomID || sharedIDs.contains(connection.sharedBoundaryID)
        }
        return StructureTopologySnapshot(
            roomBoundaries: roomBoundaries.filter { $0.roomID == roomID },
            sharedBoundaries: shared,
            passageConnections: passages,
            adjacencies: adjacencies.filter { $0.contains(roomID: roomID) },
            issues: issues.filter { $0.roomID == nil || $0.roomID == roomID }
        )
    }
}

/// Pure structure-level topology derived from the PlanOpsis semantic model.
///
/// Important: this engine never merges or rewrites semantic UUIDs. A shared boundary is evidence
/// that two room-local walls likely describe one physical partition. The semantic walls remain
/// independent until a future explicit reconciliation workflow confirms ownership.
public struct StructureTopologyEngine {
    public struct Configuration: Hashable, Sendable {
        public var endpointSnapToleranceMM: Double
        public var parallelAngleToleranceRadians: Double
        public var strongAngleToleranceRadians: Double
        public var centerlineSeparationToleranceMM: Double
        public var strongCenterlineSeparationMM: Double
        public var minimumSharedOverlapMM: Double
        public var minimumCandidateOverlapRatio: Double
        public var strongOverlapRatio: Double
        public var passageCenterToleranceMM: Double

        public init(
            endpointSnapToleranceMM: Double = GeometryTolerances.junctionJoinMM,
            parallelAngleToleranceRadians: Double = 3 * .pi / 180,
            strongAngleToleranceRadians: Double = 1 * .pi / 180,
            centerlineSeparationToleranceMM: Double = 220,
            strongCenterlineSeparationMM: Double = 60,
            minimumSharedOverlapMM: Double = 500,
            minimumCandidateOverlapRatio: Double = 0.60,
            strongOverlapRatio: Double = 0.90,
            passageCenterToleranceMM: Double = 260
        ) {
            self.endpointSnapToleranceMM = endpointSnapToleranceMM
            self.parallelAngleToleranceRadians = parallelAngleToleranceRadians
            self.strongAngleToleranceRadians = strongAngleToleranceRadians
            self.centerlineSeparationToleranceMM = centerlineSeparationToleranceMM
            self.strongCenterlineSeparationMM = strongCenterlineSeparationMM
            self.minimumSharedOverlapMM = minimumSharedOverlapMM
            self.minimumCandidateOverlapRatio = minimumCandidateOverlapRatio
            self.strongOverlapRatio = strongOverlapRatio
            self.passageCenterToleranceMM = passageCenterToleranceMM
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func generate(from project: PlanOpsisProject) -> StructureTopologySnapshot {
        var issues: [StructureTopologyIssue] = []
        let roomBoundaries = project.rooms.map { room in
            let result = boundary(for: room)
            if !result.isClosed {
                issues.append(StructureTopologyIssue(
                    code: .openRoomBoundary,
                    roomID: room.id,
                    relatedCount: result.unmatchedEndpointCount
                ))
            }
            return result
        }

        var shared = sharedBoundaries(in: project)
        shared.sort { $0.id < $1.id }

        var matchCountByWall: [UUID: Int] = [:]
        for match in shared {
            matchCountByWall[match.wallAID, default: 0] += 1
            matchCountByWall[match.wallBID, default: 0] += 1
        }
        for (wallID, count) in matchCountByWall where count > 1 {
            let roomID = project.rooms.first(where: { $0.walls.contains(where: { $0.id == wallID }) })?.id
            issues.append(StructureTopologyIssue(
                code: .ambiguousSharedBoundary,
                roomID: roomID,
                wallID: wallID,
                relatedCount: count
            ))
        }

        let passages = passageConnections(project: project, sharedBoundaries: shared)
        let adjacencies = roomAdjacencies(sharedBoundaries: shared, passages: passages)

        return StructureTopologySnapshot(
            roomBoundaries: roomBoundaries.sorted { $0.roomID.uuidString < $1.roomID.uuidString },
            sharedBoundaries: shared,
            passageConnections: passages.sorted { $0.id < $1.id },
            adjacencies: adjacencies.sorted { $0.id < $1.id },
            issues: issues.sorted { $0.id < $1.id }
        )
    }

    private struct EndpointCluster {
        var point: Point2D
        var count: Int

        mutating func absorb(_ point: Point2D) {
            let n = Double(count)
            self.point = Point2D(
                x: (self.point.x * n + point.x) / (n + 1),
                y: (self.point.y * n + point.y) / (n + 1)
            )
            count += 1
        }
    }

    private struct BoundaryEdge {
        var wallID: UUID
        var a: Int
        var b: Int
    }

    private func boundary(for room: PlanOpsisRoom) -> RoomBoundary {
        let walls = room.walls.sorted { $0.id.uuidString < $1.id.uuidString }
        guard walls.count >= 3 else {
            return RoomBoundary(
                roomID: room.id,
                polygon: walls.flatMap { [$0.start, $0.end] },
                isClosed: false,
                unmatchedEndpointCount: walls.count * 2
            )
        }

        var clusters: [EndpointCluster] = []
        var edges: [BoundaryEdge] = []

        func nearestClusterIndex(to point: Point2D, in clusters: [EndpointCluster], tolerance: Double, excluding: Int?) -> Int? {
            var bestIndex: Int?
            var bestDistance = tolerance
            for (index, cluster) in clusters.enumerated() where index != excluding {
                let distance = (cluster.point - point).length
                if distance <= bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            return bestIndex
        }

        for wall in walls {
            let endpointPoints = [wall.start, wall.end]
            var nodeIndices: [Int] = []
            let tolerance = GeometryTolerances.joinRadius(configuration.endpointSnapToleranceMM, wallLength: wall.length)
            for point in endpointPoints {
                if let existing = nearestClusterIndex(to: point, in: clusters, tolerance: tolerance, excluding: nodeIndices.first) {
                    clusters[existing].absorb(point)
                    nodeIndices.append(existing)
                } else {
                    clusters.append(EndpointCluster(point: point, count: 1))
                    nodeIndices.append(clusters.count - 1)
                }
            }
            edges.append(BoundaryEdge(wallID: wall.id, a: nodeIndices[0], b: nodeIndices[1]))
        }

        var edgeIndicesByNode: [Int: [Int]] = [:]
        for (edgeIndex, edge) in edges.enumerated() {
            edgeIndicesByNode[edge.a, default: []].append(edgeIndex)
            edgeIndicesByNode[edge.b, default: []].append(edgeIndex)
        }

        let unmatchedEndpointCount = edgeIndicesByNode.values.filter { $0.count != 2 }.reduce(0) { partial, incident in
            partial + abs(2 - incident.count)
        }
        guard unmatchedEndpointCount == 0 else {
            return RoomBoundary(
                roomID: room.id,
                polygon: clusters.map(\.point),
                isClosed: false,
                unmatchedEndpointCount: unmatchedEndpointCount
            )
        }

        let startNode = clusters.indices.min { lhs, rhs in
            let a = clusters[lhs].point
            let b = clusters[rhs].point
            if a.x == b.x { return a.y < b.y }
            return a.x < b.x
        } ?? 0

        var polygon: [Point2D] = []
        var visitedEdges = Set<Int>()
        var currentNode = startNode
        var previousEdge: Int?

        for _ in 0...edges.count {
            polygon.append(clusters[currentNode].point)
            let candidates = (edgeIndicesByNode[currentNode] ?? [])
                .filter { $0 != previousEdge }
                .sorted { edges[$0].wallID.uuidString < edges[$1].wallID.uuidString }

            guard let nextEdge = candidates.first(where: { !visitedEdges.contains($0) }) else {
                break
            }
            visitedEdges.insert(nextEdge)
            let edge = edges[nextEdge]
            let nextNode = edge.a == currentNode ? edge.b : edge.a
            previousEdge = nextEdge
            currentNode = nextNode
            if currentNode == startNode { break }
        }

        let isClosed = currentNode == startNode && visitedEdges.count == edges.count
        guard isClosed else {
            return RoomBoundary(
                roomID: room.id,
                polygon: polygon,
                isClosed: false,
                unmatchedEndpointCount: max(1, edges.count - visitedEdges.count)
            )
        }

        if signedArea(polygon) < 0 {
            polygon.reverse()
        }
        return RoomBoundary(roomID: room.id, polygon: polygon, isClosed: true, unmatchedEndpointCount: 0)
    }

    private func signedArea(_ polygon: [Point2D]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var area = 0.0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            let current = polygon[index]
            area += current.x * next.y - next.x * current.y
        }
        return area * 0.5
    }

    private func sharedBoundaries(in project: PlanOpsisProject) -> [SharedBoundary] {
        guard project.rooms.count > 1 else { return [] }
        var result: [SharedBoundary] = []

        for i in 0..<(project.rooms.count - 1) {
            for j in (i + 1)..<project.rooms.count {
                let roomA = project.rooms[i]
                let roomB = project.rooms[j]
                for wallA in roomA.walls {
                    for wallB in roomB.walls {
                        if let match = matchSharedBoundary(roomAID: roomA.id, wallA: wallA, roomBID: roomB.id, wallB: wallB) {
                            result.append(match)
                        }
                    }
                }
            }
        }
        return result
    }

    private func matchSharedBoundary(
        roomAID: UUID,
        wallA: PlanOpsisWall,
        roomBID: UUID,
        wallB: PlanOpsisWall
    ) -> SharedBoundary? {
        guard wallA.length > 1e-6, wallB.length > 1e-6 else { return nil }

        let angleDifference = orientationDifference(wallA.angleRadians, wallB.angleRadians)
        guard angleDifference <= configuration.parallelAngleToleranceRadians else { return nil }

        let distances = [wallB.start, wallB.end].map { abs(($0 - wallA.start).dot(wallA.normal)) }
        let separation = distances.max() ?? .greatestFiniteMagnitude
        guard separation <= configuration.centerlineSeparationToleranceMM else { return nil }

        let b0 = (wallB.start - wallA.start).dot(wallA.direction)
        let b1 = (wallB.end - wallA.start).dot(wallA.direction)
        let bMin = min(b0, b1)
        let bMax = max(b0, b1)
        let overlapStartOffset = max(0, bMin)
        let overlapEndOffset = min(wallA.length, bMax)
        let overlapLength = overlapEndOffset - overlapStartOffset
        guard overlapLength >= configuration.minimumSharedOverlapMM else { return nil }

        let ratio = overlapLength / max(1e-9, min(wallA.length, wallB.length))
        guard ratio >= configuration.minimumCandidateOverlapRatio else { return nil }

        let strength: SharedBoundaryStrength = (
            angleDifference <= configuration.strongAngleToleranceRadians &&
            separation <= configuration.strongCenterlineSeparationMM &&
            ratio >= configuration.strongOverlapRatio
        ) ? .strong : .candidate

        return SharedBoundary(
            roomAID: roomAID,
            wallAID: wallA.id,
            roomBID: roomBID,
            wallBID: wallB.id,
            overlapStart: wallA.start + wallA.direction * overlapStartOffset,
            overlapEnd: wallA.start + wallA.direction * overlapEndOffset,
            overlapLength: overlapLength,
            overlapRatio: ratio,
            centerlineSeparation: separation,
            angleDifferenceRadians: angleDifference,
            strength: strength
        )
    }

    private func orientationDifference(_ a: Double, _ b: Double) -> Double {
        var difference = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if difference > .pi { difference = 2 * .pi - difference }
        return min(difference, abs(.pi - difference))
    }

    private struct PassageCandidate {
        var openingA: PlanOpsisOpening
        var openingB: PlanOpsisOpening
        var distance: Double
        var boundary: SharedBoundary
    }

    private func passageConnections(
        project: PlanOpsisProject,
        sharedBoundaries: [SharedBoundary]
    ) -> [RoomPassageConnection] {
        var result: [RoomPassageConnection] = []
        var usedOpenings = Set<UUID>()

        for boundary in sharedBoundaries.sorted(by: { $0.id < $1.id }) {
            guard
                let roomA = project.rooms.first(where: { $0.id == boundary.roomAID }),
                let roomB = project.rooms.first(where: { $0.id == boundary.roomBID }),
                let wallA = roomA.walls.first(where: { $0.id == boundary.wallAID }),
                let wallB = roomB.walls.first(where: { $0.id == boundary.wallBID })
            else { continue }

            let openingsA = roomA.openings.filter { $0.parameters.hostWallID == wallA.id && $0.kind != .window }
            let openingsB = roomB.openings.filter { $0.parameters.hostWallID == wallB.id && $0.kind != .window }
            var candidates: [PassageCandidate] = []

            for openingA in openingsA {
                for openingB in openingsB {
                    let centerA = wallA.start + wallA.direction * openingA.parameters.offsetAlongWall
                    let centerB = wallB.start + wallB.direction * openingB.parameters.offsetAlongWall
                    let distance = (centerA - centerB).length
                    let widthTolerance = max(250, min(openingA.parameters.width, openingB.parameters.width) * 0.35)
                    guard distance <= configuration.passageCenterToleranceMM else { continue }
                    guard abs(openingA.parameters.width - openingB.parameters.width) <= widthTolerance else { continue }
                    candidates.append(PassageCandidate(
                        openingA: openingA,
                        openingB: openingB,
                        distance: distance,
                        boundary: boundary
                    ))
                }
            }

            candidates.sort {
                if $0.distance == $1.distance {
                    let aKey = $0.openingA.id.uuidString + $0.openingB.id.uuidString
                    let bKey = $1.openingA.id.uuidString + $1.openingB.id.uuidString
                    return aKey < bKey
                }
                return $0.distance < $1.distance
            }

            for candidate in candidates {
                guard !usedOpenings.contains(candidate.openingA.id), !usedOpenings.contains(candidate.openingB.id) else { continue }
                usedOpenings.insert(candidate.openingA.id)
                usedOpenings.insert(candidate.openingB.id)
                result.append(RoomPassageConnection(
                    roomAID: candidate.boundary.roomAID,
                    openingAID: candidate.openingA.id,
                    roomBID: candidate.boundary.roomBID,
                    openingBID: candidate.openingB.id,
                    sharedBoundaryID: candidate.boundary.id,
                    centerDistance: candidate.distance,
                    kind: passageKind(candidate.openingA.kind, candidate.openingB.kind)
                ))
            }
        }
        return result
    }

    private func passageKind(_ a: PlanOpsisOpening.Kind, _ b: PlanOpsisOpening.Kind) -> RoomPassageConnection.Kind {
        if a == .door && b == .door { return .door }
        if a == .opening && b == .opening { return .genericOpening }
        return .mixed
    }

    private func roomAdjacencies(
        sharedBoundaries: [SharedBoundary],
        passages: [RoomPassageConnection]
    ) -> [RoomAdjacency] {
        struct Pair: Hashable {
            var a: UUID
            var b: UUID
        }

        func pair(_ a: UUID, _ b: UUID) -> Pair {
            if a.uuidString < b.uuidString { return Pair(a: a, b: b) }
            return Pair(a: b, b: a)
        }

        var sharedByPair: [Pair: [String]] = [:]
        for boundary in sharedBoundaries {
            sharedByPair[pair(boundary.roomAID, boundary.roomBID), default: []].append(boundary.id)
        }

        var passagesByPair: [Pair: [String]] = [:]
        for passage in passages {
            passagesByPair[pair(passage.roomAID, passage.roomBID), default: []].append(passage.id)
        }

        return sharedByPair.keys.map { key in
            RoomAdjacency(
                roomAID: key.a,
                roomBID: key.b,
                sharedBoundaryIDs: sharedByPair[key] ?? [],
                passageConnectionIDs: passagesByPair[key] ?? []
            )
        }
    }
}
