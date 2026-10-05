import Foundation

/// Serializer- and screen-independent plan geometry, in world millimetres.
public struct ArchitecturalSymbol: Hashable, Sendable {
    public enum Geometry: Hashable, Sendable {
        case line(Point2D, Point2D)
        case polyline([Point2D], closed: Bool)
        /// Counterclockwise, including wrapped sweeps. Angles are radians.
        case arc(center: Point2D, radius: Double, start: Double, end: Double)

        public var boundsPoints: [Point2D] {
            switch self {
            case .line(let a, let b): return [a, b]
            case .polyline(let points, _): return points
            case .arc(let center, let radius, let start, let end):
                let sweep = Self.positiveAngle(end - start)
                let angles = [start, end] + [0.0, .pi / 2, .pi, .pi * 1.5].filter {
                    Self.positiveAngle($0 - start) <= sweep + 1e-10
                }
                return angles.map { center + Point2D(x: cos($0), y: sin($0)) * radius }
            }
        }

        public static func positiveAngle(_ value: Double) -> Double {
            let angle = value.truncatingRemainder(dividingBy: 2 * .pi)
            return angle < 0 ? angle + 2 * .pi : angle
        }
    }

    public enum Role: Hashable, Sendable { case outline, detail, swing }
    public struct Primitive: Hashable, Sendable, Identifiable {
        public var id: String
        public var geometry: Geometry
        public var role: Role
        public init(id: String, geometry: Geometry, role: Role = .outline) {
            self.id = id; self.geometry = geometry; self.role = role
        }
    }
    public var primitives: [Primitive]
    public init(primitives: [Primitive]) { self.primitives = primitives }
    public var bounds: FloorGeometry? { FloorGeometry.enclosing(primitives.flatMap { $0.geometry.boundsPoints }) }
}

public extension FloorGeometry {
    static func enclosing(_ points: [Point2D]) -> FloorGeometry? {
        guard let first = points.first, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return FloorGeometry(
            min: Point2D(x: points.reduce(first.x) { Swift.min($0, $1.x) }, y: points.reduce(first.y) { Swift.min($0, $1.y) }),
            max: Point2D(x: points.reduce(first.x) { Swift.max($0, $1.x) }, y: points.reduce(first.y) { Swift.max($0, $1.y) })
        )
    }
    func contains(_ point: Point2D, tolerance: Double = 0) -> Bool {
        point.x >= min.x - tolerance && point.x <= max.x + tolerance && point.y >= min.y - tolerance && point.y <= max.y + tolerance
    }
}

/// One standard level of detail. Dimensions, rotation and translation always come from semantics.
public enum ArchitecturalSymbolLibrary {
    private struct Transform {
        var origin: Point2D
        var angle: Double
        func point(_ x: Double, _ y: Double) -> Point2D {
            origin + Point2D(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
        }
    }

