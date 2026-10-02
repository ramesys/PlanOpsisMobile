import Foundation

// MARK: - Selection

public enum PlanBoxSelectionMode: String, Hashable, Sendable {
    /// Left-to-right box: only objects entirely inside are selected.
    case window
    /// Right-to-left box: objects inside or touching the box are selected.
    case crossing

    /// CAD convention: dragging to the right is a window, to the left a crossing box.
    public init(from start: Point2D, to end: Point2D) {
        self = end.x >= start.x ? .window : .crossing
    }
}

/// v12.3 selection queries for the plan editor. Pure: they read the drawn geometry and return IDs.
public enum PlanSelectionQuery {
    /// Walls, openings and components selected by a box, using what the plan draws (wall footprints,
    /// opening and component symbols).
    public static func objects(
        in rect: CADRect,
        mode: PlanBoxSelectionMode,
        snapshot: DisplayGeometrySnapshot,
        components: [PlanOpsisComponent]
    ) -> Set<UUID> {
        guard !rect.isEmpty else { return [] }
        var result = Set<UUID>()
        func test(_ outline: [Point2D]) -> Bool {
            guard !outline.isEmpty else { return false }
            switch mode {
            case .window: return outline.allSatisfy(rect.contains)
            case .crossing: return polygonTouches(outline, rect: rect)
            }
        }
        for segment in snapshot.planWallSegments {
            if let id = segment.primarySelectionID, test(segment.footprint) { result.insert(id) }
        }
        for opening in snapshot.hostedOpenings {
            let direction = Point2D(x: cos(opening.angleRadians), y: sin(opening.angleRadians))
            let normal = Point2D(x: -direction.y, y: direction.x)
            let a = direction * (opening.width / 2), b = normal * (opening.thickness / 2)
            let outline = [opening.center - a - b, opening.center + a - b, opening.center + a + b, opening.center - a + b]
            if let id = opening.primarySelectionID, test(outline) { result.insert(id) }
        }
        for component in components {
            guard let bounds = ArchitecturalSymbolLibrary.component(component).bounds else { continue }
            let outline = [bounds.min, Point2D(x: bounds.max.x, y: bounds.min.y), bounds.max, Point2D(x: bounds.min.x, y: bounds.max.y)]
            if test(outline) { result.insert(component.id) }
        }
        return result
    }

    /// True when a closed outline and a rectangle overlap at all.
    static func polygonTouches(_ polygon: [Point2D], rect: CADRect) -> Bool {
        if polygon.contains(where: rect.contains) { return true }
        let corners = [Point2D(x: rect.minX, y: rect.minY), Point2D(x: rect.maxX, y: rect.minY), Point2D(x: rect.maxX, y: rect.maxY), Point2D(x: rect.minX, y: rect.maxY)]
        if polygon.count >= 3, corners.contains(where: { CADMeasurement.contains($0, loops: [polygon]) }) { return true }
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            for j in corners.indices where CADSnapEngine.segmentIntersection(a, b, corners[j], corners[(j + 1) % 4]) != nil { return true }
        }
        return false
    }

    /// Every wall reachable from `wallID` through shared endpoints or T-junctions, across rooms.
    public static func connectedWalls(from wallID: UUID, in project: PlanOpsisProject, tolerance: Double = GeometryTolerances.coincidenceMM) -> Set<UUID> {
        let walls = project.rooms.flatMap(\.walls)
        guard walls.contains(where: { $0.id == wallID }) else { return [] }
        func touches(_ a: PlanOpsisWall, _ b: PlanOpsisWall) -> Bool {
            for p in [a.start, a.end] where distance(p, toSegment: b.start, b.end) <= tolerance { return true }
            for p in [b.start, b.end] where distance(p, toSegment: a.start, a.end) <= tolerance { return true }
            return false
        }
        var found: Set<UUID> = [wallID]
        var queue = [wallID]
        while let id = queue.popLast() {
            guard let wall = walls.first(where: { $0.id == id }) else { continue }
            for other in walls where !found.contains(other.id) && touches(wall, other) {
                found.insert(other.id)
                queue.append(other.id)
            }
        }
        return found
    }

    /// Objects of the same kind as `id`: all walls, all doors / windows / openings, or all components of
    /// the same kind. Limited to `roomID` when given.
    public static func similar(to id: UUID, in project: PlanOpsisProject, roomID: UUID? = nil) -> Set<UUID> {
        let rooms = project.rooms.filter { roomID == nil || $0.id == roomID }
        let allRooms = project.rooms
        if allRooms.contains(where: { $0.walls.contains { $0.id == id } }) {
            return Set(rooms.flatMap(\.walls).map(\.id))
        }
        if let opening = allRooms.flatMap(\.openings).first(where: { $0.id == id }) {
            return Set(rooms.flatMap(\.openings).filter { $0.kind == opening.kind }.map(\.id))
        }
        if let component = allRooms.flatMap(\.components).first(where: { $0.id == id }) {
            return Set(rooms.flatMap(\.components).filter { $0.kind == component.kind }.map(\.id))
        }
        return []
    }

    static func distance(_ p: Point2D, toSegment a: Point2D, _ b: Point2D) -> Double {
        (CADSnapEngine.nearestPoint(on: .segment(a, b), to: p) - p).length
    }
}

