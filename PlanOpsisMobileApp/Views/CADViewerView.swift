#if os(iOS)
import SwiftUI

enum CADViewerTool: String, CaseIterable, Identifiable {
    case inspect
    case distance
    case chain
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspect: return "Select"
        case .distance: return "Distance"
        case .chain: return "Chain"
        case .area: return "Area"
        }
    }

    var symbol: String {
        switch self {
        case .inspect: return "cursorarrow"
        case .distance: return "ruler"
        case .chain: return "point.topleft.down.to.point.bottomright.curvepath"
        case .area: return "square.dashed"
        }
    }
}

/// v12.3 CAD drawing viewer: pan, pinch zoom, layer visibility, entity inspection and snapped measuring.
///
/// Taps place snapped points (or select in Select mode). Touch-and-hold shows a precision cursor above
/// the finger with a live snap marker; lifting the finger places the point.
struct CADViewerView: View {
    let drawing: CADViewerDocument
    let hiddenLayers: Set<String>
    let onHideLayer: (String) -> Void
    let onIsolateLayer: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var camera: PlanViewTransform?
    @State private var pinchBase: PlanViewTransform?
    @State private var panBase: PlanViewTransform?
    @State private var isPinching = false
    @State private var isPanning = false
    @State private var tool: CADViewerTool = .inspect
    @State private var selectedItemID: Int?
    @State private var measurePoints: [Point2D] = []
    @State private var cursorScreen: CGPoint?
    @State private var cursorSnap: CADSnap?
    @State private var snapKinds: Set<CADSnapKind> = CADSnapKind.standard
    @State private var precisionEndedAt: Date?

