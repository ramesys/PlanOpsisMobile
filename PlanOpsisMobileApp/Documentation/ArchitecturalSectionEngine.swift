import Foundation

/// v12.4 sections and interior elevations from the physical wall solids.
///
/// A section is an orthographic view along a cut line: wall pieces the line crosses are drawn cut
/// (filled), wall pieces beyond it are drawn as outlines from far to near so nearer walls hide farther
/// ones. Openings need no special case: the solids already stop at door heads, sills and window
/// heads, so the gaps between pieces are the openings. View coordinates: x along the cut line in
/// millimetres, y = height above the room floor.
public struct ArchitecturalSectionEngine: Sendable {
    /// Paper line weights (mm).
    public static let cutWeight = 0.5
    public static let beyondWeight = 0.18
    public static let groundWeight = 0.7
    /// Paper text height (mm).
    public static let textHeight = 2.5

    public init() {}

    // MARK: Sections

    public func section(_ line: SectionLine, project: PlanOpsisProject, physical: DisplayGeometrySnapshot, scale: Int) -> DrawingView {
        var view = DrawingView(id: "section:\(line.id.uuidString)", title: "Section \(line.label)–\(line.label)", scale: scale, primitives: [])
        view.primitives = cutAndBeyond(
            origin: line.start, axis: line.direction, viewDirection: line.viewDirection,
            xRange: 0...(line.end - line.start).length, depth: nil,
            solids: physical.wallSolids, scale: scale
        )
        guard let extent = CADRect(points: view.primitives.flatMap(\.points)) else { return view }
        let s = Double(scale)
        // Clear widths between cut walls, the overall cut length, and the height.
        let cutEdges = view.primitives.filter { $0.fill == 0.25 }.flatMap(\.points).map { ($0.x * 10).rounded() / 10 }
        let stations = Array(Set(cutEdges)).sorted()
        if stations.count >= 2 {
            if stations.count > 2 {
                view.primitives += DimensionDrawing.chain(stations.map { Point2D(x: $0, y: 0) }, offset: Point2D(x: 0, y: -8 * s), scale: scale)
            }
            view.primitives += DimensionDrawing.chain([Point2D(x: stations.first!, y: 0), Point2D(x: stations.last!, y: 0)], offset: Point2D(x: 0, y: -15 * s), scale: scale)
        }
        view.primitives += DimensionDrawing.chain([Point2D(x: extent.minX, y: 0), Point2D(x: extent.minX, y: extent.maxY)], offset: Point2D(x: -10 * s, y: 0), scale: scale)
        view.primitives += groundAndLevels(minX: extent.minX, maxX: extent.maxX, top: extent.maxY, scale: scale)
        return view
    }

    // MARK: Interior elevations

    /// One elevation per wall of the room, seen from inside the room, with opening and height dimensions.
    public func interiorElevations(room: PlanOpsisRoom, roomName: String, project: PlanOpsisProject, physical: DisplayGeometrySnapshot, schedules: ProjectSchedules?, scale: Int) -> [DrawingView] {
        let measurement = SurveyMeasurementEngine()
        var views: [DrawingView] = []
        // Elevations go clockwise around the room from the north-west, like wall numbering.
        let ordered = PlanOrdering(project: project).orderedWalls(of: room)
        for (index, wall) in ordered.enumerated() where wall.length > 1 {
            guard let side = measurement.roomSide(ofWall: wall.id, in: room),
                  let face = try? measurement.faceSegment(wallID: wall.id, side: side, in: room) else { continue }
            let inward = wall.normal * Double(side)
            let viewDirection = inward * -1
            // The viewer stands just inside the face; looking at the wall, "right" is the view direction
            // turned clockwise.
            let axis = Point2D(x: viewDirection.y, y: -viewDirection.x)
            let standoff = 40.0
            let corner = room.walls.map(\.thickness).max() ?? wall.thickness
            let a = face.0 + inward * standoff, b = face.1 + inward * standoff
            let (left, right) = (a - b).dot(axis) < 0 ? (a, b) : (b, a)
            let faceLength = (right - left).dot(axis)
            let roomSolids = physical.wallSolids.filter { $0.sourceRoomIDs.contains(room.id) || $0.sourceWallIDs.contains(wall.id) }
            var primitives = cutAndBeyond(
                origin: left, axis: axis, viewDirection: viewDirection,
                xRange: -corner...(faceLength + corner), depth: standoff + wall.thickness + 10,
                solids: roomSolids, scale: scale
            )
            let height = wall.height
            primitives += groundAndLevels(minX: -corner, maxX: faceLength + corner, top: height, scale: scale)
            primitives += elevationDimensions(wall: wall, left: left, axis: axis, faceLength: faceLength, height: height, room: room, schedules: schedules, scale: scale)
            let facing = Self.compass(viewDirection)
            views.append(DrawingView(
                id: "elevation:\(room.id.uuidString):\(wall.id.uuidString)",
                title: "\(roomName) · Elevation \(index + 1) (\(facing))",
                scale: scale,
                primitives: primitives
            ))
        }
        return views
    }

