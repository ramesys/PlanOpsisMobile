import Foundation

/// One printed sheet: primitives in paper millimetres, origin at the bottom-left corner, Y up.
public struct DrawingSheet: Sendable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    public var paper: PaperSize
    public var primitives: [SheetPrimitive]

    public var width: Double { paper.size.width }
    public var height: Double { paper.size.height }
}

/// The complete drawing set for a project.
public struct DrawingSet: Sendable {
    public var sheets: [DrawingSheet]
    public var schedules: ProjectSchedules
    /// v12.5 quantity takeoff and finishes.
    public var quantities: ProjectQuantities
    /// Schedules followed by the quantity tables: what the Schedules view and the CSV show.
    public var tables: [ProjectSchedules.Table] { schedules.tables + quantities.tables }
    /// Scale used for the floor plan, the elevations and the sections.
    public var planScale: Int
    public var elevationScale: Int?
    public var sectionScale: Int?
    /// Problems that limited the set (e.g. a view too large for the paper at any standard scale).
    public var notes: [String]
}

/// v12.4 lays out the floor plan, schedules, interior elevations and sections on sheets with a title
/// block, north arrow, scale bar and section marks.
public struct DrawingSetComposer: Sendable {
    public static let margin = 10.0
    public static let titleBlockHeight = 38.0
    public static let viewTitleHeight = 9.0
    public static let gap = 12.0

    public init() {}

    public func compose(
        project: PlanOpsisProject,
        representation: GeometryRepresentationMode = .semanticObservations,
        semanticGeometry: ArchitecturalGeometrySnapshot? = nil,
        physicalGeometry: DisplayGeometrySnapshot? = nil,
        date: Date = Date()
    ) -> DrawingSet {
        let settings = project.documentationSettings
        let semantic = semanticGeometry ?? ParametricGeometryEngine().generate(from: project)
        let physical = physicalGeometry ?? PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)
        let schedules = ProjectSchedules(project: project, semanticGeometry: semantic, physicalGeometry: physical)
        let roomNames = ProjectSchedules.roomNames(project)
        let paper = settings.paper
        let area = Self.drawingArea(paper)
        var notes: [String] = []
        var pages: [(title: String, scale: String, primitives: [SheetPrimitive])] = []

        // Floor plan.
        let planPrimitives = DXFExchangeEngine(includeTags: true)
            .preview(for: project, representation: representation, semanticGeometry: semantic, physicalGeometry: physical).primitives
        let planBounds = CADRect(points: planPrimitives.filter { Self.plotted($0) }.flatMap(\.boundsPoints)) ?? .empty
        let planScale = settings.planScale ?? Self.fittingScale(for: planBounds, in: area, reserve: Self.viewTitleHeight) ?? Self.minimumScale(for: planBounds, in: area)
        if settings.planScale == nil, Self.fittingScale(for: planBounds, in: area, reserve: Self.viewTitleHeight) == nil {
            notes.append("The plan does not fit \(paper.title) at a standard scale; it is drawn at 1:\(planScale).")
        }
        let plan = DrawingView(id: "plan", title: "Floor plan", scale: planScale, primitives: Self.planView(planPrimitives, scale: planScale, sections: settings.includeSections ? settings.sections : []))
        var planSheet = place([plan], in: area, scale: planScale)
        planSheet += Self.northArrow(at: Point2D(x: area.maxX - 12, y: area.maxY - 16))
        planSheet += Self.scaleBar(origin: Point2D(x: Self.margin + 6, y: Self.margin + 8), scale: planScale)
        pages.append(("Floor plan", "1:\(planScale)", planSheet))

        let quantities = ProjectQuantities(project: project, schedules: schedules)
        let roomOutlines = Self.roomOutlines(project, topology: semantic.topology)