    private let zoomStep = 1.6
    /// Pick and snap radius in screen points.
    private let pickRadius: Double = 16
    /// The precision cursor floats above the finger so the finger never hides the snap.
    private let cursorLift: CGFloat = 64

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fit = fittedCamera(size: size)
            let current = camera ?? fit
            ZStack(alignment: .top) {
                canvasBackground

                Canvas { context, canvasSize in
                    let renderer = CADCanvasRenderer(
                        scene: drawing.scene,
                        transform: current,
                        size: canvasSize,
                        hiddenLayers: hiddenLayers,
                        dark: colorScheme == .dark
                    )
                    renderer.draw(in: &context)
                    if let item = selectedItem { renderer.drawHighlight(item, in: &context) }
                    renderer.drawMeasurement(points: measurePoints, closed: tool == .area, units: drawing.document.units, in: &context)
                    if let cursorScreen {
                        renderer.drawCursor(at: cursorScreen, snap: cursorSnap, in: &context)
                    }
                }
                .contentShape(Rectangle())
                .gesture(panGesture(current: current))
                .simultaneousGesture(tapGesture(current: current, size: size))
                .simultaneousGesture(precisionGesture(current: current, size: size))
                .simultaneousGesture(pinchGesture(current: current, fit: fit, size: size))

                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        toolPalette
                        Spacer(minLength: 8)
                        zoomControls(current: current, fit: fit, size: size)
                    }
                    .padding(10)
                    Spacer(minLength: 0)
                    infoCard
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .coordinateSpace(.named("cad-viewer"))
        }
        .onChange(of: drawing.source) { _, _ in
            camera = nil
            resetInteraction()
        }
        .onChange(of: drawing.id) { _, _ in
            // Item IDs belong to one scene; an edited project drawing gets a new one.
            selectedItemID = nil
        }
        .onChange(of: hiddenLayers) { _, _ in
            if let item = selectedItem, !drawing.scene.isVisible(item, hiddenLayers: hiddenLayers) { selectedItemID = nil }
        }
    }

    private var canvasBackground: some View {
        colorScheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.14) : Color.white
    }

    private var selectedItem: CADSceneItem? {
        guard let id = selectedItemID, drawing.scene.items.indices.contains(id) else { return nil }
        return drawing.scene.items[id]
    }

    private func resetInteraction() {
        selectedItemID = nil
        measurePoints = []
        cursorScreen = nil
        cursorSnap = nil
    }

    // MARK: Camera

    private func fittedCamera(size: CGSize) -> PlanViewTransform {
        PlanViewTransform.fitted(
            to: drawing.scene.visibleBounds(hiddenLayers: hiddenLayers).floorGeometry,
            viewWidth: Double(size.width),
            viewHeight: Double(size.height)
        )
    }

    /// Zoom between 1/5 of the fit and 20 000× the fit, enough to read a 1 mm detail on a site plan.
    private func zoomed(_ base: PlanViewTransform, by factor: Double, about focus: CGPoint, fit: PlanViewTransform, size: CGSize) -> PlanViewTransform {
        let target = min(fit.scale * 20_000, max(fit.scale * 0.2, base.scale * factor))
        return base.zoomed(by: target / base.scale, about: Point2D(x: Double(focus.x), y: Double(focus.y)), viewWidth: Double(size.width), viewHeight: Double(size.height))
    }

    private func model(_ point: CGPoint, _ transform: PlanViewTransform, _ size: CGSize) -> Point2D {
        transform.model(Point2D(x: Double(point.x), y: Double(point.y)), viewWidth: Double(size.width), viewHeight: Double(size.height))
    }

    // MARK: Gestures

    private func panGesture(current: PlanViewTransform) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("cad-viewer"))
            .onChanged { value in
                guard !isPinching, cursorScreen == nil else { return }
                let base = panBase ?? current
                if panBase == nil { panBase = base }
                isPanning = true
                camera = base.panned(byScreenDX: Double(value.translation.width), dy: Double(value.translation.height))
            }
            .onEnded { _ in
                panBase = nil
                DispatchQueue.main.async { isPanning = false }
            }
    }

    private func pinchGesture(current: PlanViewTransform, fit: PlanViewTransform, size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? current
                if pinchBase == nil { pinchBase = base }
                isPinching = true
                camera = zoomed(base, by: Double(value.magnification), about: value.startLocation, fit: fit, size: size)
            }
            .onEnded { _ in
                pinchBase = nil
                DispatchQueue.main.async { isPinching = false }
            }
    }

    private func tapGesture(current: PlanViewTransform, size: CGSize) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("cad-viewer"))
            .onEnded { value in
                guard !isPinching, !isPanning, cursorScreen == nil else { return }
                // A long press that placed a point must not also count as a tap.
                if let precisionEndedAt, Date().timeIntervalSince(precisionEndedAt) < 0.4 { return }
                commit(at: value.location, current: current, size: size)
            }
    }

    private func precisionGesture(current: PlanViewTransform, size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("cad-viewer")))
            .onChanged { value in
                guard !isPinching, case .second(true, let drag?) = value else { return }
                let point = CGPoint(x: drag.location.x, y: drag.location.y - cursorLift)
                cursorSnap = snap(at: point, current: current, size: size)
                cursorScreen = point
            }
            .onEnded { value in
                defer { cursorScreen = nil; cursorSnap = nil; precisionEndedAt = Date() }
                guard case .second(true, let drag?) = value else { return }
                commit(at: CGPoint(x: drag.location.x, y: drag.location.y - cursorLift), current: current, size: size)
            }
    }

    private func snap(at point: CGPoint, current: PlanViewTransform, size: CGSize) -> CADSnap? {
        guard tool != .inspect else { return nil }
        let engine = CADSnapEngine(kinds: snapKinds)
        return engine.snap(at: model(point, current, size), radius: pickRadius / current.scale, in: drawing.scene, hiddenLayers: hiddenLayers, from: measurePoints.last)
    }

    private func commit(at point: CGPoint, current: PlanViewTransform, size: CGSize) {
        let modelPoint = model(point, current, size)
        switch tool {
        case .inspect:
            selectedItemID = CADPicker.pick(at: modelPoint, radius: pickRadius / current.scale, in: drawing.scene, hiddenLayers: hiddenLayers)?.id
        case .distance:
            let placed = snap(at: point, current: current, size: size)?.point ?? modelPoint
            if measurePoints.count >= 2 { measurePoints = [] }
            measurePoints.append(placed)
        case .chain, .area:
            measurePoints.append(snap(at: point, current: current, size: size)?.point ?? modelPoint)
        }
    }

    // MARK: Chrome

    private var toolPalette: some View {
        HStack(spacing: 4) {
            ForEach(CADViewerTool.allCases) { candidate in
                Button {
                    tool = candidate
                    measurePoints = []
                    if candidate != .inspect { selectedItemID = nil }
                } label: {
                    Image(systemName: candidate.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 32)
                        .foregroundStyle(tool == candidate ? Color.white : Color.primary)
                        .background(tool == candidate ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(tool == candidate ? .isSelected : [])
            }
            Divider().frame(height: 22)
            Menu {
                Section("Object snaps") {
                    ForEach(CADSnapKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { snapKinds.contains(kind) },
                            set: { on in if on { snapKinds.insert(kind) } else { snapKinds.remove(kind) } }
                        ))
                    }
                }
                Button("Default snaps") { snapKinds = CADSnapKind.standard }
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("Object snaps")
        }
        .padding(4)
        .planOpsisLiquidSurface(cornerRadius: 13)
    }

    private func zoomControls(current: PlanViewTransform, fit: PlanViewTransform, size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            Button { camera = zoomed(current, by: 1 / zoomStep, about: center, fit: fit, size: size) } label: {
                Image(systemName: "minus").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Zoom out")
            Button { camera = nil } label: {
                Text(zoomLabel(current: current, fit: fit))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 32)
            }
            .accessibilityLabel("Fit drawing to screen")
            Button { camera = zoomed(current, by: zoomStep, about: center, fit: fit, size: size) } label: {
                Image(systemName: "plus").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.plain)
        .padding(4)
        .planOpsisLiquidSurface(cornerRadius: 13)
    }

    private func zoomLabel(current: PlanViewTransform, fit: PlanViewTransform) -> String {
        guard camera != nil else { return "Fit" }
        let ratio = current.scale / fit.scale
        return ratio >= 10 ? String(format: "%.0f×", ratio) : String(format: "%.1f×", ratio)
    }

    @ViewBuilder
    private var infoCard: some View {
        if tool == .inspect, let item = selectedItem {
            selectionCard(item)
        } else if tool != .inspect {
            measurementCard
        }
    }

    private func selectionCard(_ item: CADSceneItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(CADCanvasRenderer.displayColor(item.color, dark: colorScheme == .dark))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                Text(drawing.entity(for: item)?.type ?? "Entity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Hide layer \(item.layer)") { onHideLayer(item.layer) }
                    Button("Show only layer \(item.layer)") { onIsolateLayer(item.layer) }
                } label: {
                    Image(systemName: "square.3.layers.3d").frame(width: 30, height: 28)
                }
                .accessibilityLabel("Layer actions")
                Button { selectedItemID = nil } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
            let rows = drawing.inspection(of: item).filter { $0.title != "Type" }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.title).font(.caption).foregroundStyle(.secondary)
                        Text(row.value).font(.caption.monospacedDigit()).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .planOpsisLiquidSurface(cornerRadius: 16)
    }

    private var measurementCard: some View {
        let units = drawing.document.units
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(measurementTitle)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let detail = measurementDetail(units: units) {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                if !measurePoints.isEmpty { measurePoints.removeLast() }
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 30)
            }
            .disabled(measurePoints.isEmpty)
            .accessibilityLabel("Remove last point")
            Button { measurePoints = [] } label: {
                Image(systemName: "trash").frame(width: 32, height: 30)
            }
            .disabled(measurePoints.isEmpty)
            .accessibilityLabel("Clear measurement")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 440)
        .planOpsisLiquidSurface(cornerRadius: 16)
    }

    private var measurementTitle: String {
        let units = drawing.document.units
        switch tool {
        case .inspect:
            return ""
        case .distance:
            guard measurePoints.count == 2 else { return measurePoints.isEmpty ? "Tap the first point" : "Tap the second point" }
            return CADMeasurement.formatLength(CADMeasurement.distance(measurePoints[0], measurePoints[1]), units: units)
        case .chain:
            guard measurePoints.count >= 2 else { return measurePoints.isEmpty ? "Tap points along the path" : "Tap the next point" }
            return CADMeasurement.formatLength(CADMeasurement.chainLength(measurePoints), units: units)
        case .area:
            guard measurePoints.count >= 3 else { return "Tap \(3 - measurePoints.count) more corner\(measurePoints.count == 2 ? "" : "s")" }
            return CADMeasurement.formatArea(CADMeasurement.area(measurePoints), units: units)
        }
    }

    private func measurementDetail(units: CADUnits) -> String? {
        switch tool {
        case .inspect:
            return nil
        case .distance:
            guard measurePoints.count == 2 else { return "Hold to aim with snaps" }
            let a = measurePoints[0], b = measurePoints[1]
            return "ΔX \(CADMeasurement.formatLength(b.x - a.x, units: units))  ΔY \(CADMeasurement.formatLength(b.y - a.y, units: units))  \(CADMeasurement.formatAngle(CADMeasurement.angleDegrees(a, b)))"
        case .chain:
            return measurePoints.count >= 2 ? "\(measurePoints.count - 1) segment\(measurePoints.count == 2 ? "" : "s")" : "Hold to aim with snaps"
        case .area:
            guard measurePoints.count >= 3 else { return "Hold to aim with snaps" }
            return "Perimeter \(CADMeasurement.formatLength(CADMeasurement.chainLength(measurePoints, closed: true), units: units))"
        }
    }
}

