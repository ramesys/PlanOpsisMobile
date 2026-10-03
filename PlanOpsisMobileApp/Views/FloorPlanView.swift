#if os(iOS)
import SwiftUI

struct FloorPlanView: View {
    /// v12.1 frozen plan camera. It is refitted only on first layout, Fit, or a `fitIdentity` change,
    /// never because an edit changed the drawing extent (which rescaled the view mid-drag).
    @State private var camera: PlanViewTransform?
    /// Camera at the last fit; zoom limits and the zoom label are relative to it.
    @State private var fitCamera: PlanViewTransform?
    @State private var pinchBaseCamera: PlanViewTransform?
    @State private var isPinching = false
    @State private var panBaseCamera: PlanViewTransform?
    @State private var isPanning = false
    /// v12.3 object snap shown while a grip is dragged or after a snapped tap.
    @State private var activeSnap: CADSnap?
    /// v12.3 box selection in view coordinates (touch and hold, then drag).
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var isPushPulling = false
    @State private var underlayDragTranslation: CGSize = .zero
    @State private var precisionText = ""
    @Environment(\.colorScheme) private var colorScheme

    private let minimumZoom: Double = 0.35
    private let maximumZoom: Double = 4.0
    private let zoomStep: Double = 1.25

    /// Changing this value (another project, another focused room) refits the plan camera.
    let fitIdentity: String
    let snapshot: DisplayGeometrySnapshot
    let components: [PlanOpsisComponent]
    let annotations: [DXFPrimitive]
    /// Latest PLY plan-section evidence, retained in session state for scan-vs-model comparison.
    let plyEvidence: PLYReconstructionResult?
    let showPLYEvidence: Bool
    let onTogglePLYEvidence: () -> Void
    let selectedID: UUID?
    let selectedIDs: Set<UUID>
    let editableWall: PlanOpsisWall?
    let editableComponent: PlanOpsisComponent?
    let directEditingEnabled: Bool
    let gridEnabled: Bool
    let gridSpacingMM: Double
    let onSelect: (UUID?) -> Void
    /// Endpoint, proposed point, and whether the point is an object snap.
    let onMoveWallEndpoint: (WallEndpointKind, Point2D, Bool) -> Void
    let onMoveWallThickness: (Point2D) -> Void
    let onSetWallLength: (Double) -> Void
    let onSetWallDeltaX: (Double) -> Void
    let onSetWallDeltaY: (Double) -> Void
    let onMoveComponent: (Point2D) -> Void
    let onSetComponentRotationRadians: (Double) -> Void
    let onEndInteractiveEdit: () -> Void
    let creationTool: PlanObjectKind?
    let componentCreationTool: PlanOpsisComponent.Kind?
    let pendingWallStart: Point2D?
    /// Point, hit object, and whether the point is an object snap.
    let onPlanTap: (Point2D, UUID?, Bool) -> Void
    // v12.3 professional editing
    let editableOpening: PlanOpsisOpening?
    let openingHostWall: PlanOpsisWall?
    let openingClearances: (fromStart: Double, toEnd: Double)?
    let snapper: PlanObjectSnapper?
    let underlay: CADScene?
    let underlayHiddenLayers: Set<String>
    let isMovingUnderlay: Bool
    let dimensions: [PlanDimensionEdit]
    let pushPullOffset: Double?
    let onBoxSelect: (CADRect, PlanBoxSelectionMode) -> Void
    let onBeginPushPull: () -> Void
    let onPushPull: (Point2D, Bool) -> Void
    let onEndPushPull: () -> Void
    let onSlideOpening: (Point2D) -> Void
    let onEditDimension: (PlanDimensionEdit) -> Void
    let onMoveUnderlay: (Point2D) -> Void
    let onStopMovingUnderlay: () -> Void
    let onPrecisionInput: (String) -> Bool
    let onFinishCreation: () -> Void
    // v12.4 drawing set
    let sections: [SectionLine]
    let isPlacingSection: Bool
    let pendingSectionStart: Point2D?