        // Area plan: colour-filled rooms with a legend in a right-hand column.
        if settings.includeAreaPlan, !roomOutlines.isEmpty {
            let legendWidth = 78.0
            let planArea = CADRect(minX: area.minX, minY: area.minY, maxX: area.maxX - legendWidth - 6, maxY: area.maxY)
            let scale = settings.planScale.flatMap { s in planBounds.width / Double(s) <= planArea.width ? s : nil }
                ?? Self.fittingScale(for: planBounds, in: planArea, reserve: Self.viewTitleHeight) ?? Self.minimumScale(for: planBounds, in: planArea)
            let view = DrawingView(id: "area-plan", title: "Area plan", scale: scale,
                                   primitives: Self.areaPlanView(planPrimitives, outlines: roomOutlines, schedules: schedules, scale: scale))
            var sheet = place([view], in: planArea, scale: scale)
            sheet += Self.areaLegend(roomOutlines: roomOutlines, schedules: schedules, at: Point2D(x: area.maxX - legendWidth, y: area.maxY), width: legendWidth)
            sheet += Self.northArrow(at: Point2D(x: planArea.maxX - 12, y: planArea.maxY - 16))
            sheet += Self.scaleBar(origin: Point2D(x: Self.margin + 6, y: Self.margin + 8), scale: scale)
            pages.append(("Area plan", "1:\(scale)", sheet))
        }

        // Reflected ceiling plan: walls and opening heads, ceiling heights and finishes.
        if settings.includeCeilingPlan, !roomOutlines.isEmpty {
            let view = DrawingView(id: "ceiling-plan", title: "Reflected ceiling plan", scale: planScale,
                                   primitives: Self.ceilingPlanView(planPrimitives, outlines: roomOutlines, schedules: schedules, finishes: settings.finishes, scale: planScale))
            var sheet = place([view], in: area, scale: planScale)
            sheet += Self.northArrow(at: Point2D(x: area.maxX - 12, y: area.maxY - 16))
            sheet += Self.scaleBar(origin: Point2D(x: Self.margin + 6, y: Self.margin + 8), scale: planScale)
            pages.append(("Reflected ceiling plan", "1:\(planScale)", sheet))
        }

        // Schedules and quantities.
        let tables = (settings.includeSchedules ? schedules.tables : []) + (settings.includeQuantities ? quantities.tables : [])
        if !tables.isEmpty {
            for (index, sheet) in Self.scheduleSheets(tables, in: area).enumerated() {
                let title = settings.includeQuantities && !quantities.tables.isEmpty ? "Schedules and quantities" : "Schedules"
                pages.append((index == 0 ? title : "\(title) (\(index + 1))", "—", sheet))
            }
        }

        // Interior elevations, one scale for all.
        var elevationScale: Int?
        if settings.includeElevations {
            let engine = ArchitecturalSectionEngine()
            func elevations(_ scale: Int) -> [DrawingView] {
                PlanOrdering(project: project).rooms.flatMap { room in
                    engine.interiorElevations(room: room, roomName: roomNames[room.id] ?? "Room", project: project, physical: physical, schedules: schedules, scale: scale)
                }
            }
            let probe = elevations(50)
            if !probe.isEmpty {
                let scale = settings.elevationScale ?? Self.commonScale(for: probe, in: area)
                elevationScale = scale
                let views = scale == 50 ? probe : elevations(scale)
                for (index, group) in Self.pack(views, in: area, scale: scale).enumerated() {
                    pages.append((index == 0 ? "Interior elevations" : "Interior elevations (\(index + 1))", "1:\(scale)", place(group, in: area, scale: scale)))
                }
            }
        }