// MARK: - Renderer

/// Draws a `CADScene` into a SwiftUI Canvas through the plan camera.
struct CADCanvasRenderer {
    let scene: CADScene
    let transform: PlanViewTransform
    let size: CGSize
    let hiddenLayers: Set<String>
    let dark: Bool

    /// Text smaller than this on screen is not drawn.
    private let minimumTextHeight: CGFloat = 3
    private let maximumTexts = 2_500

    func screen(_ p: Point2D) -> CGPoint {
        let s = transform.screen(p, viewWidth: Double(size.width), viewHeight: Double(size.height))
        return CGPoint(x: s.x, y: s.y)
    }

    var visibleRect: CADRect {
        let a = transform.model(Point2D(x: 0, y: 0), viewWidth: Double(size.width), viewHeight: Double(size.height))
        let b = transform.model(Point2D(x: Double(size.width), y: Double(size.height)), viewWidth: Double(size.width), viewHeight: Double(size.height))
        return CADRect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }

    /// CAD colours adapted to the canvas: ACI 7 follows the background, and colours too close to the
    /// background are pulled toward contrast so yellow stays readable on white.
    static func displayColor(_ color: CADColor, dark: Bool) -> Color {
        let r = Double(color.red) / 255, g = Double(color.green) / 255, b = Double(color.blue) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if color.isWhite || (r == 0 && g == 0 && b == 0) { return dark ? Color(white: 0.93) : Color(white: 0.08) }
        if !dark, luminance > 0.7 {
            let k = 0.62
            return Color(red: r * k, green: g * k, blue: b * k)
        }
        if dark, luminance < 0.18 {
            return Color(red: r + (1 - r) * 0.45, green: g + (1 - g) * 0.45, blue: b + (1 - b) * 0.45)
        }
        return Color(red: r, green: g, blue: b)
    }

