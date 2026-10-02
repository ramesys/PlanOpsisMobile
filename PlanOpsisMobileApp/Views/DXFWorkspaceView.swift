#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// v12.3 DXF tab: the project's drawing or any DXF opened from Files, in the CAD viewer.
/// Opening a file here only views it; "Import DXF" in the project menu is still the way to edit one.
struct DXFWorkspaceView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    @State private var showingOpener = false
    @State private var showingLayers = false
    @State private var showingNotes = false

    var body: some View {
        Group {
            if let drawing = store.viewerDrawing {
                VStack(spacing: 8) {
                    header(drawing)
                        .padding(.horizontal, 12)
                    CADViewerView(
                        drawing: drawing,
                        hiddenLayers: store.hiddenLayers(for: drawing),
                        onHideLayer: { layer in
                            store.setHiddenLayers(store.hiddenLayers(for: drawing).union([layer]), for: drawing)
                        },
                        onIsolateLayer: { layer in
                            store.setHiddenLayers(Set(drawing.scene.layers.map(\.id)).subtracting([layer]), for: drawing)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .padding(.horizontal, 10)
                }
                .sheet(isPresented: $showingLayers) {
                    CADLayerPanel(
                        drawing: drawing,
                        hidden: Binding(
                            get: { store.hiddenLayers(for: drawing) },
                            set: { store.setHiddenLayers($0, for: drawing) }
                        )
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showingNotes) {
                    CADDrawingNotesView(drawing: drawing)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
            } else {
                ContentUnavailableView {
                    Label("No drawing", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Scan a room or open a project to see its drawing, or open any DXF to view and measure it.")
                } actions: {
                    Button("Open DXF\u{2026}") { showingOpener = true }
                        .planOpsisGlassProminentButton(active: true)
                }
            }
        }
        .overlay {
            if store.isOpeningDrawing {
                ProgressView("Opening drawing\u{2026}")
                    .padding(18)
                    .planOpsisLiquidSurface(cornerRadius: 16)
            }
        }
        .fileImporter(isPresented: $showingOpener, allowedContentTypes: [.planOpsisDXF, .plainText, .data]) { result in
            switch result {
            case let .success(url): store.openDrawing(at: url)
            case let .failure(error): store.statusMessage = "Could not open the drawing: \(error.localizedDescription)"
            }
        }
    }

    private func header(_ drawing: CADViewerDocument) -> some View {
        let hidden = store.hiddenLayers(for: drawing)
        let visibleLayerCount = drawing.scene.layers.filter { $0.itemCount > 0 && !hidden.contains($0.id) }.count
        let usedLayerCount = drawing.scene.layers.filter { $0.itemCount > 0 }.count
        return HStack(spacing: 8) {
            Menu {
                if let project = store.projectDrawing {
                    Button {
                        store.viewerShowsOpenedDrawing = false
                    } label: {
                        Label(project.title, systemImage: drawing.source == .project ? "checkmark" : "square.split.2x2")
                    }
                }
                if let opened = store.openedDrawing {
                    Button {
                        store.viewerShowsOpenedDrawing = true
                    } label: {
                        Label(opened.title, systemImage: drawing.id == opened.id ? "checkmark" : "doc")
                    }
                }
                Divider()
                Button("Open DXF\u{2026}") { showingOpener = true }
                if let opened = store.openedDrawing {
                    Button("Close \(opened.title)", role: .destructive) { store.closeOpenedDrawing() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: drawing.source == .project ? "square.split.2x2" : "doc.text")
                    Text(drawing.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
            }
            .planOpsisGlassButton()
            .accessibilityLabel("Drawing: \(drawing.title)")

            Text(drawing.document.units.symbol)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .accessibilityLabel("Drawing units \(drawing.document.units.symbol)")

            Spacer(minLength: 4)

            if !drawing.scene.diagnostics.summary.isEmpty {
                Button { showingNotes = true } label: {
                    Image(systemName: "info.circle").frame(width: 34, height: 34)
                }
                .planOpsisGlassButton()
                .accessibilityLabel("Drawing notes")
            }

            Button { showingLayers = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.3.layers.3d")
                    Text("\(visibleLayerCount)/\(usedLayerCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
            }
            .planOpsisGlassButton()
            .accessibilityLabel("Layers, \(visibleLayerCount) of \(usedLayerCount) visible")
        }
    }
}

/// Layer list: visibility, isolate, colour and object counts, with search for drawings with many layers.
struct CADLayerPanel: View {
    let drawing: CADViewerDocument
    @Binding var hidden: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var showsEmptyLayers = false

    private var layers: [CADSceneLayer] {
        drawing.scene.layers.filter { layer in
            (showsEmptyLayers || layer.itemCount > 0)
                && (query.isEmpty || layer.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Show all layers") { hidden = [] }
                    Button("Hide all layers") { hidden = Set(drawing.scene.layers.map(\.id)) }
                    Button("Reset to file settings") { hidden = drawing.scene.initiallyHiddenLayers }
                    Toggle("Show empty layers", isOn: $showsEmptyLayers)
                }
                Section("\(layers.count) layer\(layers.count == 1 ? "" : "s")") {
                    ForEach(layers) { entry in
                        row(entry)
                    }
                }
            }
            .searchable(text: $query, prompt: "Find layer")
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ entry: CADSceneLayer) -> some View {
        let isVisible = !hidden.contains(entry.id)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CADCanvasRenderer.displayColor(entry.layer.color, dark: colorScheme == .dark))
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.id)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isVisible ? .primary : .secondary)
                    .lineLimit(1)
                Text(detail(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isVisible ? "eye" : "eye.slash")
                .foregroundStyle(isVisible ? Color.accentColor : .secondary)
                .frame(width: 30)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isVisible { hidden.insert(entry.id) } else { hidden.remove(entry.id) }
        }
        .swipeActions(edge: .trailing) {
            Button("Only") { hidden = Set(drawing.scene.layers.map(\.id)).subtracting([entry.id]) }
                .tint(.accentColor)
        }
        .contextMenu {
            Button("Show only this layer") { hidden = Set(drawing.scene.layers.map(\.id)).subtracting([entry.id]) }
            Button(isVisible ? "Hide" : "Show") {
                if isVisible { hidden.insert(entry.id) } else { hidden.remove(entry.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isVisible ? "Visible" : "Hidden")
        .accessibilityAddTraits(.isButton)
    }

    private func detail(_ entry: CADSceneLayer) -> String {
        var parts = ["\(entry.itemCount) object\(entry.itemCount == 1 ? "" : "s")"]
        if entry.layer.isFrozen { parts.append("frozen in file") } else if !entry.layer.isOn { parts.append("off in file") }
        if case let .hundredthsMM(value) = entry.layer.lineWeight { parts.append(String(format: "%.2f mm", Double(value) / 100)) }
        if entry.layer.lineType.uppercased() != "CONTINUOUS" { parts.append(entry.layer.lineType) }
        return parts.joined(separator: " · ")
    }
}

/// What the reader could not show, so a partial drawing is never mistaken for a complete one.
struct CADDrawingNotesView: View {
    let drawing: CADViewerDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Entities", value: "\(drawing.document.entities.count)")
                    LabeledContent("Drawn objects", value: "\(drawing.scene.items.count)")
                    LabeledContent("Blocks", value: "\(drawing.document.blocks.count)")
                    LabeledContent("Units", value: drawing.document.units.symbol)
                    if let version = drawing.document.version { LabeledContent("DXF version", value: version) }
                }
                Section("Not shown") {
                    ForEach(drawing.scene.diagnostics.summary, id: \.self) { line in
                        Text(line).font(.footnote)
                    }
                }
            }
            .navigationTitle("Drawing notes")
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