// MARK: - Wall push/pull

public enum PlanDirectEditError: Error, Equatable, LocalizedError {
    case notFound
    case degenerateWall(UUID)
    case openingWouldNotFit(UUID)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "The edited object no longer exists."
        case .degenerateWall: return "The move would collapse a connected wall."
        case .openingWouldNotFit: return "A door, window or opening would no longer fit on its wall."
        }
    }
}

public struct WallPushPullResult: Sendable {
    public var project: PlanOpsisProject
    /// Walls whose geometry changed, including the pushed wall.
    public var changedWallIDs: Set<UUID>
}

/// v12.3 push/pull: moves a wall parallel to itself while connected walls stretch along their own
/// direction, as architectural CAD tools do. A rectangle stays a rectangle; a wall meeting the moved
/// wall at a T keeps meeting it.
public struct WallPushPullEngine: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = GeometryTolerances.coincidenceMM) {
        self.tolerance = tolerance
    }

    /// - Parameter offset: distance along the wall's normal (positive = to the wall's left).
    public func pushPull(wallID: UUID, offset: Double, in project: PlanOpsisProject) throws -> WallPushPullResult {
        guard let roomIndex = project.rooms.firstIndex(where: { $0.walls.contains { $0.id == wallID } }),
              let wall = project.rooms[roomIndex].walls.first(where: { $0.id == wallID }) else { throw PlanDirectEditError.notFound }
        guard abs(offset) > 1e-9 else { return WallPushPullResult(project: project, changedWallIDs: []) }
        let room = project.rooms[roomIndex]
        let shift = wall.normal * offset
        let newLineStart = wall.start + shift
        let direction = wall.direction
        var edited = Dictionary(uniqueKeysWithValues: room.walls.map { ($0.id, $0) })

        // Ends of the pushed wall: follow the first non-parallel wall that shares or hosts the end.
        func newEnd(for point: Point2D) -> Point2D {
            for other in room.walls where other.id != wallID {
                let touchesEnd = (other.start - point).length <= tolerance || (other.end - point).length <= tolerance
                let hostsEnd = PlanSelectionQuery.distance(point, toSegment: other.start, other.end) <= tolerance
                guard touchesEnd || hostsEnd else { continue }
                if let p = Self.intersectLines(other.start, other.direction, newLineStart, direction) { return p }
            }
            return point + shift
        }
        let start = newEnd(for: wall.start)
        let end = newEnd(for: wall.end)
        var pushed = wall
        pushed.start = start
        pushed.editEnd(end)
        guard pushed.length > 1, (end - start).dot(direction) > 0 else { throw PlanDirectEditError.degenerateWall(wallID) }
        edited[wallID] = pushed

        // Connected walls: an endpoint at either end of the pushed wall, or on its span (a T stem),
        // slides along its own wall to the new line.
        for other in room.walls where other.id != wallID {
            var updated = other
            for endpoint in [WallEndpointKind.start, .end] {
                let point = endpoint == .start ? other.start : other.end
                let target: Point2D?
                if (point - wall.start).length <= tolerance {
                    target = start
                } else if (point - wall.end).length <= tolerance {
                    target = end
                } else if PlanSelectionQuery.distance(point, toSegment: wall.start, wall.end) <= tolerance {
                    target = Self.intersectLines(other.start, other.direction, newLineStart, direction) ?? point + shift
                } else {
                    target = nil
                }
                guard let target else { continue }
                if endpoint == .start { updated.editStartKeepingEnd(target) } else { updated.editEnd(target) }
            }
            guard updated != other else { continue }
            guard updated.length > 1 else { throw PlanDirectEditError.degenerateWall(other.id) }
            edited[other.id] = updated
        }

        let previous = Dictionary(uniqueKeysWithValues: room.walls.map { ($0.id, $0) })
        var next = project
        next.rooms[roomIndex].walls = room.walls.map { edited[$0.id] ?? $0 }
        do {
            next.rooms[roomIndex].openings = try PlanEditingConstraintEngine.reanchorHostedOpenings(room.openings, previousWalls: previous, editedWalls: edited)
        } catch let WallEndpointEditError.openingWouldNotFit(openingID, _) {
            throw PlanDirectEditError.openingWouldNotFit(openingID)
        }
        let changed = Set(room.walls.filter { edited[$0.id] != $0 }.map(\.id))
        return WallPushPullResult(project: next, changedWallIDs: changed)
    }

    /// Intersection of the lines `p + t·u` and `q + s·v`, or nil when they are within 1° of parallel.
    static func intersectLines(_ p: Point2D, _ u: Point2D, _ q: Point2D, _ v: Point2D) -> Point2D? {
        let denominator = u.x * v.y - u.y * v.x
        guard abs(denominator) > sin(.pi / 180) else { return nil }
        let w = q - p
        let t = (w.x * v.y - w.y * v.x) / denominator
        return p + u * t
    }
}