    static func lineWidth(_ millimetres: Double?) -> CGFloat {
        guard let millimetres, millimetres > 0 else { return 0.8 }
        return CGFloat(max(0.8, min(4, millimetres * 4.5)))
    }

    private struct StrokeKey: Hashable {
        var color: CADColor
        var width: CGFloat
    }

    func draw(in context: inout GraphicsContext) {
        let rect = visibleRect.expanded(by: 2 / transform.scale)
        let items = scene.items(in: rect, hiddenLayers: hiddenLayers)
        let minimumExtent = 0.5 / transform.scale
        var colors: [CADColor: Color] = [:]
        func color(_ c: CADColor) -> Color {
            if let cached = colors[c] { return cached }
            let value = Self.displayColor(c, dark: dark)
            colors[c] = value
            return value
        }

        var strokes: [StrokeKey: Path] = [:]
        var texts: [CADSceneItem] = []
        var points: [CADSceneItem] = []
        for item in items {
            switch item.shape {
            case .text, .point: break
            default: if max(item.bounds.width, item.bounds.height) < minimumExtent { continue }
            }
            switch item.shape {
            case let .fill(loops):
                var path = Path()
                for loop in loops { addPolyline(loop, closed: true, to: &path) }
                context.fill(path, with: .color(color(item.color).opacity(0.85)), style: FillStyle(eoFill: true))
            case let .path(pointsList, closed):
                let key = StrokeKey(color: item.color, width: Self.lineWidth(item.lineWeightMM))
                var path = strokes[key] ?? Path()
                addPolyline(pointsList, closed: closed, to: &path)
                strokes[key] = path
            case let .segments(pointsList):
                let key = StrokeKey(color: item.color, width: item.isSnappable ? Self.lineWidth(item.lineWeightMM) : 0.5)
                var path = strokes[key] ?? Path()
                var i = 0
                while i + 1 < pointsList.count {
                    path.move(to: screen(pointsList[i]))
                    path.addLine(to: screen(pointsList[i + 1]))
                    i += 2
                }
                strokes[key] = path
            case .text:
                texts.append(item)
            case .point:
                points.append(item)
            }
        }
        for (key, path) in strokes {
            context.stroke(path, with: .color(color(key.color)), style: StrokeStyle(lineWidth: key.width, lineCap: .round, lineJoin: .round))
        }
        for item in points {
            guard case let .point(p) = item.shape else { continue }
            let s = screen(p)
            var path = Path()
            path.move(to: CGPoint(x: s.x - 3, y: s.y)); path.addLine(to: CGPoint(x: s.x + 3, y: s.y))
            path.move(to: CGPoint(x: s.x, y: s.y - 3)); path.addLine(to: CGPoint(x: s.x, y: s.y + 3))
            context.stroke(path, with: .color(color(item.color)), lineWidth: 1)
        }
        var drawnTexts = 0
        for item in texts {
            guard drawnTexts < maximumTexts, case let .text(text) = item.shape else { continue }
            if drawText(text, color: color(item.color), in: &context) { drawnTexts += 1 }
        }
    }