    public static func component(_ component: PlanOpsisComponent) -> ArchitecturalSymbol {
        guard [component.width, component.depth, component.rotationRadians, component.position.x, component.position.y].allSatisfy(\.isFinite),
              component.width > 0, component.depth > 0 else { return ArchitecturalSymbol(primitives: []) }
        let t = Transform(origin: component.position, angle: component.rotationRadians)
        let w = component.width, d = component.depth
        func p(_ x: Double, _ y: Double) -> Point2D { t.point(x * w, y * d) }
        var items: [ArchitecturalSymbol.Primitive] = []
        func line(_ name: String, _ a: Point2D, _ b: Point2D, _ role: ArchitecturalSymbol.Role = .detail) {
            items.append(.init(id: "component:\(component.id):\(name)", geometry: .line(a, b), role: role))
        }
        func poly(_ name: String, _ points: [Point2D], _ role: ArchitecturalSymbol.Role = .outline) {
            items.append(.init(id: "component:\(component.id):\(name)", geometry: .polyline(points, closed: true), role: role))
        }
        func rect(_ name: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ role: ArchitecturalSymbol.Role = .outline) {
            poly(name, [p(x0,y0),p(x1,y0),p(x1,y1),p(x0,y1)], role)
        }
        func ellipse(_ name: String, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double) {
            poly(name, (0..<32).map { i in
                let a = Double(i) * 2 * .pi / 32
                return p(x + cos(a) * rx, y + sin(a) * ry)
            }, .detail)
        }
        switch component.kind {
        case .column:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("axis-x", p(-0.5, 0), p(0.5, 0), .detail)
            line("axis-y", p(0, -0.5), p(0, 0.5), .detail)
        case .beam:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("axis", p(-0.5, 0), p(0.5, 0), .detail)
        case .table:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
        case .chair:
            // A chamfered seat, two back rails and four restrained leg markers.
            // No enclosing rectangle that makes the chair read as a box.
            poly("seat", [p(-0.44,-0.5),p(0.44,-0.5),p(0.5,-0.44),p(0.5,0.26),p(-0.5,0.26),p(-0.5,-0.44)])
            line("back:0", p(-0.5,0.38), p(0.5,0.38), .outline)
            line("back:1", p(-0.5,0.5), p(0.5,0.5), .outline)
            line("back-end-a", p(-0.5,0.38), p(-0.5,0.5), .outline)
            line("back-end-b", p(0.5,0.38), p(0.5,0.5), .outline)
            for (i, xy) in [(-0.38,-0.37),(0.38,-0.37),(-0.38,0.14),(0.38,0.14)].enumerated() {
                let (x,y) = xy
                rect("leg:\(i)", x-0.025,y-0.025,x+0.025,y+0.025,.detail)
            }
        case .bed:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            let halves = w >= 1200 ? [(-0.43,-0.035),(0.035,0.43)] : [(-0.4,0.4)]
            for (i, range) in halves.enumerated() { rect("pillow:\(i)", range.0,0.25,range.1,0.44,.detail) }
            line("blanket", p(-0.5,0.13),p(0.5,0.13))
        case .sofa:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("back", p(-0.5,0.28),p(0.5,0.28))
            line("arm-left", p(-0.4,-0.5),p(-0.4,0.28))
            line("arm-right", p(0.4,-0.5),p(0.4,0.28))
            line("seat", p(-0.4,-0.38),p(0.4,-0.38))
            line("seat-division", p(0,-0.38),p(0,0.28))
        case .wc:
            rect("cistern", -0.5,0.28,0.5,0.5)
            // D-shaped bowl, connected to the cistern, with no false rectangular footprint.
            let nose = (0...16).map { i -> Point2D in
                let a = Double.pi + Double(i) * .pi / 16
                return p(cos(a) * 0.43, -0.13 + sin(a) * 0.37)
            }
            poly("bowl", [p(-0.43,0.28)] + nose + [p(0.43,0.28)])
            ellipse("inner-bowl", 0,-0.08,0.29,0.30)
        case .sink:
            poly("outline", [p(-0.5,0.5),p(0.5,0.5),p(0.5,-0.32),p(0.36,-0.5),p(-0.36,-0.5),p(-0.5,-0.32)])
            ellipse("bowl",0,-0.04,0.38,0.32)
            // A short cross remains legible without sub-millimetre circles.
            line("drain-x",p(-0.035,-0.04),p(0.035,-0.04))
            line("drain-y",p(0,-0.075),p(0,-0.005))
        // v12.8 symbols for every object RoomPlan recognises. Local -y is the front (the room side),
        // +y the back (against the wall), as for the bed, sofa and WC above.
        case .storage:
            // A cupboard: its outline, the door line along the front and one diagonal.
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("doors", p(-0.5, -0.4), p(0.5, -0.4))
            line("diagonal", p(-0.5, -0.4), p(0.5, 0.5))
        case .fireplace:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            poly("hearth", [p(-0.32, -0.5), p(-0.2, 0.2), p(0.2, 0.2), p(0.32, -0.5)], .detail)
        case .bathtub:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            // The basin: a rounded rectangle inside the rim, the drain at the tap end.
            let rimX = min(0.45, 0.5 - 60 / w), rimY = min(0.42, 0.5 - 60 / d)
            let r = min(0.12, rimX * 0.3)
            var basin: [Point2D] = []
            for (cx, cy, start) in [(rimX - r, -rimY + r * w / d, -Double.pi / 2), (rimX - r, rimY - r * w / d, 0),
                                    (-rimX + r, rimY - r * w / d, Double.pi / 2), (-rimX + r, -rimY + r * w / d, Double.pi)] {
                for i in 0...4 {
                    let a = start + Double(i) * Double.pi / 8
                    basin.append(p(cx + cos(a) * r, cy + sin(a) * r * w / d))
                }
            }
            poly("basin", basin, .detail)
            ellipse("drain", rimX - 0.1, 0, 0.025, 0.025 * w / d)
        case .refrigerator:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("door", p(-0.5, -0.38), p(0.5, -0.38))
            line("cross-a", p(-0.5, -0.38), p(0.5, 0.5))
            line("cross-b", p(0.5, -0.38), p(-0.5, 0.5))
        case .stove:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            for (i, xy) in [(-0.24, -0.22), (0.24, -0.22), (-0.24, 0.24), (0.24, 0.24)].enumerated() {
                ellipse("burner:\(i)", xy.0, xy.1, 0.16, 0.16 * w / d)
            }
        case .oven:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            rect("door", -0.42, -0.5, 0.42, -0.36, .detail)
            line("handle", p(-0.3, -0.43), p(0.3, -0.43))
        case .dishwasher:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            line("door", p(-0.5, -0.4), p(0.5, -0.4))
            line("rack-a", p(-0.38, -0.3), p(0.38, 0.42))
            line("rack-b", p(0.38, -0.3), p(-0.38, 0.42))
        case .washerDryer:
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            ellipse("drum", 0, 0.03, 0.34, 0.34 * w / d)
            line("door", p(-0.5, -0.42), p(0.5, -0.42))
        case .television:
            // A thin screen and its stand line behind it.
            rect("screen", -0.5, -0.5, 0.5, 0.0)
            line("stand", p(-0.15, 0.0), p(0.15, 0.0))
            line("back", p(-0.15, 0.5), p(0.15, 0.5))
        case .stairs:
            // Treads across the run (along +y) every 280 mm or so, and the walking line with its arrow.
            rect("outline", -0.5, -0.5, 0.5, 0.5)
            let treads = max(2, Int((d / 280).rounded()))
            for i in 1..<treads {
                let y = -0.5 + Double(i) / Double(treads)
                line("tread:\(i)", p(-0.5, y), p(0.5, y), .outline)
            }
            line("walk", p(0, -0.45), p(0, 0.45))
            let head = min(0.2, 250 / d)
            line("arrow-a", p(0, 0.45), p(-min(0.15, 120 / w), 0.45 - head))
            line("arrow-b", p(0, 0.45), p(min(0.15, 120 / w), 0.45 - head))
        }
        return ArchitecturalSymbol(primitives: items)
    }