    /// N, NE, E… for a plan direction (plan +Y is north).
    public static func compass(_ direction: Point2D) -> String {
        let names = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
        var angle = atan2(direction.y, direction.x) * 180 / .pi
        if angle < 0 { angle += 360 }
        return names[Int((angle / 45).rounded()) % 8]
    }

    // MARK: Shared drawing

    private struct Projected {
        var minX: Double, maxX: Double, nearDepth: Double, bottom: Double, top: Double
    }

    /// Cut fills for solids the line crosses and outlines for solids beyond it, far to near.
    func cutAndBeyond(origin: Point2D, axis: Point2D, viewDirection: Point2D, xRange: ClosedRange<Double>, depth: Double?, solids: [DisplayWallSolidSegment], scale: Int) -> [SheetPrimitive] {
        var cuts: [SheetPrimitive] = []
        var beyond: [Projected] = []
        for solid in solids where solid.height > 1 {
            let footprint = Self.footprint(solid)
            let local = footprint.map { p -> (x: Double, d: Double) in let v = p - origin; return (v.dot(axis), v.dot(viewDirection)) }
            let depths = local.map(\.d)
            guard let nearest = depths.min(), let farthest = depths.max() else { continue }
            if let depth, nearest > depth { continue }
            if nearest < 0 && farthest > 0 {
                // The cut line crosses this piece: the cut is the footprint's extent along x at depth 0.
                var xs: [Double] = []
                for i in 0..<4 {
                    let p = local[i], q = local[(i + 1) % 4]
                    if (p.d < 0) != (q.d < 0) {
                        let t = p.d / (p.d - q.d)
                        xs.append(p.x + (q.x - p.x) * t)
                    }
                }
                guard let x0 = xs.min(), let x1 = xs.max() else { continue }
                let a = max(x0, xRange.lowerBound), b = min(x1, xRange.upperBound)
                guard b - a > 0.5 else { continue }
                let y0 = solid.bottom, y1 = solid.bottom + solid.height
                cuts.append(SheetPrimitive(.polygon([Point2D(x: a, y: y0), Point2D(x: b, y: y0), Point2D(x: b, y: y1), Point2D(x: a, y: y1)]), weight: Self.cutWeight, fill: 0.25))
            } else if nearest >= 0 {
                let xs = local.map(\.x)
                let a = max(xs.min()!, xRange.lowerBound), b = min(xs.max()!, xRange.upperBound)
                guard b - a > 0.5 else { continue }
                beyond.append(Projected(minX: a, maxX: b, nearDepth: nearest, bottom: solid.bottom, top: solid.bottom + solid.height))
            }
        }
        // Painter's order: white-filled outlines far to near, so nearer pieces hide farther ones.
        let outlines = beyond.sorted { $0.nearDepth > $1.nearDepth }.map { piece in
            SheetPrimitive(.polygon([Point2D(x: piece.minX, y: piece.bottom), Point2D(x: piece.maxX, y: piece.bottom), Point2D(x: piece.maxX, y: piece.top), Point2D(x: piece.minX, y: piece.top)]),
                           weight: Self.beyondWeight, fill: 1)
        }
        return outlines + cuts
    }

    static func footprint(_ solid: DisplayWallSolidSegment) -> [Point2D] {
        let d = Point2D(x: cos(solid.renderAngleRadians), y: sin(solid.renderAngleRadians))
        let n = Point2D(x: -d.y, y: d.x)
        let half = d * (solid.renderLength / 2), t = n * (solid.thickness / 2)
        let c = solid.renderCenter
        return [c - half - t, c + half - t, c + half + t, c - half + t]
    }

    /// Ground line and level marks (±0 at the floor, +height at the top).
    func groundAndLevels(minX: Double, maxX: Double, top: Double, scale: Int) -> [SheetPrimitive] {
        let s = Double(scale)
        let overhang = 6 * s
        var out = [SheetPrimitive(.line(Point2D(x: minX - overhang, y: 0), Point2D(x: maxX + overhang, y: 0)), weight: Self.groundWeight)]
        for (level, label) in [(0.0, "±0.00"), (top, String(format: "+%.2f", top / 1_000))] {
            let x = maxX + overhang + 2 * s
            // Level symbol: a small triangle on the level line and the value beside it.
            out.append(SheetPrimitive(.line(Point2D(x: maxX + overhang * 0.3, y: level), Point2D(x: x + 12 * s, y: level)), weight: Self.beyondWeight))
            out.append(SheetPrimitive(.polygon([Point2D(x: x, y: level), Point2D(x: x - 1.5 * s, y: level + 2.5 * s), Point2D(x: x + 1.5 * s, y: level + 2.5 * s)]), weight: 0.13, fill: 0))
            out.append(SheetPrimitive(.text(label, at: Point2D(x: x + 3 * s, y: level + 1 * s), height: Self.textHeight, rotation: 0, anchor: .left, bold: false)))
        }
        return out
    }