    /// Adds a polyline, dropping points closer than half a screen point to the previous one.
    private func addPolyline(_ points: [Point2D], closed: Bool, to path: inout Path) {
        guard let first = points.first else { return }
        var last = screen(first)
        path.move(to: last)
        for (i, p) in points.enumerated().dropFirst() {
            let s = screen(p)
            if i == points.count - 1 || abs(s.x - last.x) + abs(s.y - last.y) >= 0.5 {
                path.addLine(to: s)
                last = s
            }
        }
        if closed { path.closeSubpath() }
    }

    @discardableResult
    private func drawText(_ text: CADSceneText, color: Color, in context: inout GraphicsContext) -> Bool {
        let height = CGFloat(text.height * transform.scale)
        guard height >= minimumTextHeight else { return false }
        // CAD text height is the capital height, about 0.72 of the font size.
        let label = Text(text.string)
            .font(.system(size: min(2_000, height / 0.72)))
            .foregroundStyle(color)
        var layer = context
        let origin = screen(text.position)
        layer.translateBy(x: origin.x, y: origin.y)
        layer.rotate(by: .radians(-text.rotation))
        if abs(text.widthFactor - 1) > 0.01 { layer.scaleBy(x: CGFloat(max(0.1, text.widthFactor)), y: 1) }
        let anchor: UnitPoint
        switch (text.horizontal, text.vertical) {
        case (.left, .top): anchor = .topLeading
        case (.center, .top): anchor = .top
        case (.right, .top): anchor = .topTrailing
        case (.left, .middle): anchor = .leading
        case (.center, .middle): anchor = .center
        case (.right, .middle): anchor = .trailing
        case (.left, _): anchor = UnitPoint(x: 0, y: 0.8)
        case (.center, _): anchor = UnitPoint(x: 0.5, y: 0.8)
        case (.right, _): anchor = UnitPoint(x: 1, y: 0.8)
        }
        layer.draw(label, at: .zero, anchor: anchor)
        return true
    }