// MARK: - Openings

public enum PlanOpeningEditing {
    /// Moves an opening along its host wall so its centre is as close as possible to `point`.
    /// The opening stays inside the wall; with `step`, the clear distance from the nearer wall end to
    /// the opening edge is rounded to the step, and the centre snaps to the wall midpoint when close.
    public static func slide(openingID: UUID, toward point: Point2D, in project: PlanOpsisProject, step: Double? = nil) -> PlanOpsisProject? {
        guard let roomIndex = project.rooms.firstIndex(where: { $0.openings.contains { $0.id == openingID } }),
              let openingIndex = project.rooms[roomIndex].openings.firstIndex(where: { $0.id == openingID }) else { return nil }
        var opening = project.rooms[roomIndex].openings[openingIndex]
        var parameters = opening.parameters
        guard let wall = project.rooms[roomIndex].walls.first(where: { $0.id == parameters.hostWallID }) else { return nil }
        let half = parameters.width / 2
        guard wall.length >= parameters.width else { return nil }
        var offset = (point - wall.start).dot(wall.direction)
        if let step, step > 0 {
            let midpoint = wall.length / 2
            if abs(offset - midpoint) <= step {
                offset = midpoint
            } else if offset < midpoint {
                offset = ((offset - half) / step).rounded() * step + half
            } else {
                offset = wall.length - (((wall.length - offset - half) / step).rounded() * step + half)
            }
        }
        offset = min(wall.length - half, max(half, offset))
        guard abs(offset - parameters.offsetAlongWall) > 1e-9 else { return project }
        parameters.offsetAlongWall = offset
        opening.parameters = parameters
        var next = project
        next.rooms[roomIndex].openings[openingIndex] = opening
        return next
    }

    /// Clear distances from the opening edges to the wall start and end (for the live readout).
    public static func clearances(openingID: UUID, in project: PlanOpsisProject) -> (fromStart: Double, toEnd: Double)? {
        for room in project.rooms {
            guard let opening = room.openings.first(where: { $0.id == openingID }),
                  let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { continue }
            let p = opening.parameters
            return (p.offsetAlongWall - p.width / 2, wall.length - p.offsetAlongWall - p.width / 2)
        }
        return nil
    }
}

// MARK: - Driving dimensions

/// What a plan dimension measures, recovered from its annotation primitive.
public enum PlanDimensionTarget: Hashable, Sendable {
    case wallLength(UUID)
    case openingWidth(UUID)