    /// Shared entry point for the plan canvas and physical/semantic DXF fallback.
    public static func opening(_ opening: DisplayOpeningGeometry, roomFloors: [RoomFloorGeometry] = []) -> ArchitecturalSymbol {
        let boundary = roomFloors.first { opening.sourceRoomIDs.contains($0.roomID) && $0.polygon.count >= 3 }?.polygon ?? []
        return self.opening(id: opening.id, kind: opening.kind, center: opening.center, width: opening.width,
                            thickness: opening.thickness, angle: opening.angleRadians, swing: opening.doorSwing,
                            doorOperation: opening.doorOperation ?? .singleHinged, windowOperation: opening.windowOperation ?? .fixed,
                            inwardSign: inwardSign(center: opening.center, angle: opening.angleRadians, boundary: boundary))
    }

    public static func inwardSign(center: Point2D, angle: Double, boundary: [Point2D]) -> Double {
        guard boundary.count >= 3 else { return 1 }
        let normal = Point2D(x: -sin(angle), y: cos(angle))
        func inside(_ p: Point2D) -> Bool {
            var result = false
            var j = boundary.count - 1
            for i in boundary.indices {
                let a = boundary[i], b = boundary[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x) * (p.y-a.y) / (b.y-a.y) + a.x { result.toggle() }
                j = i
            }
            return result
        }
        return inside(center + normal * 1) ? 1 : (inside(center - normal * 1) ? -1 : 1)
    }