        // Sections.
        var sectionScale: Int?
        if settings.includeSections, !settings.sections.isEmpty {
            let engine = ArchitecturalSectionEngine()
            let probe = settings.sections.map { engine.section($0, project: project, physical: physical, scale: 50) }
            let scale = settings.elevationScale ?? Self.commonScale(for: probe, in: area)
            sectionScale = scale
            let views = settings.sections.map { engine.section($0, project: project, physical: physical, scale: scale) }
            for (index, group) in Self.pack(views, in: area, scale: scale).enumerated() {
                pages.append((index == 0 ? "Sections" : "Sections (\(index + 1))", "1:\(scale)", place(group, in: area, scale: scale)))
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateText = formatter.string(from: date)
        let sheets = pages.enumerated().map { index, page in
            DrawingSheet(
                id: "sheet-\(index + 1)",
                number: index + 1,
                title: page.title,
                paper: paper,
                primitives: Self.frame(paper) + page.primitives + Self.titleBlock(
                    paper: paper, project: project, settings: settings, sheetTitle: page.title,
                    scale: page.scale, date: dateText, number: index + 1, count: pages.count
                )
            )
        }
        return DrawingSet(sheets: sheets, schedules: schedules, quantities: quantities, planScale: planScale, elevationScale: elevationScale, sectionScale: sectionScale, notes: notes)
    }

    // MARK: Layout

    /// The printable area above the title-block band.
    static func drawingArea(_ paper: PaperSize) -> CADRect {
        let size = paper.size
        return CADRect(minX: margin + 5, minY: margin + titleBlockHeight + 6, maxX: size.width - margin - 5, maxY: size.height - margin - 5)
    }

    /// The largest standard scale (smallest denominator) at which `bounds` fits `area`.
    static func fittingScale(for bounds: CADRect, in area: CADRect, reserve: Double) -> Int? {
        guard !bounds.isEmpty else { return 50 }
        return DocumentationSettings.standardScales.first { scale in
            bounds.width / Double(scale) <= area.width && bounds.height / Double(scale) + reserve <= area.height
        }
    }

    /// A round scale that fits when no standard one does.
    static func minimumScale(for bounds: CADRect, in area: CADRect) -> Int {
        let needed = max(bounds.width / area.width, bounds.height / max(1, area.height - viewTitleHeight))
        return max(1, Int((needed / 100).rounded(.up)) * 100)
    }

    /// One scale at which every view fits a sheet on its own.
    static func commonScale(for views: [DrawingView], in area: CADRect) -> Int {
        // Views were laid out at 1:50; their geometry extent is scale independent apart from annotation,
        // which grows with the scale, so check each candidate with a 25 % annotation allowance.
        let bounds = CADRect(minX: 0, minY: 0, maxX: views.map(\.bounds.width).max() ?? 0, maxY: views.map(\.bounds.height).max() ?? 0)
        return DocumentationSettings.standardScales.filter { $0 >= 20 }.first { scale in
            bounds.width * 1.25 / Double(scale) <= area.width && bounds.height * 1.25 / Double(scale) + viewTitleHeight <= area.height
        } ?? minimumScale(for: bounds, in: area)
    }

    /// Shelf packing of views into sheets: rows left to right, top to bottom.
    static func pack(_ views: [DrawingView], in area: CADRect, scale: Int) -> [[DrawingView]] {
        var sheets: [[DrawingView]] = []
        var current: [DrawingView] = []
        var x = 0.0, rowHeight = 0.0, usedHeight = 0.0
        for view in views {
            let w = view.bounds.width / Double(scale), h = view.bounds.height / Double(scale) + viewTitleHeight
            if x > 0, x + w > area.width {
                usedHeight += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            if !current.isEmpty, usedHeight + h > area.height {
                sheets.append(current)
                current = []
                x = 0; rowHeight = 0; usedHeight = 0
            }
            current.append(view)
            x += w + gap
            rowHeight = max(rowHeight, h)
        }
        if !current.isEmpty { sheets.append(current) }
        return sheets
    }

    /// Places views in rows inside `area` (same packing as `pack`), each with its title underneath.
    func place(_ views: [DrawingView], in area: CADRect, scale: Int) -> [SheetPrimitive] {
        let s = Double(scale)
        var out: [SheetPrimitive] = []
        var rows: [[DrawingView]] = [[]]
        var x = 0.0
        for view in views {
            let w = view.bounds.width / s
            if x > 0, x + w > area.width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(view)
            x += w + Self.gap
        }
        var top = area.maxY
        for row in rows where !row.isEmpty {
            let rowHeight = row.map { $0.bounds.height / s }.max() ?? 0
            let rowWidth = row.map { $0.bounds.width / s }.reduce(0, +) + Self.gap * Double(row.count - 1)
            // A single view is centred; rows of several views start at the left.
            var left = row.count == 1 ? area.minX + (area.width - rowWidth) / 2 : area.minX
            for view in row {
                let b = view.bounds
                let w = b.width / s
                let origin = Point2D(x: left, y: top - rowHeight + (rowHeight - b.height / s))
                func map(_ p: Point2D) -> Point2D { Point2D(x: origin.x + (p.x - b.minX) / s, y: origin.y + (p.y - b.minY) / s) }
                out += view.primitives.map { $0.mapped(map, scale: 1 / s) }
                let titleY = top - rowHeight - 6
                out.append(SheetPrimitive(.text(view.title, at: Point2D(x: left, y: titleY), height: 3.0, rotation: 0, anchor: .left, bold: true)))
                out.append(SheetPrimitive(.text("1:\(scale)", at: Point2D(x: left + w, y: titleY), height: 2.5, rotation: 0, anchor: .right, bold: false)))
                out.append(SheetPrimitive(.line(Point2D(x: left, y: titleY - 1.5), Point2D(x: left + max(w, 40), y: titleY - 1.5)), weight: 0.35))
                left += w + Self.gap
            }
            top -= rowHeight + Self.viewTitleHeight + Self.gap
        }
        return out
    }

    // MARK: Plan view

    static func plotted(_ primitive: DXFPrimitive) -> Bool {
        guard let layer = ArchitecturalDraftingConvention.Layer(rawValue: primitive.layer) else { return true }
        return ArchitecturalDraftingConvention.isPlotLayer(layer)
    }

    /// The drawing's primitives as a plan view: technical layers dropped, annotation text at fixed
    /// paper heights, tag frames sized for the paper, and section marks.
    static func planView(_ primitives: [DXFPrimitive], scale: Int, sections: [SectionLine]) -> [SheetPrimitive] {
        typealias Layer = ArchitecturalDraftingConvention.Layer
        let s = Double(scale)
        var out: [SheetPrimitive] = []
        let tagCenters = Dictionary(primitives.filter { $0.layer == Layer.tags.rawValue && $0.kind == .text }.compactMap { p -> (String, Point2D)? in
            guard let at = p.points.first else { return nil }
            return (String(p.id.dropLast(":text".count)), at)
        }, uniquingKeysWith: { a, _ in a })
        for p in primitives where plotted(p) {
            let weight = max(0.13, p.lineWeightMM)
            let isTag = p.layer == Layer.tags.rawValue
            switch p.kind {
            case .line where p.points.count >= 2:
                out.append(SheetPrimitive(.line(p.points[0], p.points[1]), weight: weight))
            case .polyline where p.points.count >= 2:
                if isTag, let center = tagCenters[String(p.id.dropLast(":frame".count))] {
                    // Model-sized tag frames are rescaled to read the same at every scale.
                    let k = 3.2 * s / 240
                    out.append(SheetPrimitive(.polyline(p.points.map { center + ($0 - center) * k }, closed: true), weight: 0.25, fill: 1))
                } else {
                    out.append(SheetPrimitive(.polyline(p.points, closed: p.closed), weight: weight))
                }
            case .arc:
                guard let c = p.center, let r = p.radius, let a = p.startAngleDegrees, let b = p.endAngleDegrees else { continue }
                if isTag {
                    // Door tags are two half arcs in DXF; one paper-sized circle on the sheet.
                    if p.id.hasSuffix(":frame") { out.append(SheetPrimitive(.circle(center: c, radius: 3.2 * s), weight: 0.25, fill: 1)) }
                } else if abs(b - a) >= 359.999 {
                    out.append(SheetPrimitive(.circle(center: c, radius: r), weight: weight))
                } else {
                    out.append(SheetPrimitive(.arc(center: c, radius: r, start: a * .pi / 180, end: b * .pi / 180), weight: weight))
                }
            case .text:
                guard let at = p.points.first, let text = p.text else { continue }
                let height: Double
                var bold = false
                if p.layer == Layer.dimensions.rawValue { height = 2.0 }
                else if isTag { height = 2.2; bold = true }
                else if p.id.hasPrefix("room-name:") { height = 3.0; bold = true }
                else if p.layer == Layer.roomAnnotation.rawValue { height = 2.5 }
                else { height = max(1.8, (p.textHeight ?? 150) / s) }
                let rotation = (p.rotationDegrees ?? 0) * .pi / 180
                // DXF labels are centred on their point; drop the baseline by half the text height.
                let down = Point2D(x: sin(rotation), y: -cos(rotation)) * (height * s / 2)
                out.append(SheetPrimitive(.text(text, at: at + down, height: height, rotation: rotation, anchor: .center, bold: bold)))
            default:
                continue
            }
        }
        // Text last, so white tag frames never cover their labels (stable: drawing order is kept otherwise).
        func isText(_ p: SheetPrimitive) -> Bool { if case .text = p.shape { return true }; return false }
        out = out.filter { !isText($0) } + out.filter(isText)
        for section in sections { out += sectionMark(section, scale: scale) }
        return out
    }

    /// Chain line with labelled bubbles and view-direction arrows at both ends.
    static func sectionMark(_ section: SectionLine, scale: Int) -> [SheetPrimitive] {
        let s = Double(scale)
        var out = [SheetPrimitive(.line(section.start, section.end), weight: 0.35, dash: [6, 1.5, 1, 1.5])]
        let view = section.viewDirection
        for end in [section.start, section.end] {
            let outward = (end - (section.start + section.end) * 0.5).normalized
            let bubble = end + outward * (5 * s)
            out.append(SheetPrimitive(.circle(center: bubble, radius: 4 * s), weight: 0.35, fill: 1))
            out.append(SheetPrimitive(.text(section.label, at: bubble + Point2D(x: 0, y: -1.5 * s), height: 3.0, rotation: 0, anchor: .center, bold: true)))
            let tip = end + view * (5 * s)
            let side = Point2D(x: -view.y, y: view.x) * (2 * s)
            out.append(SheetPrimitive(.polygon([tip, end + side, end - side]), weight: 0.13, fill: 0))
        }
        return out
    }

    // MARK: Area and ceiling plans

    /// Clear interior outline of every closed room, by room ID.
    static func roomOutlines(_ project: PlanOpsisProject, topology: StructureTopologySnapshot) -> [(room: PlanOpsisRoom, outline: [Point2D])] {
        PlanOrdering(project: project).rooms.compactMap { room in
            let centerline = ArchitecturalRoomEnvelope.polygon(for: room, topology: topology)
            guard let inner = RoomFaceBoundary(room: room, centerline: centerline)?.inner, inner.count >= 3 else { return nil }
            return (room, inner)
        }
    }

    static func color(for index: Int) -> SheetColor { SheetColor.roomPalette[index % SheetColor.roomPalette.count] }

    /// Walls and openings only (no furniture, swings, dimensions or labels), optionally dashed.
    static func outlineOnly(_ primitives: [DXFPrimitive], dashedOpenings: Bool) -> [SheetPrimitive] {
        typealias Layer = ArchitecturalDraftingConvention.Layer
        let openingLayers: Set<String> = [Layer.door.rawValue, Layer.window.rawValue, Layer.opening.rawValue]
        var out: [SheetPrimitive] = []
        for p in primitives where p.layer == Layer.wall.rawValue || openingLayers.contains(p.layer) {
            let isOpening = openingLayers.contains(p.layer)
            let weight = isOpening ? 0.18 : max(0.35, p.lineWeightMM)
            let dash: [Double] = isOpening && dashedOpenings ? [2, 1.2] : []
            switch p.kind {
            case .line where p.points.count >= 2:
                out.append(SheetPrimitive(.line(p.points[0], p.points[1]), weight: weight, dash: dash))
            case .polyline where p.points.count >= 2:
                out.append(SheetPrimitive(.polyline(p.points, closed: p.closed), weight: weight, dash: dash))
            case .arc:
                // Door leaves' swing arcs live on the swing layer; arcs here are window or opening symbols.
                guard let c = p.center, let r = p.radius, let a = p.startAngleDegrees, let b = p.endAngleDegrees else { continue }
                out.append(SheetPrimitive(.arc(center: c, radius: r, start: a * .pi / 180, end: b * .pi / 180), weight: weight, dash: dash))
            default:
                continue
            }
        }
        return out
    }

    static func centeredLabel(_ text: String, at p: Point2D, height: Double, bold: Bool, scale: Int, offset: Double = 0) -> SheetPrimitive {
        // `offset` is in paper millimetres above (positive) or below the point.
        SheetPrimitive(.text(text, at: Point2D(x: p.x, y: p.y + (offset - height / 2) * Double(scale)), height: height, rotation: 0, anchor: .center, bold: bold))
    }

    static func areaPlanView(_ primitives: [DXFPrimitive], outlines: [(room: PlanOpsisRoom, outline: [Point2D])], schedules: ProjectSchedules, scale: Int) -> [SheetPrimitive] {
        var out: [SheetPrimitive] = []
        for (index, entry) in outlines.enumerated() {
            out.append(SheetPrimitive(.polygon(entry.outline), weight: 0, fillColor: color(for: index)))
        }
        out += outlineOnly(primitives, dashedOpenings: false)
        for entry in outlines {
            guard let row = schedules.rooms.first(where: { $0.roomID == entry.room.id }), let c = PlanPolygon.centroid(entry.outline) else { continue }
            out.append(centeredLabel(row.name, at: c, height: 3.5, bold: true, scale: scale, offset: 2.6))
            out.append(centeredLabel(String(format: "%.2f m²", row.area / 1_000_000), at: c, height: 3.0, bold: false, scale: scale, offset: -2.6))
        }
        return out
    }

    /// Room colours, names and areas, then the total, top-down from `top`.
    static func areaLegend(roomOutlines: [(room: PlanOpsisRoom, outline: [Point2D])], schedules: ProjectSchedules, at top: Point2D, width: Double) -> [SheetPrimitive] {
        var out = [SheetPrimitive(.text("Areas", at: Point2D(x: top.x, y: top.y - 6), height: 3.5, rotation: 0, anchor: .left, bold: true))]
        var y = top.y - 15
        var total = 0.0
        for (index, entry) in roomOutlines.enumerated() {
            guard let row = schedules.rooms.first(where: { $0.roomID == entry.room.id }) else { continue }
            total += row.area
            out.append(SheetPrimitive(.polygon([Point2D(x: top.x, y: y - 1), Point2D(x: top.x + 6, y: y - 1), Point2D(x: top.x + 6, y: y + 3.5), Point2D(x: top.x, y: y + 3.5)]),
                                      weight: 0.13, fillColor: color(for: index)))
            out.append(SheetPrimitive(.text("\(row.number)  \(row.name)", at: Point2D(x: top.x + 9, y: y), height: 2.5, rotation: 0, anchor: .left, bold: false)))
            out.append(SheetPrimitive(.text(String(format: "%.2f m²", row.area / 1_000_000), at: Point2D(x: top.x + width, y: y), height: 2.5, rotation: 0, anchor: .right, bold: false)))
            y -= 7
        }
        out.append(SheetPrimitive(.line(Point2D(x: top.x, y: y + 4.5), Point2D(x: top.x + width, y: y + 4.5)), weight: 0.35))
        out.append(SheetPrimitive(.text("Total net floor area", at: Point2D(x: top.x, y: y - 0.5), height: 2.5, rotation: 0, anchor: .left, bold: true)))
        out.append(SheetPrimitive(.text(String(format: "%.2f m²", total / 1_000_000), at: Point2D(x: top.x + width, y: y - 0.5), height: 2.5, rotation: 0, anchor: .right, bold: true)))
        return out
    }

    static func ceilingPlanView(_ primitives: [DXFPrimitive], outlines: [(room: PlanOpsisRoom, outline: [Point2D])], schedules: ProjectSchedules, finishes: [UUID: RoomFinishes], scale: Int) -> [SheetPrimitive] {
        let s = Double(scale)
        var out = outlineOnly(primitives, dashedOpenings: true)
        for entry in outlines {
            guard let row = schedules.rooms.first(where: { $0.roomID == entry.room.id }), let c = PlanPolygon.centroid(entry.outline) else { continue }
            out.append(centeredLabel(row.name, at: c, height: 3.0, bold: true, scale: scale, offset: 8))
            // Ceiling height tag: boxed "CH +2.80", the RCP convention.
            let label = String(format: "CH +%.2f", row.height / 1_000)
            let w = (Double(label.count) * 1.75 + 4) * s, h = 6 * s
            out.append(SheetPrimitive(.polygon([Point2D(x: c.x - w / 2, y: c.y - h / 2), Point2D(x: c.x + w / 2, y: c.y - h / 2), Point2D(x: c.x + w / 2, y: c.y + h / 2), Point2D(x: c.x - w / 2, y: c.y + h / 2)]),
                                      weight: 0.35, fill: 1))
            out.append(centeredLabel(label, at: c, height: 2.8, bold: true, scale: scale))
            let ceiling = finishes[entry.room.id]?.ceiling.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ceiling.isEmpty { out.append(centeredLabel(ceiling, at: c, height: 2.4, bold: false, scale: scale, offset: -7)) }
        }
        return out
    }

    // MARK: Sheet furniture

    static func frame(_ paper: PaperSize) -> [SheetPrimitive] {
        let (w, h) = paper.size
        let m = margin
        return [SheetPrimitive(.polyline([Point2D(x: m, y: m), Point2D(x: w - m, y: m), Point2D(x: w - m, y: h - m), Point2D(x: m, y: h - m)], closed: true), weight: 0.5)]
    }

    static func northArrow(at center: Point2D) -> [SheetPrimitive] {
        [
            SheetPrimitive(.circle(center: center, radius: 7), weight: 0.25),
            SheetPrimitive(.polygon([center + Point2D(x: 0, y: 7), center + Point2D(x: 3.5, y: -5), center + Point2D(x: 0, y: -2.5)]), weight: 0.13, fill: 0),
            SheetPrimitive(.polygon([center + Point2D(x: 0, y: 7), center + Point2D(x: -3.5, y: -5), center + Point2D(x: 0, y: -2.5)]), weight: 0.25, fill: 1),
            SheetPrimitive(.text("N", at: center + Point2D(x: 0, y: 9), height: 3.0, rotation: 0, anchor: .center, bold: true)),
        ]
    }

    /// Alternating black and white bar of round metres at the plan scale.
    static func scaleBar(origin: Point2D, scale: Int) -> [SheetPrimitive] {
        let mmPerMetre = 1_000 / Double(scale)
        let steps: [Double] = mmPerMetre >= 20 ? [0, 1, 2, 3, 4, 5] : (mmPerMetre >= 5 ? [0, 2, 4, 6, 8, 10] : [0, 5, 10, 15, 20, 25])
        var out: [SheetPrimitive] = []
        for i in 0..<(steps.count - 1) {
            let x0 = origin.x + steps[i] * mmPerMetre, x1 = origin.x + steps[i + 1] * mmPerMetre
            out.append(SheetPrimitive(.polygon([Point2D(x: x0, y: origin.y), Point2D(x: x1, y: origin.y), Point2D(x: x1, y: origin.y + 1.5), Point2D(x: x0, y: origin.y + 1.5)]), weight: 0.18, fill: i.isMultiple(of: 2) ? 0 : 1))
        }
        for step in steps {
            out.append(SheetPrimitive(.text(String(format: "%g", step), at: Point2D(x: origin.x + step * mmPerMetre, y: origin.y + 3), height: 2.0, rotation: 0, anchor: .center, bold: false)))
        }
        out.append(SheetPrimitive(.text("m", at: Point2D(x: origin.x + steps.last! * mmPerMetre + 4, y: origin.y), height: 2.0, rotation: 0, anchor: .left, bold: false)))
        return out
    }

    /// Bottom-right title block: project, site, drawing, scale, date, author, revision, sheet number.
    static func titleBlock(paper: PaperSize, project: PlanOpsisProject, settings: DocumentationSettings, sheetTitle: String, scale: String, date: String, number: Int, count: Int) -> [SheetPrimitive] {
        let (w, _) = paper.size
        let width = min(180, w - 2 * margin), height = titleBlockHeight
        let x0 = w - margin - width, y0 = margin
        var out: [SheetPrimitive] = [SheetPrimitive(.polyline([Point2D(x: x0, y: y0), Point2D(x: x0 + width, y: y0), Point2D(x: x0 + width, y: y0 + height), Point2D(x: x0, y: y0 + height)], closed: true), weight: 0.5)]
        func hline(_ y: Double, from: Double = 0, to: Double? = nil) { out.append(SheetPrimitive(.line(Point2D(x: x0 + from, y: y0 + y), Point2D(x: x0 + (to ?? width), y: y0 + y)), weight: 0.18)) }
        func vline(_ x: Double, from: Double, to: Double) { out.append(SheetPrimitive(.line(Point2D(x: x0 + x, y: y0 + from), Point2D(x: x0 + x, y: y0 + to)), weight: 0.18)) }
        func field(_ label: String, _ value: String, x: Double, y: Double, size: Double = 2.5, bold: Bool = false) {
            out.append(SheetPrimitive(.text(label.uppercased(), at: Point2D(x: x0 + x + 1.5, y: y0 + y + 1.0 + size + 1.6), height: 1.4, rotation: 0, anchor: .left, bold: false), gray: 0.45))
            out.append(SheetPrimitive(.text(value, at: Point2D(x: x0 + x + 1.5, y: y0 + y + 1.0), height: size, rotation: 0, anchor: .left, bold: bold)))
        }
        // Rows from the top: project | site | drawing | scale/date/author/revision/sheet.
        hline(height - 9.5); hline(height - 17.5); hline(height - 28)
        field("Project", project.displayName, x: 0, y: height - 9.5, size: 3.2, bold: true)
        field("Site / client", [settings.siteAddress, settings.company].filter { !$0.isEmpty }.joined(separator: " · "), x: 0, y: height - 17.5, size: 2.4)
        field("Drawing", sheetTitle, x: 0, y: height - 28, size: 4.0, bold: true)
        let cells: [(String, String)] = [("Scale", scale), ("Date", date), ("Drawn", settings.author.isEmpty ? "—" : settings.author), ("Rev", settings.revision), ("Sheet", "\(number) / \(count)")]
        let cellWidth = width / Double(cells.count)
        for (i, cell) in cells.enumerated() {
            if i > 0 { vline(cellWidth * Double(i), from: 0, to: height - 28) }
            field(cell.0, cell.1, x: cellWidth * Double(i), y: 1.5)
        }
        out.append(SheetPrimitive(.text("PlanOpsis · measured from scan; verify dimensions on site", at: Point2D(x: x0 + width, y: y0 - 4), height: 1.8, rotation: 0, anchor: .right, bold: false), gray: 0.45))
        return out
    }

    // MARK: Schedules

    /// Tables flowed in columns across as many sheets as needed.
    static func scheduleSheets(_ tables: [ProjectSchedules.Table], in area: CADRect) -> [[SheetPrimitive]] {
        let rowHeight = 6.0, titleHeight = 9.0, charWidth = 1.55, padding = 3.0
        var sheets: [[SheetPrimitive]] = [[]]
        var x = area.minX, y = area.maxY, columnWidth = 0.0
        for table in tables {
            var widths = table.columns.map { Double($0.count) * charWidth + 2 * padding }
            for row in table.rows { for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], Double(cell.count) * charWidth + 2 * padding) } }
            let tableWidth = widths.reduce(0, +)
            var remaining = table.rows[...]
            var continued = false
            while true {
                let fitRows = Int(((y - area.minY) - titleHeight - rowHeight) / rowHeight)
                if fitRows < 1 || (fitRows < remaining.count && fitRows < 3 && y < area.maxY) {
                    // Next column, or next sheet when out of width.
                    x += columnWidth + 10
                    y = area.maxY
                    columnWidth = 0
                    if x + tableWidth > area.maxX { sheets.append([]); x = area.minX }
                    continue
                }
                let chunk = remaining.prefix(fitRows)
                remaining = remaining.dropFirst(chunk.count)
                sheets[sheets.count - 1] += drawTable(table, rows: Array(chunk), widths: widths, origin: Point2D(x: x, y: y), rowHeight: rowHeight, continued: continued)
                y -= titleHeight + rowHeight * Double(chunk.count + 1) + 8
                columnWidth = max(columnWidth, tableWidth)
                if remaining.isEmpty { break }
                continued = true
                y = area.minY // force a new column for the rest
            }
        }
        return sheets.filter { !$0.isEmpty }
    }

    static func drawTable(_ table: ProjectSchedules.Table, rows: [[String]], widths: [Double], origin: Point2D, rowHeight: Double, continued: Bool) -> [SheetPrimitive] {
        var out: [SheetPrimitive] = []
        let width = widths.reduce(0, +)
        out.append(SheetPrimitive(.text(table.title + (continued ? " (continued)" : ""), at: Point2D(x: origin.x, y: origin.y - 6), height: 3.0, rotation: 0, anchor: .left, bold: true)))
        let top = origin.y - 9
        let allRows = [table.columns] + rows
        let bottom = top - rowHeight * Double(allRows.count)
        out.append(SheetPrimitive(.polygon([Point2D(x: origin.x, y: top), Point2D(x: origin.x + width, y: top), Point2D(x: origin.x + width, y: top - rowHeight), Point2D(x: origin.x, y: top - rowHeight)]), weight: 0, fill: 0.88))
        for i in 0...allRows.count {
            let y = top - rowHeight * Double(i)
            out.append(SheetPrimitive(.line(Point2D(x: origin.x, y: y), Point2D(x: origin.x + width, y: y)), weight: i == 0 || i == 1 || i == allRows.count ? 0.35 : 0.13))
        }
        var x = origin.x
        for (c, w) in widths.enumerated() {
            out.append(SheetPrimitive(.line(Point2D(x: x, y: top), Point2D(x: x, y: bottom)), weight: 0.13))
            for (r, row) in allRows.enumerated() where c < row.count {
                let numeric = r > 0 && table.numericColumns.contains(c)
                let baseline = top - rowHeight * Double(r) - rowHeight + 1.9
                out.append(SheetPrimitive(.text(row[c], at: Point2D(x: numeric ? x + w - 3 : x + 3, y: baseline), height: 2.2, rotation: 0, anchor: numeric ? .right : .left, bold: r == 0)))
            }
            x += w
        }
        out.append(SheetPrimitive(.line(Point2D(x: x, y: top), Point2D(x: x, y: bottom)), weight: 0.13))
        return out
    }
}