    /// Annotation primitive IDs are `dim-<part>:<wall UUID>` or `dim-<part>:opening:<opening UUID>`.
    public init?(annotationID: String) {
        guard annotationID.hasPrefix("dim-"), let colon = annotationID.firstIndex(of: ":") else { return nil }
        let rest = annotationID[annotationID.index(after: colon)...]
        if rest.hasPrefix("opening:"), let id = UUID(uuidString: String(rest.dropFirst("opening:".count))) {
            self = .openingWidth(id)
        } else if let id = UUID(uuidString: String(rest)) {
            self = .wallLength(id)
        } else {
            return nil
        }
    }

    /// The dimension's text and measured length in the annotation set.
    public static func dimensions(in annotations: [DXFPrimitive]) -> [(target: PlanDimensionTarget, text: DXFPrimitive, measured: Double)] {
        var lines: [String: Double] = [:]
        for primitive in annotations where primitive.id.hasPrefix("dim-line:") && primitive.points.count == 2 {
            lines[String(primitive.id.dropFirst("dim-line:".count))] = (primitive.points[1] - primitive.points[0]).length
        }
        return annotations.compactMap { primitive in
            guard primitive.kind == .text, primitive.id.hasPrefix("dim-text:"), let target = PlanDimensionTarget(annotationID: primitive.id) else { return nil }
            let key = String(primitive.id.dropFirst("dim-text:".count))
            guard let measured = lines[key] else { return nil }
            return (target, primitive, measured)
        }
    }
}

/// A plan dimension the user can edit by value.
public struct PlanDimensionEdit: Hashable, Sendable, Identifiable {
    public var target: PlanDimensionTarget
    /// The length the dimension currently shows.
    public var measured: Double
    /// Where its text is drawn, for hit testing.
    public var labelPosition: Point2D
    public var rotationDegrees: Double

    public init(target: PlanDimensionTarget, measured: Double, labelPosition: Point2D, rotationDegrees: Double) {
        self.target = target
        self.measured = measured
        self.labelPosition = labelPosition
        self.rotationDegrees = rotationDegrees
    }

    public var id: String {
        switch target {
        case let .wallLength(id): return "wall:\(id.uuidString)"
        case let .openingWidth(id): return "opening:\(id.uuidString)"
        }
    }

    public var title: String {
        switch target {
        case .wallLength: return "Wall length"
        case .openingWidth: return "Opening width"
        }
    }
}

public enum PlanLengthAnchor: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// The wall start stays; the end moves.
    case start
    /// The wall end stays; the start moves.
    case end
    /// Both ends move by half the change.
    case center

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .start: return "Keep start"
        case .end: return "Keep end"
        case .center: return "Keep centre"
        }
    }
}

extension PlanEditingConstraintEngine {
    /// Changes a wall's length by `delta` along its axis, moving connected junctions with it.
    public func changeWallLength(wallID: UUID, by delta: Double, anchor: PlanLengthAnchor, in project: PlanOpsisProject) throws -> PlanOpsisProject {
        guard let room = project.rooms.first(where: { $0.walls.contains { $0.id == wallID } }),
              let wall = room.walls.first(where: { $0.id == wallID }) else { throw WallEndpointEditError.wallNotFound(wallID) }
        guard wall.length + delta > 1 else { throw WallEndpointEditError.degenerateWall(wallID) }
        let settings = PlanEditingSettings()
        var next = project
        let d = wall.direction
        switch anchor {
        case .start:
            next = try moveEndpoint(wallID: wallID, endpoint: .end, proposed: wall.end + d * delta, in: next, roomID: room.id, settings: settings, applyConstraints: false).project
        case .end:
            next = try moveEndpoint(wallID: wallID, endpoint: .start, proposed: wall.start - d * delta, in: next, roomID: room.id, settings: settings, applyConstraints: false).project
        case .center:
            next = try moveEndpoint(wallID: wallID, endpoint: .end, proposed: wall.end + d * (delta / 2), in: next, roomID: room.id, settings: settings, applyConstraints: false).project
            next = try moveEndpoint(wallID: wallID, endpoint: .start, proposed: wall.start - d * (delta / 2), in: next, roomID: room.id, settings: settings, applyConstraints: false).project
        }
        return next
    }