    /// Opening chain and overall length under the elevation; sill, head and wall height at the side.
    func elevationDimensions(wall: PlanOpsisWall, left: Point2D, axis: Point2D, faceLength: Double, height: Double, room: PlanOpsisRoom, schedules: ProjectSchedules?, scale: Int) -> [SheetPrimitive] {
        let s = Double(scale)
        var out: [SheetPrimitive] = []
        var stations: [Double] = [0, faceLength]
        var verticals: [Double] = [0, height]
        for opening in room.openings where opening.parameters.hostWallID == wall.id {
            let p = opening.parameters
            for offset in [p.offsetAlongWall - p.width / 2, p.offsetAlongWall + p.width / 2] {
                let x = (wall.start + wall.direction * offset - left).dot(axis)
                if x > 1, x < faceLength - 1 { stations.append(x) }
            }
            if p.sillHeight > 1 { verticals.append(p.sillHeight) }
            verticals.append(min(height, p.sillHeight + p.height))
            if let mark = schedules?.marks[opening.id] {
                let x = (wall.start + wall.direction * p.offsetAlongWall - left).dot(axis)
                out.append(SheetPrimitive(.text(mark, at: Point2D(x: x, y: p.sillHeight + p.height / 2), height: Self.textHeight, rotation: 0, anchor: .center, bold: true)))
            }
        }
        stations = Array(Set(stations.map { ($0 * 10).rounded() / 10 })).sorted()
        verticals = Array(Set(verticals.map { ($0 * 10).rounded() / 10 })).sorted()
        let chainY = -8 * s, overallY = -15 * s
        if stations.count > 2 {
            out += DimensionDrawing.chain(stations.map { Point2D(x: $0, y: 0) }, offset: Point2D(x: 0, y: chainY), scale: scale)
        }
        out += DimensionDrawing.chain([Point2D(x: 0, y: 0), Point2D(x: faceLength, y: 0)], offset: Point2D(x: 0, y: overallY), scale: scale)
        let sideX = -10 * s
        out += DimensionDrawing.chain(verticals.map { Point2D(x: 0, y: $0) }, offset: Point2D(x: sideX, y: 0), scale: scale)
        return out
    }
}

/// v12.4 architectural dimension strings in view coordinates (oblique ticks, text above the line).
public enum DimensionDrawing {
    /// A chain through `points` (all on one horizontal or vertical line), drawn at `offset` from them.
    public static func chain(_ points: [Point2D], offset: Point2D, scale: Int) -> [SheetPrimitive] {
        guard points.count >= 2 else { return [] }
        let s = Double(scale)
        let vertical = abs(points.last!.y - points.first!.y) > abs(points.last!.x - points.first!.x)
        let line = points.map { $0 + offset }
        var out: [SheetPrimitive] = [SheetPrimitive(.line(line.first!, line.last!), weight: 0.13)]
        let tick = 1.2 * s
        for (p, q) in zip(points, line) {
            // Extension line from 1 mm (paper) off the object to 1.5 mm past the dimension line.
            let direction = (q - p).length > 1e-9 ? (q - p).normalized : Point2D(x: 0, y: -1)
            out.append(SheetPrimitive(.line(p + direction * (1 * s), q + direction * (1.5 * s)), weight: 0.13))
            out.append(SheetPrimitive(.line(q + Point2D(x: -tick, y: -tick) * 0.7, q + Point2D(x: tick, y: tick) * 0.7), weight: 0.35))
        }
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let length = vertical ? abs(points[i + 1].y - points[i].y) : abs(points[i + 1].x - points[i].x)
            guard length > 0.5 else { continue }
            let mid = Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let text = String(Int(length.rounded()))
            if vertical {
                out.append(SheetPrimitive(.text(text, at: mid + Point2D(x: -1 * s, y: 0), height: 2.0, rotation: .pi / 2, anchor: .center, bold: false)))
            } else {
                out.append(SheetPrimitive(.text(text, at: mid + Point2D(x: 0, y: 1 * s), height: 2.0, rotation: 0, anchor: .center, bold: false)))
            }
        }
        return out
    }
}
