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
    let onMoveWallStart: (Point2D) -> Void
    let onMoveWallEnd: (Point2D) -> Void
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
    let onPlanTap: (Point2D, UUID?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let viewport = PlanViewport(transform: camera ?? fittedCamera(size: size), size: size)
            ZStack {
                Canvas { context, _ in
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

                }
                .contentShape(Rectangle())
                // v9.9.3: taps select/place; drags navigate the drawing. Keeping
                // these as distinct gestures avoids the old zero-distance drag
                // recognizer that made object selection feel delayed and fought
                // with pinch gestures.
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("plan-space"))
                        .onEnded { value in
                            guard !isPinching, !isPanning else { return }
                            let hit = hitTest(value.location, viewport: viewport)
                            if creationTool != nil || componentCreationTool != nil {
                                onPlanTap(viewport.plan(value.location), hit)
                            } else {
                                onSelect(hit)
                            }
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("plan-space"))
                        .onChanged { value in
                            guard !isPinching else { return }
                            let base = panBaseCamera ?? viewport.transform
                            if panBaseCamera == nil { panBaseCamera = base }
                            isPanning = true
                            camera = base.panned(byScreenDX: Double(value.translation.width), dy: Double(value.translation.height))
                        }
                        .onEnded { _ in
                            panBaseCamera = nil
                            DispatchQueue.main.async { isPanning = false }
                        }
                )

                if directEditingEnabled, creationTool == nil, componentCreationTool == nil {
                    if let wall = editableWall {
                        wallHandles(wall: wall, viewport: viewport)
                        wallDimensionEditor(wall: wall)
                    } else if let component = editableComponent {
                        componentHandles(component: component, viewport: viewport)
                    }
                }

                if creationTool != nil || componentCreationTool != nil {
                    VStack {
                        HStack {
                            Label(creationPrompt, systemImage: "cursorarrow.click")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .planOpsisLiquidSurface(cornerRadius: 16)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }

                zoomControls(size: size, current: viewport.transform)
                if plyEvidence != nil { evidenceControl }

                if let start = pendingWallStart {
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
        if let componentCreationTool { return "Place \(componentCreationTool.displayName)" }
        if let creationTool {
            if creationTool == .wall && pendingWallStart != nil { return "Tap wall end" }
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

        Text("L \(wall.length.formatted(.number.precision(.fractionLength(0...1)))) mm")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(uiColor: .systemBackground).opacity(0.92), in: Capsule())
            .position(dimensionMid)
            .allowsHitTesting(false)

        editHandle(label: "S", color: .accentColor, position: start) { point in
            onMoveWallStart(viewport.plan(point))
        }
        editHandle(label: "E", color: .accentColor, position: end) { point in
            onMoveWallEnd(viewport.plan(point))
        }
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