    private var isPlacingPoints: Bool { creationTool != nil || componentCreationTool != nil || isPlacingSection }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let viewport = PlanViewport(transform: camera ?? fittedCamera(size: size), size: size)
            ZStack {
                Canvas { context, _ in
                    if let underlay {
                        // The underlay is reference only: faded, below the grid and the model.
                        context.drawLayer { layer in
                            layer.opacity = isMovingUnderlay ? 0.7 : 0.4
                            CADCanvasRenderer(scene: underlay, transform: viewport.transform, size: size, hiddenLayers: underlayHiddenLayers, dark: colorScheme == .dark)
                                .draw(in: &layer)
                        }
                    }
                    if gridEnabled {
                        drawGrid(viewport: viewport, context: &context)
                    }

                    for floor in snapshot.roomFloors where floor.polygon.count >= 3 {
                        var floorPath = Path()
                        floorPath.move(to: viewport.screen(floor.polygon[0]))
                        for point in floor.polygon.dropFirst() {
                            floorPath.addLine(to: viewport.screen(point))
                        }
                        floorPath.closeSubpath()
                        context.fill(floorPath, with: .color(.secondary.opacity(0.045)))
                    }

                    // Evidence is intentionally drawn above the floor wash but below semantic walls,
                    // so the measured PLY footprint remains legible during scan-vs-model comparison.
                    if showPLYEvidence, let plyEvidence {
                        drawPLYEvidence(plyEvidence, viewport: viewport, context: &context)
                    }

                    for segment in snapshot.planWallSegments {
                        var path = Path()
                        guard let first = segment.footprint.first else { continue }
                        path.move(to: viewport.screen(first))
                        for point in segment.footprint.dropFirst() {
                            path.addLine(to: viewport.screen(point))
                        }
                        path.closeSubpath()
                        context.fill(
                            path,
                            with: .color(segment.sourceWallIDs.contains(where: selectedIDs.contains) ? Color.accentColor : .primary.opacity(0.82))
                        )
                    }

                    for opening in snapshot.hostedOpenings {
                        draw(
                            opening: opening,
                            selected: opening.sourceOpeningIDs.contains(where: selectedIDs.contains),
                            viewport: viewport,
                            context: &context
                        )
                    }

                    for component in components {
                        draw(component: component, selected: selectedIDs.contains(component.id), viewport: viewport, context: &context)
                    }
                    for annotation in annotations { draw(annotation: annotation, viewport: viewport, context: &context) }

                    for section in sections {
                        drawSection(section, viewport: viewport, context: &context)
                    }

                    if let activeSnap {
                        drawSnap(activeSnap, viewport: viewport, context: &context)
                    }
                }
                .contentShape(Rectangle())
                // v9.9.3: taps select/place; drags navigate the drawing. Keeping
                // these as distinct gestures avoids the old zero-distance drag
                // recognizer that made object selection feel delayed and fought
                // with pinch gestures.
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("plan-space"))
                        .onEnded { value in
                            guard !isPinching, !isPanning, marqueeStart == nil, !isMovingUnderlay else { return }
                            let hit = hitTest(value.location, viewport: viewport)
                            if creationTool == .wall || componentCreationTool != nil || isPlacingSection {
                                let resolved = snappedPoint(value.location, viewport: viewport, from: isPlacingSection ? pendingSectionStart : pendingWallStart)
                                onPlanTap(resolved.point, hit, resolved.snapped)
                            } else if creationTool != nil {
                                activeSnap = nil
                                onPlanTap(viewport.plan(value.location), hit, false)
                            } else if directEditingEnabled, let dimension = dimensionHit(value.location, viewport: viewport) {
                                onEditDimension(dimension)
                            } else {
                                activeSnap = nil
                                onSelect(hit)
                            }
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("plan-space"))
                        .onChanged { value in
                            guard !isPinching, marqueeStart == nil else { return }
                            isPanning = true
                            if isMovingUnderlay {
                                let dx = value.translation.width - underlayDragTranslation.width
                                let dy = value.translation.height - underlayDragTranslation.height
                                underlayDragTranslation = value.translation
                                onMoveUnderlay(Point2D(x: Double(dx) / viewport.scale, y: -Double(dy) / viewport.scale))
                                return
                            }
                            let base = panBaseCamera ?? viewport.transform
                            if panBaseCamera == nil { panBaseCamera = base }
                            camera = base.panned(byScreenDX: Double(value.translation.width), dy: Double(value.translation.height))
                        }
                        .onEnded { _ in
                            panBaseCamera = nil
                            underlayDragTranslation = .zero
                            DispatchQueue.main.async { isPanning = false }
                        }
                )
                .simultaneousGesture(marqueeGesture(viewport: viewport))

                if directEditingEnabled, !isPlacingPoints {
                    if let wall = editableWall {
                        wallHandles(wall: wall, viewport: viewport)
                        wallDimensionEditor(wall: wall)
                    } else if let component = editableComponent {
                        componentHandles(component: component, viewport: viewport)
                    } else if let opening = editableOpening, let host = openingHostWall {
                        openingHandle(opening: opening, wall: host, viewport: viewport)
                    }
                }

                if let marqueeStart, let marqueeEnd {
                    marqueeOverlay(from: marqueeStart, to: marqueeEnd)
                }

                if isMovingUnderlay {
                    underlayMoveBanner
                }

                if isPlacingPoints {
                    VStack {
                        HStack(alignment: .top) {
                            creationBar
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                }

                zoomControls(size: size, current: viewport.transform)
                if plyEvidence != nil { evidenceControl }

                if let start = pendingWallStart ?? pendingSectionStart {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .position(viewport.screen(start))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "plan-space")
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBaseCamera ?? viewport.transform
                        if pinchBaseCamera == nil { pinchBaseCamera = base }
                        isPinching = true
                        // Zoom about the pinch location so the touched drawing stays under the fingers.
                        camera = zoomed(base, by: Double(value.magnification), about: value.startLocation, size: size)
                    }
                    .onEnded { _ in
                        pinchBaseCamera = nil
                        // Defer clearing so the zero-distance selection gesture from the
                        // same two-finger interaction cannot select an object accidentally.
                        DispatchQueue.main.async {
                            isPinching = false
                        }
                    }
            )
            .clipped()
            .onAppear { if camera == nil { refit(size: size) } }
            .onChange(of: fitIdentity) { _, _ in refit(size: size) }
        }
        .background(PlanOpsisPalette.workspace)
    }

    /// Fit to the complete visible drawing extent for the current geometry.
    private func fittedCamera(size: CGSize) -> PlanViewTransform {
        PlanViewTransform.fitted(
            to: PlanViewport.fitBounds(
                snapshot: snapshot,
                components: components,
                annotations: annotations,
                plyEvidence: showPLYEvidence ? plyEvidence : nil
            ),
            viewWidth: Double(size.width),
            viewHeight: Double(size.height)
        )
    }

    private func refit(size: CGSize) {
        let fitted = fittedCamera(size: size)
        fitCamera = fitted
        camera = fitted
        panBaseCamera = nil
        pinchBaseCamera = nil
    }

    /// Zooms `base` about a view point, keeping the result within the zoom limits relative to the fit.
    private func zoomed(_ base: PlanViewTransform, by factor: Double, about focus: CGPoint, size: CGSize) -> PlanViewTransform {
        let reference = fitCamera?.scale ?? base.scale
        let target = min(maximumZoom, max(minimumZoom, base.scale * factor / reference)) * reference
        return base.zoomed(by: target / base.scale, about: Point2D(x: Double(focus.x), y: Double(focus.y)),
                           viewWidth: Double(size.width), viewHeight: Double(size.height))
    }

    private var evidenceControl: some View {
        VStack {
            HStack {
                Button(action: onTogglePLYEvidence) {
                    Label(showPLYEvidence ? "PLY compare ON" : "PLY compare OFF", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(showPLYEvidence ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .planOpsisLiquidSurface(cornerRadius: 14)
                .accessibilityLabel(showPLYEvidence ? "Hide PLY evidence" : "Show PLY evidence")
                Spacer()
            }
            Spacer()
        }
        .padding(12)
    }

    private func zoomControls(size: CGSize, current: PlanViewTransform) -> some View {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        return VStack {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    Button {
                        camera = zoomed(current, by: 1 / zoomStep, about: center, size: size)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .frame(width: 34, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom out")

                    Button {
                        refit(size: size)
                    } label: {
                        Text(zoomLabel(current))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 46, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fit plan to screen")
                    .accessibilityValue(zoomLabel(current))

                    Button {
                        camera = zoomed(current, by: zoomStep, about: center, size: size)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .frame(width: 34, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom in")
                }
                .padding(4)
                .planOpsisLiquidSurface(cornerRadius: 14)
            }
            Spacer()
        }
        .padding(12)
    }

    private func zoomLabel(_ current: PlanViewTransform) -> String {
        guard let fitCamera, current != fitCamera else { return "Fit" }
        return "\(Int((current.scale / fitCamera.scale * 100).rounded()))%"
    }

    private var creationPrompt: String {
        if isPlacingSection { return pendingSectionStart == nil ? "Section: tap the cut start" : "Section: tap the cut end" }
        if let componentCreationTool { return "Place \(componentCreationTool.displayName)" }
        if let creationTool {
            if creationTool == .wall { return pendingWallStart == nil ? "Tap the first corner" : "Tap the next corner" }
            return "Add \(creationTool.rawValue.capitalized)"
        }
        return "Add object"
    }

    private func drawPLYEvidence(_ result: PLYReconstructionResult, viewport: PlanViewport, context: inout GraphicsContext) {
        // Keep interaction fluid on device. The reconstruction itself uses all downsampled evidence;
        // this is only the visual comparison underlay.
        let maxDisplayPoints = 12_000
        let step = max(1, result.sectionPointsMM.count / maxDisplayPoints)
        var pointPath = Path()
        if !result.sectionPointsMM.isEmpty {
            for index in stride(from: 0, to: result.sectionPointsMM.count, by: step) {
                let p = result.sectionPointsMM[index]
                let q = viewport.screen(Point2D(x: p.x, y: p.y))
                pointPath.addEllipse(in: CGRect(x: q.x - 1.05, y: q.y - 1.05, width: 2.1, height: 2.1))
            }
        }
        context.fill(pointPath, with: .color(Color.white.opacity(0.48)))

        for segment in result.segments {
            var path = Path()
            path.move(to: viewport.screen(Point2D(x: segment.start.x, y: segment.start.y)))
            path.addLine(to: viewport.screen(Point2D(x: segment.end.x, y: segment.end.y)))
            context.stroke(
                path,
                with: .color(Color.orange.opacity(0.34)),
                style: StrokeStyle(lineWidth: 0.9, dash: [5, 3])
            )
        }

        // QA candidates remain visible in comparison mode even when they were not promoted into
        // PlanOpsis semantics. Orange = review, faint red = suppressed scan noise.
        for wall in result.reviewWallSeeds {
            var path = Path()
            path.move(to: viewport.screen(Point2D(x: wall.startMM.x, y: wall.startMM.y)))
            path.addLine(to: viewport.screen(Point2D(x: wall.endMM.x, y: wall.endMM.y)))
            context.stroke(path, with: .color(Color.orange.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
        for wall in result.suppressedWallSeeds {
            var path = Path()
            path.move(to: viewport.screen(Point2D(x: wall.startMM.x, y: wall.startMM.y)))
            path.addLine(to: viewport.screen(Point2D(x: wall.endMM.x, y: wall.endMM.y)))
            context.stroke(path, with: .color(Color.red.opacity(0.22)), style: StrokeStyle(lineWidth: 1.0, dash: [2, 5]))
        }
    }

    private func drawGrid(viewport: PlanViewport, context: inout GraphicsContext) {
        let spacing = max(1, gridSpacingMM)
        let topLeft = viewport.plan(CGPoint(x: 0, y: 0))
        let bottomRight = viewport.plan(CGPoint(x: viewport.size.width, y: viewport.size.height))
        let minX = min(topLeft.x, bottomRight.x)
        let maxX = max(topLeft.x, bottomRight.x)
        let minY = min(topLeft.y, bottomRight.y)
        let maxY = max(topLeft.y, bottomRight.y)

        var x = floor(minX / spacing) * spacing
        while x <= maxX + spacing {
            var path = Path()
            path.move(to: viewport.screen(Point2D(x: x, y: minY)))
            path.addLine(to: viewport.screen(Point2D(x: x, y: maxY)))
            let major = Int((x / spacing).rounded()).isMultiple(of: 4)
            context.stroke(path, with: .color(.secondary.opacity(major ? 0.16 : 0.08)), lineWidth: major ? 1 : 0.5)
            x += spacing
        }

        var y = floor(minY / spacing) * spacing
        while y <= maxY + spacing {
            var path = Path()
            path.move(to: viewport.screen(Point2D(x: minX, y: y)))
            path.addLine(to: viewport.screen(Point2D(x: maxX, y: y)))
            let major = Int((y / spacing).rounded()).isMultiple(of: 4)
            context.stroke(path, with: .color(.secondary.opacity(major ? 0.16 : 0.08)), lineWidth: major ? 1 : 0.5)
            y += spacing
        }
    }

    @ViewBuilder
    private func wallDimensionEditor(wall: PlanOpsisWall) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                compactNumberField(
                    label: "L",
                    value: Binding(get: { wall.length }, set: onSetWallLength)
                )
                compactNumberField(
                    label: "ΔX",
                    value: Binding(get: { wall.end.x - wall.start.x }, set: onSetWallDeltaX)
                )
                compactNumberField(
                    label: "ΔY",
                    value: Binding(get: { wall.end.y - wall.start.y }, set: onSetWallDeltaY)
                )
            }
            .padding(8)
            .planOpsisLiquidSurface(cornerRadius: 18)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func componentHandles(component: PlanOpsisComponent, viewport: PlanViewport) -> some View {
        let center = viewport.screen(component.position)
        let rotationModelPoint = component.position + component.normal * (component.depth * 0.5 + max(220, 36 / max(viewport.scale, 1e-6)))
        let rotationPoint = viewport.screen(rotationModelPoint)

        Path { path in
            path.move(to: center)
            path.addLine(to: rotationPoint)
        }
        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .allowsHitTesting(false)

        Text("\(Int(component.width.rounded())) × \(Int(component.depth.rounded())) mm")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
            .position(x: center.x, y: center.y + 28)
            .allowsHitTesting(false)

        editHandle(label: "M", color: .accentColor, position: center) { point in
            onMoveComponent(viewport.plan(point))
        }
        editHandle(label: "R", color: .secondary, position: rotationPoint) { point in
            let target = viewport.plan(point)
            let delta = target - component.position
            guard delta.length > 1e-6 else { return }
            // Component normal points 90° counter-clockwise from its local width axis.
            onSetComponentRotationRadians(atan2(delta.y, delta.x) - .pi / 2)
        }
    }

    private func compactNumberField(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 54, idealWidth: 64, maxWidth: 76)
            Text("mm")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func wallHandles(wall: PlanOpsisWall, viewport: PlanViewport) -> some View {
        let start = viewport.screen(wall.start)
        let end = viewport.screen(wall.end)
        let modelOffset = wall.thickness * 0.5 + max(90, 18 / max(viewport.scale, 1e-6))
        let thicknessPoint = viewport.screen(wall.center + wall.normal * modelOffset)
        let dimensionOffset = wall.thickness * 0.5 + max(260, 36 / max(viewport.scale, 1e-6))
        let dimensionStart = viewport.screen(wall.start + wall.normal * dimensionOffset)
        let dimensionEnd = viewport.screen(wall.end + wall.normal * dimensionOffset)
        let dimensionMid = CGPoint(x: (dimensionStart.x + dimensionEnd.x) * 0.5, y: (dimensionStart.y + dimensionEnd.y) * 0.5)

        Path { path in
            path.move(to: start)
            path.addLine(to: dimensionStart)
            path.move(to: end)
            path.addLine(to: dimensionEnd)
            path.move(to: dimensionStart)
            path.addLine(to: dimensionEnd)
        }
        .stroke(.secondary.opacity(0.65), lineWidth: 1)
        .allowsHitTesting(false)

        Button {
            onEditDimension(PlanDimensionEdit(target: .wallLength(wall.id), measured: wall.length, labelPosition: wall.center, rotationDegrees: 0))
        } label: {
            Text("L \(wall.length.formatted(.number.precision(.fractionLength(0...1)))) mm")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.5), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .position(dimensionMid)
        .accessibilityLabel("Wall length \(Int(wall.length.rounded())) millimetres")
        .accessibilityHint("Edit the length by value")

        editHandle(label: "S", color: .accentColor, position: start) { point in
            let resolved = snappedPoint(point, viewport: viewport, from: wall.end)
            onMoveWallEndpoint(.start, resolved.point, resolved.snapped)
        }
        editHandle(label: "E", color: .accentColor, position: end) { point in
            let resolved = snappedPoint(point, viewport: viewport, from: wall.start)
            onMoveWallEndpoint(.end, resolved.point, resolved.snapped)
        }
        pushPullHandle(wall: wall, viewport: viewport)
        editHandle(label: "T", color: .secondary, position: thicknessPoint) { point in
            onMoveWallThickness(viewport.plan(point))
        }

        Path { path in
            path.move(to: viewport.screen(wall.center))
            path.addLine(to: thicknessPoint)
        }
        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .allowsHitTesting(false)
    }

    // MARK: v12.3 professional editing

    /// The model point under `screenPoint`, moved to an object snap when one is within reach.
    private func snappedPoint(_ screenPoint: CGPoint, viewport: PlanViewport, from origin: Point2D?) -> (point: Point2D, snapped: Bool) {
        let model = viewport.plan(screenPoint)
        guard let snapper else {
            activeSnap = nil
            return (model, false)
        }
        let radius = 18 / max(viewport.scale, 1e-9)
        if let snap = snapper.snap(model, radius: radius, from: origin, underlay: underlay, underlayHiddenLayers: underlayHiddenLayers) {
            activeSnap = snap
            return (snap.point, true)
        }
        activeSnap = nil
        return (model, false)
    }

    private func drawSnap(_ snap: CADSnap, viewport: PlanViewport, context: inout GraphicsContext) {
        let s = viewport.screen(snap.point)
        context.stroke(CADCanvasRenderer.snapGlyph(snap.kind, at: s), with: .color(.green), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        let label = context.resolve(Text(snap.kind.title).font(.caption2.weight(.semibold)).foregroundStyle(.white))
        let size = label.measure(in: CGSize(width: 200, height: 30))
        let box = CGRect(x: s.x + 10, y: s.y - size.height - 12, width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.green.opacity(0.9)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    /// Section mark on the plan: dash-dot cut line, lettered bubbles beyond both ends and arrows
    /// showing the direction the section looks.
    private func drawSection(_ section: SectionLine, viewport: PlanViewport, context: inout GraphicsContext) {
        let a = viewport.screen(section.start), b = viewport.screen(section.end)
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        context.stroke(line, with: .color(.purple), style: StrokeStyle(lineWidth: 1.2, dash: [10, 3, 2, 3]))
        let screenDirection = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = max(1, hypot(screenDirection.x, screenDirection.y))
        let u = CGPoint(x: screenDirection.x / length, y: screenDirection.y / length)
        // Plan Y is up and screen Y is down, so the model view direction flips its Y on screen.
        let view = section.viewDirection
        let v = CGPoint(x: view.x, y: -view.y)
        for (end, outward) in [(a, CGPoint(x: -u.x, y: -u.y)), (b, u)] {
            let bubble = CGPoint(x: end.x + outward.x * 16, y: end.y + outward.y * 16)
            let circle = Path(ellipseIn: CGRect(x: bubble.x - 11, y: bubble.y - 11, width: 22, height: 22))
            context.fill(circle, with: .color(Color(uiColor: .systemBackground)))
            context.stroke(circle, with: .color(.purple), lineWidth: 1.5)
            context.draw(Text(section.label).font(.caption.weight(.bold)).foregroundStyle(.purple), at: bubble, anchor: .center)
            var arrow = Path()
            arrow.move(to: CGPoint(x: end.x + v.x * 14, y: end.y + v.y * 14))
            arrow.addLine(to: CGPoint(x: end.x - v.y * 6, y: end.y + v.x * 6))
            arrow.addLine(to: CGPoint(x: end.x + v.y * 6, y: end.y - v.x * 6))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.purple))
        }
    }

    /// The editable dimension whose text is under the tap.
    private func dimensionHit(_ screenPoint: CGPoint, viewport: PlanViewport) -> PlanDimensionEdit? {
        dimensions
            .map { ($0, hypot(viewport.screen($0.labelPosition).x - screenPoint.x, viewport.screen($0.labelPosition).y - screenPoint.y)) }
            .filter { $0.1 <= 22 }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Touch and hold on the plan, then drag: left to right selects objects fully inside (window),
    /// right to left selects everything touched (crossing).
    private func marqueeGesture(viewport: PlanViewport) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("plan-space")))
            .onChanged { value in
                guard directEditingEnabled, !isPlacingPoints, !isMovingUnderlay, !isPinching,
                      case .second(true, let drag?) = value else { return }
                if marqueeStart == nil { marqueeStart = drag.startLocation }
                marqueeEnd = drag.location
            }
            .onEnded { _ in
                defer { marqueeStart = nil; marqueeEnd = nil }
                guard let a = marqueeStart, let b = marqueeEnd, hypot(b.x - a.x, b.y - a.y) > 8 else { return }
                let p = viewport.plan(a), q = viewport.plan(b)
                let rect = CADRect(minX: min(p.x, q.x), minY: min(p.y, q.y), maxX: max(p.x, q.x), maxY: max(p.y, q.y))
                onBoxSelect(rect, PlanBoxSelectionMode(from: Point2D(x: Double(a.x), y: 0), to: Point2D(x: Double(b.x), y: 0)))
            }
    }

    @ViewBuilder
    private func marqueeOverlay(from a: CGPoint, to b: CGPoint) -> some View {
        let crossing = b.x < a.x
        let tint: Color = crossing ? .green : .blue
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        Rectangle()
            .fill(tint.opacity(0.08))
            .overlay(Rectangle().stroke(tint, style: StrokeStyle(lineWidth: 1.2, dash: crossing ? [6, 4] : [])))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        Text(crossing ? "Crossing" : "Window")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint, in: Capsule())
            .position(x: b.x, y: b.y - 18)
            .allowsHitTesting(false)
    }

    /// Push/pull grip at the middle of the selected wall: drag across the wall to move it parallel.
    @ViewBuilder
    private func pushPullHandle(wall: PlanOpsisWall, viewport: PlanViewport) -> some View {
        let position = viewport.screen(wall.center)
        ZStack {
            Circle().fill(Color.accentColor)
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                // Screen Y points down, so the wall normal's screen angle is the negated model angle.
                .rotationEffect(.radians(-wall.angleRadians))
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .position(position)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("plan-space"))
                .onChanged { value in
                    if !isPushPulling {
                        isPushPulling = true
                        onBeginPushPull()
                    }
                    let resolved = snappedPoint(value.location, viewport: viewport, from: nil)
                    onPushPull(resolved.point, resolved.snapped)
                }
                .onEnded { _ in
                    isPushPulling = false
                    activeSnap = nil
                    onEndPushPull()
                }
        )
        .accessibilityLabel("Push or pull wall")
        .accessibilityHint("Drag across the wall to move it parallel; connected walls follow")
        if let pushPullOffset {
            Text("\(pushPullOffset >= 0 ? "+" : "")\(Int(pushPullOffset.rounded())) mm")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
                .position(x: position.x, y: position.y - 30)
                .allowsHitTesting(false)
        }
    }

    /// Slide grip on the selected opening: drag along the wall; clear distances to the wall ends show live.
    @ViewBuilder
    private func openingHandle(opening: PlanOpsisOpening, wall: PlanOpsisWall, viewport: PlanViewport) -> some View {
        let center = wall.start + wall.direction * opening.parameters.offsetAlongWall
        let position = viewport.screen(center)
        ZStack {
            Circle().fill(Color.accentColor)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.radians(-wall.angleRadians))
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .position(position)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("plan-space"))
                .onChanged { value in onSlideOpening(viewport.plan(value.location)) }
                .onEnded { _ in onEndInteractiveEdit() }
        )
        .accessibilityLabel("Move opening along its wall")
        if let openingClearances {
            Text("\(Int(openingClearances.fromStart.rounded())) · \(Int(opening.parameters.width.rounded())) · \(Int(openingClearances.toEnd.rounded())) mm")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
                .position(x: position.x, y: position.y + 32)
                .allowsHitTesting(false)
        }
    }

    /// Tool prompt; while drawing walls it also takes typed lengths and finishes the chain.
    private var creationBar: some View {
        HStack(spacing: 8) {
            Label(creationPrompt, systemImage: "cursorarrow.click")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if creationTool == .wall {
                TextField(pendingWallStart == nil ? "x,y" : "3450  ·  3450<90  ·  @dx,dy", text: $precisionText)
                    .font(.caption.monospacedDigit())
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .frame(minWidth: 120, maxWidth: 200)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit {
                        if onPrecisionInput(precisionText) { precisionText = "" }
                    }
                    .accessibilityLabel("Typed point")
                    .accessibilityHint("Length, length and angle, relative or absolute coordinates in millimetres")
            }
            Button("Done", action: onFinishCreation)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .planOpsisLiquidSurface(cornerRadius: 16)
    }

    private var underlayMoveBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Label("Drag to move the underlay", systemImage: "hand.draw")
                    .font(.caption.weight(.semibold))
                Button("Done", action: onStopMovingUnderlay)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .planOpsisLiquidSurface(cornerRadius: 16)
            Spacer()
        }
        .padding(.top, 56)
    }

    private func editHandle(
        label: String,
        color: Color,
        position: CGPoint,
        onDrag: @escaping (CGPoint) -> Void
    ) -> some View {
        ZStack {
            Circle().fill(Color(uiColor: .systemBackground))
            Circle().stroke(color, lineWidth: 3)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .position(position)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("plan-space"))
                .onChanged { value in onDrag(value.location) }
                .onEnded { _ in onEndInteractiveEdit() }
        )
        .accessibilityLabel("Wall \(label) parametric grip")
    }

    private func draw(annotation: DXFPrimitive, viewport: PlanViewport, context: inout GraphicsContext) {
        if annotation.kind == .line, annotation.points.count == 2 {
            var path = Path()
            path.move(to: viewport.screen(annotation.points[0])); path.addLine(to: viewport.screen(annotation.points[1]))
            context.stroke(path, with: .color(.secondary), lineWidth: 0.7)
        } else if annotation.kind == .text, let point = annotation.points.first, let text = annotation.text {
            let position = viewport.screen(point)
            let size = max(7, min(18, (annotation.textHeight ?? 150) * viewport.scale))
            context.drawLayer { layer in
                layer.translateBy(x: position.x, y: position.y)
                layer.rotate(by: .degrees(-(annotation.rotationDegrees ?? 0)))
                layer.draw(Text(text).font(.system(size: size, design: .monospaced)).foregroundColor(.secondary), at: .zero, anchor: .center)
            }
        }
    }

    private func draw(opening: DisplayOpeningGeometry, selected: Bool, viewport: PlanViewport, context: inout GraphicsContext) {
        draw(symbol: ArchitecturalSymbolLibrary.opening(opening, roomFloors: snapshot.roomFloors),
             color: selected ? .accentColor : (opening.cutsWall ? .primary : .secondary),
             outlineWeight: 0.25, viewport: viewport, context: &context)
    }

    private func draw(component: PlanOpsisComponent, selected: Bool, viewport: PlanViewport, context: inout GraphicsContext) {
        draw(symbol: ArchitecturalSymbolLibrary.component(component), color: selected ? .accentColor : .primary,
             outlineWeight: (component.kind == .column || component.kind == .beam) ? 0.35 : 0.18, viewport: viewport, context: &context)
    }

    private func draw(symbol: ArchitecturalSymbol, color: Color, outlineWeight: Double, viewport: PlanViewport, context: inout GraphicsContext) {
        for primitive in symbol.primitives {
            var path = Path()
            switch primitive.geometry {
            case .line(let a, let b):
                path.move(to: viewport.screen(a)); path.addLine(to: viewport.screen(b))
            case .polyline(let points, let closed):
                guard let first = points.first else { continue }
                path.move(to: viewport.screen(first))
                for point in points.dropFirst() { path.addLine(to: viewport.screen(point)) }
                if closed { path.closeSubpath() }
            case .arc(let center, let radius, let start, let end):
                // Sampling is a canvas adapter concern; DXF retains the exact circular arc.
                let sweep = ArchitecturalSymbol.Geometry.positiveAngle(end - start)
                for i in 0...48 {
                    let angle = start + sweep * Double(i) / 48
                    let point = center + Point2D(x: cos(angle), y: sin(angle)) * radius
                    if i == 0 { path.move(to: viewport.screen(point)) }
                    else { path.addLine(to: viewport.screen(point)) }
                }
            }
            let weight = primitive.role == .outline ? outlineWeight : 0.13
            context.stroke(path, with: .color(color), lineWidth: max(0.7, weight * 6))
        }
    }

    private func hitTest(_ screenPoint: CGPoint, viewport: PlanViewport) -> UUID? {
        let point = viewport.plan(screenPoint)
        let touchToleranceModel = max(1, 18 / max(viewport.scale, 1e-9))

        if let component = components.reversed().first(where: { ArchitecturalSymbolLibrary.component($0).bounds?.contains(point) == true }) {
            return component.id
        }

        // Keep hosted objects easy to select even when the whole room is fit
        // on a phone. The old fixed 120 mm hit band could collapse to only a
        // few screen pixels at Fit, which felt like delayed/failed selection.
        if let opening = snapshot.hostedOpenings.reversed().first(where: { candidate in
            let direction = Point2D(x: cos(candidate.angleRadians), y: sin(candidate.angleRadians))
            let a = candidate.center - direction * (candidate.width * 0.5)
            let b = candidate.center + direction * (candidate.width * 0.5)
            let tolerance = max(120, candidate.thickness * 0.75, touchToleranceModel)
            return distance(point, toSegmentFrom: a, to: b) <= tolerance || ArchitecturalSymbolLibrary.opening(candidate, roomFloors: snapshot.roomFloors).bounds?.contains(point) == true
        }) {
            return opening.primarySelectionID
        }

        for segment in snapshot.planWallSegments.reversed() {
            if pointInPolygon(point, segment.footprint) { return segment.primarySelectionID }
            if segment.footprint.count >= 4 {
                let startCenter = (segment.footprint[0] + segment.footprint[3]) * 0.5
                let endCenter = (segment.footprint[1] + segment.footprint[2]) * 0.5
                let halfThickness = (segment.footprint[0] - segment.footprint[3]).length * 0.5
                if distance(point, toSegmentFrom: startCenter, to: endCenter) <= max(halfThickness, touchToleranceModel * 0.8) {
                    return segment.primarySelectionID
                }
            }
        }
        return nil
    }

    private func distance(_ point: Point2D, toSegmentFrom a: Point2D, to b: Point2D) -> Double {
        let ab = b - a
        let lengthSquared = ab.dot(ab)
        guard lengthSquared > 1e-12 else { return (point - a).length }
        let t = max(0, min(1, (point - a).dot(ab) / lengthSquared))
        let projection = a + ab * t
        return (point - projection).length
    }

    private func pointInPolygon(_ point: Point2D, _ polygon: [Point2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let crosses = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) == 0 ? 1e-12 : (pj.y - pi.y)) + pi.x)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }
}

