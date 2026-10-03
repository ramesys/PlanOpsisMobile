#if os(iOS)
import SwiftUI

/// v12.4 Sheets tab: the project's drawing set (plan, schedules, interior elevations, sections) as
/// printable sheets, the schedules as native tables, and the drawing-set settings.
struct SheetsWorkspaceView: View {
    enum Content: String, CaseIterable, Identifiable {
        case sheets = "Sheets"
        case schedules = "Schedules"
        var id: String { rawValue }
    }

    @ObservedObject var store: PlanOpsisMobileStore
    let onExportPDF: () -> Void
    let onExportCSV: () -> Void
    let onDrawSection: () -> Void

    @State private var content: Content = .sheets
    @State private var showingSettings = false
    @State private var openSheet: DrawingSheet?

    var body: some View {
        Group {
            if let set = store.drawingSet, !set.sheets.isEmpty {
                VStack(spacing: 8) {
                    header(set)
                        .padding(.horizontal, 12)
                    if !set.notes.isEmpty {
                        Label(set.notes.joined(separator: " "), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 16)
                    }
                    switch content {
                    case .sheets: sheetList(set)
                    case .schedules: ScheduleTablesView(tables: set.tables)
                    }
                }
                .fullScreenCover(item: $openSheet) { sheet in
                    SheetDetailView(sheets: set.sheets, initial: sheet) { openSheet = nil }
                }
            } else {
                ContentUnavailableView(
                    "No drawings yet",
                    systemImage: "doc.richtext",
                    description: Text("Scan a room or open a project: its plan, schedules, interior elevations and sections are laid out on sheets here.")
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            DocumentationSettingsView(store: store) {
                showingSettings = false
                onDrawSection()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func header(_ set: DrawingSet) -> some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $content) {
                ForEach(Content.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer(minLength: 4)

            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34)
            }
            .planOpsisGlassButton()
            .accessibilityLabel("Drawing set settings")

            Menu {
                Button { onExportPDF() } label: { Label("Drawing set (PDF)", systemImage: "doc.richtext") }
                Button { onExportCSV() } label: { Label("Schedules (CSV)", systemImage: "tablecells") }
            } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 34, height: 34)
            }
            .planOpsisGlassProminentButton(active: true)
            .accessibilityLabel("Export drawings")
        }
    }