    /// Snaps the direction from `anchor` to the nearest multiple of `incrementDegrees` when within
    /// `toleranceDegrees` of it (polar tracking). Distance from the anchor is kept.
    public func polarPoint(_ point: Point2D, anchor: Point2D, incrementDegrees: Double, toleranceDegrees: Double = 4) -> Point2D? {
        let v = point - anchor
        let length = v.length
        guard incrementDegrees > 0, length > 1e-9 else { return nil }
        let angle = atan2(v.y, v.x) * 180 / .pi
        let snapped = (angle / incrementDegrees).rounded() * incrementDegrees
        guard abs(angle - snapped) <= toleranceDegrees else { return nil }
        let radians = snapped * .pi / 180
        return anchor + Point2D(x: cos(radians), y: sin(radians)) * length
    }
}

// MARK: - Precision input

/// v12.3 typed coordinates for drawing walls, in millimetres:
/// - `3450` — that distance along the current pointer direction;
/// - `3450<90` or `@3450<90` — distance and angle (degrees, counter-clockwise from +X);
/// - `@1200,-300` or `1200,-300` — relative ΔX, ΔY;
/// - `#5000,2000` — absolute X, Y.
public enum PlanPrecisionInput {
    public static func point(from text: String, anchor: Point2D, direction: Point2D?) -> Point2D? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") {
            s.removeFirst()
            guard let (x, y) = pair(s, separator: ",") else { return nil }
            return Point2D(x: x, y: y)
        }
        if s.hasPrefix("@") { s.removeFirst() }
        if s.contains("<") {
            guard let (length, degrees) = pair(s, separator: "<"), length >= 0 else { return nil }
            let radians = degrees * .pi / 180
            return anchor + Point2D(x: cos(radians), y: sin(radians)) * length
        }
        if s.contains(",") {
            guard let (dx, dy) = pair(s, separator: ",") else { return nil }
            return anchor + Point2D(x: dx, y: dy)
        }
        guard let length = Double(s), let direction, direction.length > 1e-9 else { return nil }
        return anchor + direction.normalized * length
    }

    private static func pair(_ s: String, separator: Character) -> (Double, Double)? {
        let parts = s.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a.isFinite, b.isFinite else { return nil }
        return (a, b)
    }
}

// MARK: - Editor object snaps

/// v12.3 object snaps for the plan editor: wall axes (endpoints, midpoints, intersections,
/// perpendicular), component centres, and an optional underlay drawing.
public struct PlanObjectSnapper: Sendable {
    public let scene: CADScene

    /// - Parameter excludedWallIDs: walls being edited, which must not snap to themselves.
    public init(project: PlanOpsisProject, excludingWallIDs excludedWallIDs: Set<UUID> = []) {
        var entities: [CADEntity] = []
        for room in project.rooms {
            for wall in room.walls where !excludedWallIDs.contains(wall.id) && wall.length > 1e-6 {
                entities.append(CADEntity(type: "WALL", layer: "AXIS", geometry: .line(wall.start, wall.end), xdata: ["PLANOPSIS": [wall.id.uuidString]]))
            }
            for component in room.components {
                entities.append(CADEntity(type: "COMPONENT", layer: "AXIS", geometry: .point(component.position), xdata: ["PLANOPSIS": [component.id.uuidString]]))
            }
        }
        scene = CADScene(document: CADDocument(units: .millimetres, layers: [CADLayer(name: "AXIS")], entities: entities))
    }

    /// The snapped point near `point` (within `radius` mm), checking the plan first and then the underlay.
    public func snap(
        _ point: Point2D,
        radius: Double,
        from origin: Point2D? = nil,
        kinds: Set<CADSnapKind> = CADSnapKind.standard,
        underlay: CADScene? = nil,
        underlayHiddenLayers: Set<String> = []
    ) -> CADSnap? {
        let engine = CADSnapEngine(kinds: kinds)
        if let snap = engine.snap(at: point, radius: radius, in: scene, from: origin) { return snap }
        guard let underlay else { return nil }
        return engine.snap(at: point, radius: radius, in: underlay, hiddenLayers: underlayHiddenLayers, from: origin)
    }
}