    public static func opening(id: String, kind: DisplayOpeningKind, center: Point2D, width: Double, thickness: Double,
                               angle: Double, swing: PlanOpsisDoor.Swing = .unspecified,
                               doorOperation: PlanOpsisDoor.Operation = .singleHinged,
                               windowOperation: PlanOpsisWindow.Operation = .fixed, inwardSign: Double = 1) -> ArchitecturalSymbol {
        guard [center.x, center.y, width, thickness, angle, inwardSign].allSatisfy(\.isFinite), width > 0, thickness > 0 else { return .init(primitives: []) }
        let t = Transform(origin: center, angle: angle)
        let h = width / 2, half = thickness / 2
        func p(_ x: Double, _ y: Double) -> Point2D { t.point(x, y) }
        var items: [ArchitecturalSymbol.Primitive] = []
        func line(_ name: String, _ a: Point2D, _ b: Point2D, _ role: ArchitecturalSymbol.Role = .outline) {
            items.append(.init(id: "\(name):\(id)", geometry: .line(a,b), role: role))
        }
        line("jamb-a",p(-h,-half),p(-h,half))
        line("jamb-b",p(h,-half),p(h,half))
        switch kind {
        case .opening, .mixedPassage: break
        case .window:
            let frame = thickness * 0.18
            line("window-rail-plus",p(-h,frame),p(h,frame))
            line("window-rail-minus",p(-h,-frame),p(h,-frame))
            switch windowOperation {
            case .fixed: break
            case .singleCasement:
                // A leaf shown open 30 degrees, outside the frame, instead of a crossing diagonal.
                line("window-leaf",p(-h,inwardSign*frame),p(-h+width*cos(.pi/6),inwardSign*(frame+width*0.5)),.detail)
            case .doubleCasement:
                line("window-mullion",p(0,-frame),p(0,frame))
                for side in [-1.0,1.0] {
                    line("window-leaf-\(side < 0 ? "left" : "right")",p(side*h,inwardSign*frame),p(side*(h-h*cos(.pi/6)),inwardSign*(frame+h*0.5)),.detail)
                }
            case .sliding:
                line("window-slide-a",p(-h,frame*0.5),p(width*0.1,frame*0.5),.detail)
                line("window-slide-b",p(-width*0.1,-frame*0.5),p(h,-frame*0.5),.detail)
            }
        case .door:
            let side: Double = (swing == .rightIn || swing == .rightOut) ? 1 : -1
            let normal: Double = (swing == .leftOut || swing == .rightOut) ? -inwardSign : inwardSign
            switch doorOperation {
            case .sliding:
                let offset = thickness * 0.16
                line("door-slide-a",p(-h,offset),p(width*0.12,offset))
                line("door-slide-b",p(-width*0.12,-offset),p(h,-offset))
            case .pocket:
                let offset = thickness * 0.12
                line("door-pocket-leaf",p(-h,offset),p(h,offset))
                // Two short end ticks make the pocket's side unambiguous. Full semantic leaf width.
                line("door-pocket",p(side*h,offset),p(side*(h+width),offset),.detail)
                line("door-pocket-end",p(side*(h+width),-offset),p(side*(h+width),offset),.detail)
            case .singleHinged, .doubleHinged:
                guard swing != .unspecified else { break } // never invent captured handedness
                let sides = doorOperation == .doubleHinged ? [-1.0,1.0] : [side]
                let leaf = doorOperation == .doubleHinged ? width/2 : width
                for (i,s) in sides.enumerated() {
                    let hinge = p(s*h,normal*half)
                    let end = p(s*h,normal*(half+leaf))
                    let prefix = doorOperation == .doubleHinged ? "door-double" : "door"
                    let suffix = doorOperation == .doubleHinged ? ":\(i)" : ""
                    line("\(prefix)-leaf\(suffix)",hinge,end)
                    let closedAngle = angle + (s < 0 ? 0 : .pi)
                    let openAngle = angle + (normal > 0 ? .pi/2 : -.pi/2)
                    let ccw = -s * normal > 0
                    items.append(.init(id: "\(prefix)-swing\(suffix):\(id)", geometry: .arc(center: hinge,radius: leaf,
                        start: ArchitecturalSymbol.Geometry.positiveAngle(ccw ? closedAngle : openAngle),
                        end: ArchitecturalSymbol.Geometry.positiveAngle(ccw ? openAngle : closedAngle)),role: .swing))
                }
            }
        }
        return .init(primitives: items)
    }
}