    private func sheetList(_ set: DrawingSet) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(set.sheets) { sheet in
                    Button { openSheet = sheet } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            SheetCanvas(sheet: sheet)
                                .aspectRatio(sheet.width / sheet.height, contentMode: .fit)
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                            HStack {
                                Text("\(sheet.number) · \(sheet.title)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sheet.paper.title)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sheet \(sheet.number), \(sheet.title)")
                    .accessibilityHint("Opens the sheet to zoom in")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

/// Draws a sheet's paper-millimetre primitives into the view, fitted with a white page.
struct SheetCanvas: View {
    let sheet: DrawingSheet
    /// Paper-to-view transform; nil fits the whole sheet.
    var camera: PlanViewTransform?

    var body: some View {
        Canvas { context, size in
            let transform = camera ?? Self.fitted(sheet, size: size)
            func screen(_ p: Point2D) -> CGPoint {
                let s = transform.screen(p, viewWidth: Double(size.width), viewHeight: Double(size.height))
                return CGPoint(x: s.x, y: s.y)
            }
            let k = CGFloat(transform.scale)
            let page = CGRect(origin: screen(Point2D(x: 0, y: sheet.height)), size: CGSize(width: sheet.width * transform.scale, height: sheet.height * transform.scale))
            context.fill(Path(page), with: .color(.white))
            for primitive in sheet.primitives {
                Self.draw(primitive, k: k, screen: screen, in: &context)
            }
        }
        .background(Color(white: 0.86))
    }

    static func fitted(_ sheet: DrawingSheet, size: CGSize) -> PlanViewTransform {
        let scale = min(Double(size.width) / sheet.width, Double(size.height) / sheet.height) * 0.98
        return PlanViewTransform(scale: scale, modelCenter: Point2D(x: sheet.width / 2, y: sheet.height / 2))
    }

    static func draw(_ primitive: SheetPrimitive, k: CGFloat, screen: (Point2D) -> CGPoint, in context: inout GraphicsContext) {
        let ink = Color(white: primitive.gray)
        let style = StrokeStyle(lineWidth: max(0.35, CGFloat(primitive.weight) * k), lineCap: .round, lineJoin: .round, dash: primitive.dash.map { CGFloat($0) * k })
        func finish(_ path: Path, closed: Bool) {
            if closed, let color = primitive.fillColor { context.fill(path, with: .color(Color(red: color.red, green: color.green, blue: color.blue))) }
            else if let fill = primitive.fill, closed { context.fill(path, with: .color(Color(white: fill))) }
            if primitive.weight > 0 { context.stroke(path, with: .color(ink), style: style) }
        }
        switch primitive.shape {
        case let .line(a, b):
            var path = Path(); path.move(to: screen(a)); path.addLine(to: screen(b)); finish(path, closed: false)
        case let .polyline(points, closed):
            guard let first = points.first else { return }
            var path = Path(); path.move(to: screen(first))
            for p in points.dropFirst() { path.addLine(to: screen(p)) }
            if closed { path.closeSubpath() }
            finish(path, closed: closed)
        case let .polygon(points):
            guard let first = points.first else { return }
            var path = Path(); path.move(to: screen(first))
            for p in points.dropFirst() { path.addLine(to: screen(p)) }
            path.closeSubpath()
            finish(path, closed: true)
        case let .circle(center, radius):
            let c = screen(center), r = CGFloat(radius) * k
            finish(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), closed: true)
        case let .arc(center, radius, start, end):
            // Sampled in paper coordinates (counter-clockwise), so the Y flip needs no arc-direction rules.
            var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
            if sweep <= 0 { sweep += 2 * .pi }
            let steps = max(8, Int(sweep / (.pi / 24)))
            var path = Path()
            for i in 0...steps {
                let a = start + sweep * Double(i) / Double(steps)
                let p = screen(Point2D(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            finish(path, closed: false)
        case let .text(string, at, height, rotation, anchor, bold):
            let size = CGFloat(height / 0.72) * k
            guard size >= 1.5 else { return }
            let text = Text(string).font(.system(size: size, weight: bold ? .bold : .regular)).foregroundStyle(ink)
            var layer = context
            let origin = screen(at)
            layer.translateBy(x: origin.x, y: origin.y)
            layer.rotate(by: .radians(-rotation))
            let unit: UnitPoint
            switch anchor {
            case .left: unit = UnitPoint(x: 0, y: 0.8)
            case .center: unit = UnitPoint(x: 0.5, y: 0.8)
            case .right: unit = UnitPoint(x: 1, y: 0.8)
            }
            layer.draw(text, at: .zero, anchor: unit)
        }
    }
}

/// Full-screen sheet with pinch zoom, pan and paging between sheets.
struct SheetDetailView: View {
    let sheets: [DrawingSheet]
    let onClose: () -> Void
    @State private var index: Int
    @State private var camera: PlanViewTransform?
    @State private var base: PlanViewTransform?

    init(sheets: [DrawingSheet], initial: DrawingSheet, onClose: @escaping () -> Void) {
        self.sheets = sheets
        self.onClose = onClose
        _index = State(initialValue: sheets.firstIndex { $0.id == initial.id } ?? 0)
    }

    var body: some View {
        let sheet = sheets[min(index, sheets.count - 1)]
        NavigationStack {
            GeometryReader { proxy in
                let size = proxy.size
                let fit = SheetCanvas.fitted(sheet, size: size)
                let current = camera ?? fit
                SheetCanvas(sheet: sheet, camera: current)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let start = base ?? current
                                if base == nil { base = start }
                                camera = start.panned(byScreenDX: Double(value.translation.width), dy: Double(value.translation.height))
                            }
                            .onEnded { _ in base = nil }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let start = base ?? current
                                if base == nil { base = start }
                                let target = min(fit.scale * 12, max(fit.scale * 0.8, start.scale * Double(value.magnification)))
                                camera = start.zoomed(by: target / start.scale, about: Point2D(x: Double(value.startLocation.x), y: Double(value.startLocation.y)),
                                                      viewWidth: Double(size.width), viewHeight: Double(size.height))
                            }
                            .onEnded { _ in base = nil }
                    )
                    .onTapGesture(count: 2) { camera = nil }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("\(sheet.number) · \(sheet.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                        .accessibilityLabel("Previous sheet")
                    Spacer()
                    Text("Sheet \(sheet.number) of \(sheets.count) · double-tap to fit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= sheets.count - 1)
                        .accessibilityLabel("Next sheet")
                }
            }
        }
    }

    private func step(_ delta: Int) {
        index = max(0, min(sheets.count - 1, index + delta))
        camera = nil
    }
}

/// The schedules as native, scrollable tables.
struct ScheduleTablesView: View {
    let tables: [ProjectSchedules.Table]

    var body: some View {
        if tables.isEmpty {
            ContentUnavailableView("No schedules", systemImage: "tablecells", description: Text("Rooms, doors and windows appear here once the project has them."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(tables, id: \.title) { table in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(table.title).font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                                    GridRow {
                                        ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                                            Text(column).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Divider()
                                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                        GridRow {
                                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                                Text(cell)
                                                    .font(.callout.monospacedDigit())
                                                    .gridColumnAlignment(table.numericColumns.contains(column) ? .trailing : .leading)
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Title block, paper, scales, contents and section lines of the drawing set.
struct DocumentationSettingsView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    let onDrawSection: () -> Void
    @Environment(\.dismiss) private var dismiss

    private func binding<T>(_ keyPath: WritableKeyPath<DocumentationSettings, T>, label: String = "Drawing settings") -> Binding<T> {
        Binding(get: { store.documentationSettings[keyPath: keyPath] }, set: { value in store.updateDocumentation(label) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title block") {
                    TextField("Project name", text: Binding(get: { store.project?.name ?? "" }, set: { store.renameProject($0) }))
                    TextField("Drawn by", text: binding(\.author))
                    TextField("Client / company", text: binding(\.company))
                    TextField("Site address", text: binding(\.siteAddress))
                    TextField("Revision", text: binding(\.revision))
                }
                Section("Paper and scale") {
                    Picker("Paper", selection: binding(\.paper)) {
                        ForEach(PaperSize.allCases) { Text("\($0.title) landscape").tag($0) }
                    }
                    Picker("Plan scale", selection: binding(\.planScale)) {
                        Text("Fit automatically").tag(Int?.none)
                        ForEach(DocumentationSettings.standardScales, id: \.self) { Text("1:\($0)").tag(Int?.some($0)) }
                    }
                    Picker("Elevations and sections", selection: binding(\.elevationScale)) {
                        Text("Fit automatically").tag(Int?.none)
                        ForEach(DocumentationSettings.standardScales, id: \.self) { Text("1:\($0)").tag(Int?.some($0)) }
                    }
                    if let set = store.drawingSet {
                        LabeledContent("Plan is drawn at", value: "1:\(set.planScale)")
                    }
                }
                Section("Contents") {
                    Toggle("Door and window tags on the plan", isOn: $store.showTags)
                    Toggle("Area plan", isOn: binding(\.includeAreaPlan))
                    Toggle("Reflected ceiling plan", isOn: binding(\.includeCeilingPlan))
                    Toggle("Schedules", isOn: binding(\.includeSchedules))
                    Toggle("Quantities and finishes", isOn: binding(\.includeQuantities))
                    Toggle("Interior elevations", isOn: binding(\.includeElevations))
                    Toggle("Sections", isOn: binding(\.includeSections))
                }
                Section {
                    ForEach(store.documentationSettings.sections) { section in
                        HStack {
                            Text("Section \(section.label)–\(section.label)")
                            Spacer()
                            Button {
                                store.flipSection(section.id)
                            } label: {
                                Label("Flip view", systemImage: "arrow.left.arrow.right")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Flip the direction section \(section.label) looks")
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.deleteSection(section.id) }
                        }
                    }
                    Button {
                        onDrawSection()
                    } label: {
                        Label("Draw a section on the plan", systemImage: "line.diagonal")
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Tap where the cut starts and ends on the plan; the section looks to the left of the line. Flip it here.")
                }
            }
            .navigationTitle("Drawing set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