    func drawHighlight(_ item: CADSceneItem, in context: inout GraphicsContext) {
        let accent = Color.accentColor
        var path = Path()
        switch item.shape {
        case let .path(points, closed):
            addPolyline(points, closed: closed, to: &path)
        case let .segments(points):
            var i = 0
            while i + 1 < points.count { path.move(to: screen(points[i])); path.addLine(to: screen(points[i + 1])); i += 2 }
        case let .fill(loops):
            for loop in loops { addPolyline(loop, closed: true, to: &path) }
        case .text, .point:
            let a = screen(Point2D(x: item.bounds.minX, y: item.bounds.maxY)), b = screen(Point2D(x: item.bounds.maxX, y: item.bounds.minY))
            path.addRect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -3, dy: -3))
        }
        context.stroke(path, with: .color(accent.opacity(0.28)), style: StrokeStyle(lineWidth: Self.lineWidth(item.lineWeightMM) + 7, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: Self.lineWidth(item.lineWeightMM) + 1, lineCap: .round, lineJoin: .round))
        for key in item.keyPoints where key.kind == .endpoint || key.kind == .center {
            let s = screen(key.point)
            context.fill(Path(CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7)), with: .color(accent))
        }
    }

    func drawMeasurement(points: [Point2D], closed: Bool, units: CADUnits, in context: inout GraphicsContext) {
        guard !points.isEmpty else { return }
        let accent = Color.orange
        let screens = points.map(screen)
        if points.count >= 2 {
            var path = Path()
            path.move(to: screens[0])
            for s in screens.dropFirst() { path.addLine(to: s) }
            if closed, points.count >= 3 {
                path.closeSubpath()
                context.fill(path, with: .color(accent.opacity(0.12)))
            }
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: closed ? [6, 4] : []))
            let segmentCount = closed && points.count >= 3 ? points.count : points.count - 1
            for i in 0..<segmentCount {
                let a = points[i], b = points[(i + 1) % points.count]
                let length = CADMeasurement.distance(a, b)
                guard length * transform.scale > 40 else { continue }
                let mid = screen(Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                let label = Text(CADMeasurement.formatLength(length, units: units))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                let resolved = context.resolve(label)
                let textSize = resolved.measure(in: CGSize(width: 300, height: 40))
                let box = CGRect(x: mid.x - textSize.width / 2 - 5, y: mid.y - textSize.height / 2 - 2, width: textSize.width + 10, height: textSize.height + 4)
                context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(accent))
                context.draw(resolved, at: mid, anchor: .center)
            }
        }
        for s in screens {
            context.fill(Path(ellipseIn: CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9)), with: .color(accent), lineWidth: 2)
        }
    }

    /// Precision cursor: crosshair where the user aims, plus the snap glyph and its name.
    func drawCursor(at point: CGPoint, snap: CADSnap?, in context: inout GraphicsContext) {
        let ink: Color = dark ? .white : .black
        var cross = Path()
        cross.move(to: CGPoint(x: point.x - 14, y: point.y)); cross.addLine(to: CGPoint(x: point.x + 14, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - 14)); cross.addLine(to: CGPoint(x: point.x, y: point.y + 14))
        context.stroke(cross, with: .color(ink.opacity(0.7)), lineWidth: 1)
        guard let snap else { return }
        let s = screen(snap.point)
        let marker = Self.snapGlyph(snap.kind, at: s)
        context.stroke(marker, with: .color(.green), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        let label = context.resolve(Text(snap.kind.title).font(.caption2.weight(.semibold)).foregroundStyle(.white))
        let textSize = label.measure(in: CGSize(width: 200, height: 30))
        let box = CGRect(x: s.x + 10, y: s.y - textSize.height - 12, width: textSize.width + 10, height: textSize.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.green.opacity(0.9)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    /// CAD-style snap glyphs: square endpoint, triangle midpoint, circle centre, diamond quadrant,
    /// cross intersection, right angle perpendicular.
    static func snapGlyph(_ kind: CADSnapKind, at p: CGPoint) -> Path {
        let r: CGFloat = 7
        var path = Path()
        switch kind {
        case .endpoint:
            path.addRect(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .midpoint:
            path.move(to: CGPoint(x: p.x, y: p.y - r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y + r)); path.addLine(to: CGPoint(x: p.x - r, y: p.y + r)); path.closeSubpath()
        case .center:
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .quadrant:
            path.move(to: CGPoint(x: p.x, y: p.y - r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y)); path.addLine(to: CGPoint(x: p.x, y: p.y + r)); path.addLine(to: CGPoint(x: p.x - r, y: p.y)); path.closeSubpath()
        case .intersection:
            path.move(to: CGPoint(x: p.x - r, y: p.y - r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
            path.move(to: CGPoint(x: p.x + r, y: p.y - r)); path.addLine(to: CGPoint(x: p.x - r, y: p.y + r))
        case .perpendicular:
            path.move(to: CGPoint(x: p.x - r, y: p.y - r)); path.addLine(to: CGPoint(x: p.x - r, y: p.y + r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
            path.move(to: CGPoint(x: p.x - r, y: p.y)); path.addLine(to: CGPoint(x: p.x, y: p.y)); path.addLine(to: CGPoint(x: p.x, y: p.y + r))
        case .nearest:
            path.move(to: CGPoint(x: p.x - r, y: p.y - r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y - r)); path.addLine(to: CGPoint(x: p.x - r, y: p.y + r)); path.addLine(to: CGPoint(x: p.x + r, y: p.y + r)); path.closeSubpath()
        case .insertion, .node:
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            path.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
        }
        return path
    }
}
#endif