private struct PlanViewport {
    let transform: PlanViewTransform
    let size: CGSize

    var scale: Double { transform.scale }

    func screen(_ point: Point2D) -> CGPoint {
        let p = transform.screen(point, viewWidth: Double(size.width), viewHeight: Double(size.height))
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    func plan(_ point: CGPoint) -> Point2D {
        transform.model(Point2D(x: Double(point.x), y: Double(point.y)), viewWidth: Double(size.width), viewHeight: Double(size.height))
    }

    /// Complete visible architectural extent used for Fit.
    static func fitBounds(
        snapshot: DisplayGeometrySnapshot,
        components: [PlanOpsisComponent],
        annotations: [DXFPrimitive],
        plyEvidence: PLYReconstructionResult?
    ) -> FloorGeometry? {
        // v9.9.2: fit to the complete visible architectural extent, not only
        // opening centerlines. This prevents windows/door graphics at perimeter
        // walls from being clipped even when the room itself fits correctly.
        var points: [Point2D] = snapshot.planWallSegments.flatMap(\.footprint)
        for opening in snapshot.hostedOpenings {
            let symbol = ArchitecturalSymbolLibrary.opening(opening, roomFloors: snapshot.roomFloors)
            points.append(contentsOf: symbol.primitives.flatMap { $0.geometry.boundsPoints })
        }
        for component in components {
            let symbol = ArchitecturalSymbolLibrary.component(component)
            points.append(contentsOf: symbol.primitives.flatMap { $0.geometry.boundsPoints })
        }
        points.append(contentsOf: snapshot.roomFloors.flatMap(\.polygon))
        points.append(contentsOf: annotations.flatMap(\.boundsPoints))
        if let plyEvidence {
            // Evidence may contain tens of thousands of section points. Fit only needs the extent,
            // so scan once and append four corners instead of allocating a Point2D for every sample.
            if let firstEvidencePoint = plyEvidence.sectionPointsMM.first {
                var minX = firstEvidencePoint.x
                var maxX = firstEvidencePoint.x
                var minY = firstEvidencePoint.y
                var maxY = firstEvidencePoint.y
                for point in plyEvidence.sectionPointsMM.dropFirst() {
                    minX = Swift.min(minX, point.x)
                    maxX = Swift.max(maxX, point.x)
                    minY = Swift.min(minY, point.y)
                    maxY = Swift.max(maxY, point.y)
                }
                points.append(contentsOf: [
                    Point2D(x: minX, y: minY),
                    Point2D(x: maxX, y: minY),
                    Point2D(x: maxX, y: maxY),
                    Point2D(x: minX, y: maxY)
                ])
            } else {
                for segment in plyEvidence.segments {
                    points.append(Point2D(x: segment.start.x, y: segment.start.y))
                    points.append(Point2D(x: segment.end.x, y: segment.end.y))
                }
            }
        }

        if points.isEmpty, let floor = snapshot.floor {
            points = [
                floor.min,
                Point2D(x: floor.max.x, y: floor.min.y),
                floor.max,
                Point2D(x: floor.min.x, y: floor.max.y)
            ]
        }
        return FloorGeometry.enclosing(points)
    }
}

#endif
