#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct PlanOpsisMobileApp: App {
    var body: some Scene {
        WindowGroup {
            PlanOpsisLaunchGate()
                .tint(.accentColor)
        }
    }
}

/// A deliberately short launch gate. The real root view is constructed immediately behind it, so
/// project/store initialization happens during the intro instead of after a decorative splash.
private struct PlanOpsisLaunchGate: View {
    @State private var isPresentingIntro = true

    var body: some View {
        ZStack {
            PlanOpsisRootView()
                .opacity(isPresentingIntro ? 0 : 1)
                .allowsHitTesting(!isPresentingIntro)

            if isPresentingIntro {
                PlanOpsisLaunchView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(1)
            }
        }
        .background(PlanOpsisPalette.workspace)
        .task {
            guard isPresentingIntro else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.28)) {
                isPresentingIntro = false
            }
        }
    }
}

private struct PlanOpsisLaunchView: View {
    var body: some View {
        ZStack {
            PlanOpsisPalette.workspace
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                        .frame(width: 78, height: 78)
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(.primary)
                }

                VStack(spacing: 5) {
                    Text("PlanOpsis")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .tracking(-0.7)
                    Text("Spatial evidence → parametric design")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 3)
            }
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PlanOpsis loading")
    }
}

enum PlanOpsisViewMode: String, CaseIterable, Identifiable {
    case capture = "Scan"
    case ply = "PLY"
    case plan = "Plan"
    case model = "3D"
    case dxf = "DXF"
    case survey = "Survey"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .capture: return "viewfinder"
        case .ply: return "point.3.connected.trianglepath.dotted"
        case .plan: return "square.split.2x2"
        case .model: return "cube.transparent"
        case .dxf: return "doc.text"
        case .survey: return "ruler"
        }
    }
}

struct PlanOpsisRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = PlanOpsisMobileStore()
    @StateObject private var captureService = RoomPlanCaptureService()
    @State private var mode: PlanOpsisViewMode = .capture
    @State private var showingInspector = false
    @State private var showingDXFImporter = false
    @State private var showingExporter = false
    @State private var showingDXFReview = false
    @State private var exportDocument = ArchitecturalExchangeTextDocument()
    @State private var exportFormat: ArchitecturalExchangeFormat = .dxf

    var body: some View {
        NavigationStack {
            workspace
                .background(PlanOpsisPalette.workspace)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !captureService.isStructureCaptureActive {
                        workspaceHeader
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !captureService.isStructureCaptureActive {
                        if #available(iOS 26.0, *) {
                            GlassEffectContainer(spacing: 8) {
                                bottomChrome
                            }
                        } else {
                            bottomChrome
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showingInspector) {
                    NavigationStack {
                        InspectorView(store: store)
                            .navigationTitle(inspectorTitle)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingInspector = false }
                                }
                            }
                    }
                    .presentationDetents([.height(340), .medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showingDXFReview) {
                    DXFReadinessSheet(report: store.dxfReadiness)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(isPresented:$store.showSurveyImportReview) { SurveyExchangeReviewView(store:store) }
                .fileImporter(isPresented: $showingDXFImporter, allowedContentTypes: [.planOpsisDXF, .plainText]) { result in
                    do {
                        let url = try result.get()
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        store.importDXF(data: try Data(contentsOf: url))
                        mode = store.project == nil ? .dxf : .plan
                    } catch {
                        store.statusMessage = "DXF import failed: \(error.localizedDescription)"
                    }
                }
                // One presentation host: stacking fileExporter modifiers suppresses
                // the first format's save picker on the tested iOS runtime.
                .fileExporter(
                    isPresented: $showingExporter,
                    document: exportDocument,
                    contentType: exportFormat.contentType,
                    defaultFilename: exportFormat.filename
                ) { result in
                    if case .failure(let error) = result {
                        store.statusMessage = "\(exportFormat.label) export failed: \(error.localizedDescription)"
                    } else {
                        store.statusMessage = exportFormat == .dxf
                            ? "Architectural DXF exported in millimetres."
                            : "IFC4 semantic model exported with stable PlanOpsis references."
                    }
                }
                .onReceive(captureService.$structureSnapshot.compactMap { $0 }) { snapshot in
                    store.importStructureSnapshot(snapshot)
                    mode = .plan
                }
                .onChange(of: captureService.isStructureCaptureActive) { _, active in
                    UIApplication.shared.isIdleTimerDisabled = active
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active, captureService.isStructureCaptureActive else { return }
                    // RoomPlan requires a continuous AR session for multi-room alignment. Rather
                    // than keep camera/Metal resources alive in the background with invalid tracking,
                    // cancel the in-progress structure and require a clean restart on return.
                    captureService.cancelStructure()
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                .onDisappear {
                    captureService.cancelStructure()
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }


    private var bottomChrome: some View {
        VStack(spacing: 8) {
            if mode != .capture, store.project != nil {
                contextualToolDock
            }
            if let message = store.statusMessage {
                statusChip(message)
            }
            modeDock
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var workspace: some View {
        switch mode {
        case .capture:
            CaptureView(
                service: captureService,
                loadSingleMock: {
                    store.loadMock()
                    mode = .plan
                },
                loadMultiRoomMock: {
                    store.loadMultiRoomMock()
                    mode = .plan
                }
            )
        case .ply:
            PLYImportView(model: store.plyImportModel) { reconstruction in
                store.importPLYReconstruction(reconstruction)
                if store.project != nil {
                    mode = .plan
                }
            }
        case .survey:
            SurveyWorkspaceView(store: store)
        case .plan:
            if store.project != nil {
                FloorPlanView(
                    fitIdentity: store.planFitIdentity,
                    snapshot: store.displayGeometry,
                    components: store.displayComponents,
                    annotations: store.planAnnotations,
                    plyEvidence: store.activePLYEvidence,
                    showPLYEvidence: store.showPLYEvidenceOverlay,
                    onTogglePLYEvidence: { store.showPLYEvidenceOverlay.toggle() },
                    selectedID: store.selectedID,
                    selectedIDs: store.selectedIDs,
                    editableWall: store.selectedWall,
                    editableComponent: store.selectedComponent,
                    directEditingEnabled: store.representationMode == .semanticObservations && store.physicalEditDraft == nil,
                    gridEnabled: store.gridEnabled,
                    gridSpacingMM: store.gridSpacingMM,
                    onSelect: store.select,
                    onMoveWallStart: store.moveSelectedWallStart,
                    onMoveWallEnd: store.moveSelectedWallEnd,
                    onMoveWallThickness: store.moveSelectedWallThicknessGrip,
                    onSetWallLength: store.setSelectedWallLength,
                    onSetWallDeltaX: store.setSelectedWallDeltaX,
                    onSetWallDeltaY: store.setSelectedWallDeltaY,
                    onMoveComponent: store.moveSelectedComponent,
                    onSetComponentRotationRadians: store.setSelectedComponentRotationRadians,
                    onEndInteractiveEdit: store.endInteractiveEdit,
                    creationTool: store.creationTool,
                    componentCreationTool: store.componentCreationTool,
                    pendingWallStart: store.pendingWallStart,
                    onPlanTap: store.handlePlanTap
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                emptyProject
            }
        case .model:
            if store.project != nil {
                Room3DView(
                    snapshot: store.displayGeometry,
                    components: store.displayComponents,
                    selectedID: store.selectedID,
                    selectedIDs: store.selectedIDs,
                    onSelect: store.select
                )
            } else {
                emptyProject
            }
        case .dxf:
            if !store.dxfPreview.primitives.isEmpty {
                DXFPreviewView(snapshot: store.dxfPreview)
            } else {
                ContentUnavailableView(
                    "No DXF drawing",
                    systemImage: "doc.text",
                    description: Text("Scan a room, open a project, or import DXF geometry.")
                )
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("PlanOpsis")
                    .font(.headline.weight(.semibold))
                    .tracking(-0.2)
                Text(workspaceSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if store.project != nil, mode != .capture, mode != .ply {
                PlanOpsisIconButton(
                    systemName: "slider.horizontal.3",
                    accessibilityLabel: "Inspector"
                ) {
                    showingInspector = true
                }
            }

            Menu {
                if store.project != nil {
                    Button("Show all rooms") { store.focusRoom(nil) }
                    if store.rooms.count > 1 {
                        ForEach(Array(store.rooms.enumerated()), id: \.element.id) { index, room in
                            Button("Room \(index + 1)") { store.focusRoom(room.id) }
                        }
                        Divider()
                    }
                    Button("Import DXF") { showingDXFImporter = true }
                    Button("Export DXF") { prepareDXFExport() }
                        .disabled(!store.canExportDXF)
                    Button("Export IFC4") { prepareIFC4Export() }
                    Divider()
                    Button("Save project", action: store.save)
                    Button("Close project", action: store.closeProject)
                    Button("Reopen project", action: store.reopen)
                } else {
                    Button("Import DXF") { showingDXFImporter = true }
                    Button("Reopen project", action: store.reopen)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .planOpsisGlassButton()
            .accessibilityLabel("Project menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .planOpsisLiquidSurface(cornerRadius: 18)
    }

    private var contextualToolDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            representationMenu

            if mode == .plan, store.representationMode == .semanticObservations {
                PlanOpsisIconButton(
                    systemName: "arrow.uturn.backward",
                    accessibilityLabel: store.undoLabel,
                    action: store.undo
                )
                .disabled(!store.canUndo)

                PlanOpsisIconButton(
                    systemName: "arrow.uturn.forward",
                    accessibilityLabel: store.redoLabel,
                    action: store.redo
                )
                .disabled(!store.canRedo)

                PlanOpsisToggleButton(
                    title: "Multi",
                    systemName: "checkmark.circle",
                    isOn: store.multiSelectEnabled
                ) {
                    store.setMultiSelectEnabled(!store.multiSelectEnabled)
                }

                Menu {
                    Section("Architecture") {
                    Button("Wall") { store.beginCreation(.wall) }

                    Menu("Door") {
                        Button("Single hinged") { store.beginDoorCreation(.singleHinged) }
                        Button("Double hinged") { store.beginDoorCreation(.doubleHinged) }
                        Button("Sliding") { store.beginDoorCreation(.sliding) }
                        Button("Pocket") { store.beginDoorCreation(.pocket) }
                    }

                    Menu("Window") {
                        Button("Fixed") { store.beginWindowCreation(.fixed) }
                        Button("Single casement") { store.beginWindowCreation(.singleCasement) }
                        Button("Double casement") { store.beginWindowCreation(.doubleCasement) }
                        Button("Sliding") { store.beginWindowCreation(.sliding) }
                    }

                    Button("Opening") { store.beginCreation(.opening) }
                    }
                    Section("Structure") {
                        Button("Column") { store.beginComponentCreation(.column) }
                        Button("Beam") { store.beginComponentCreation(.beam) }
                    }
                    Section("Furniture") {
                            Button("Bed") { store.beginComponentCreation(.bed) }
                            Button("Table") { store.beginComponentCreation(.table) }
                            Button("Chair") { store.beginComponentCreation(.chair) }
                            Button("Sofa") { store.beginComponentCreation(.sofa) }
                        }
                        Section("Sanitary") {
                            Button("WC") { store.beginComponentCreation(.wc) }
                            Button("Sink") { store.beginComponentCreation(.sink) }
                        }
                    Section("Documentation") {
                        Toggle("Dimensions", isOn: $store.showDimensions)
                        Toggle("Opening widths", isOn: $store.showOpeningWidths)
                        Toggle("Room text", isOn: $store.showRoomText)
                        Button("Drawing preview") { mode = .dxf }
                    }

                    if store.creationTool != nil || store.componentCreationTool != nil {
                        Divider()
                        Button("Cancel add tool", role: .cancel, action: store.cancelCreation)
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 34)
                }
                .planOpsisGlassProminentButton(active: store.creationTool != nil || store.componentCreationTool != nil)
                .accessibilityLabel("Add architectural object")

                if !store.selectedIDs.isEmpty {
                    if store.selectedIDs.count == 1 {
                        PlanOpsisIconButton(
                            systemName: "plus.square.on.square",
                            accessibilityLabel: "Duplicate selected object",
                            action: store.duplicateSelectedObject
                        )
                    }

                    if store.selectedComponent != nil {
                        PlanOpsisIconButton(
                            systemName: "rotate.right",
                            accessibilityLabel: "Rotate selected component 90 degrees"
                        ) {
                            store.rotateSelectedComponent(byDegrees: 90)
                        }
                    }

                    if store.canMirrorSelectedDoor {
                        Button {
                            store.mirrorSelectedDoorHanding()
                        } label: {
                            Label("Mirror", systemImage: "arrow.left.and.right")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .frame(height: 34)
                        }
                        .planOpsisGlassProminentButton(active: true)
                        .accessibilityLabel("Mirror selected door handing")
                    }

                    if store.selectedComponentCount >= 1 {
                        Menu {
                            if store.canAlignSelection {
                                Section("Align") {
                                    Button("Left") { store.alignSelection(.left) }
                                    Button("Center X") { store.alignSelection(.centerX) }
                                    Button("Right") { store.alignSelection(.right) }
                                    Button("Bottom") { store.alignSelection(.bottom) }
                                    Button("Center Y") { store.alignSelection(.centerY) }
                                    Button("Top") { store.alignSelection(.top) }
                                }
                            }
                            if store.canDistributeSelection {
                                Section("Distribute") {
                                    Button("Horizontal") { store.distributeSelection(.horizontal) }
                                    Button("Vertical") { store.distributeSelection(.vertical) }
                                }
                            }
                            Section("Array") {
                                Picker("Count", selection: $store.arrayCount) {
                                    ForEach(2...8, id: \.self) { Text("×\($0)").tag($0) }
                                }
                                Picker("Step", selection: $store.arrayStepMM) {
                                    Text("250 mm").tag(250.0)
                                    Text("500 mm").tag(500.0)
                                    Text("1000 mm").tag(1000.0)
                                    Text("2000 mm").tag(2000.0)
                                }
                                Button("Array X") { store.arraySelection(.horizontal) }
                                    .disabled(!store.canArraySelection)
                                Button("Array Y") { store.arraySelection(.vertical) }
                                    .disabled(!store.canArraySelection)
                            }
                        } label: {
                            Image(systemName: "align.horizontal.left")
                                .frame(width: 36, height: 34)
                        }
                        .planOpsisGlassButton()
                        .accessibilityLabel("Align distribute and array tools")
                    }

                    PlanOpsisIconButton(
                        systemName: "trash",
                        accessibilityLabel: store.selectedIDs.count == 1 ? "Delete selected object" : "Delete selected objects",
                        role: .destructive,
                        action: store.deleteSelectedObject
                    )
                }

                PlanOpsisToggleButton(
                    title: "Ortho",
                    systemName: "angle",
                    isOn: store.orthoEnabled
                ) {
                    store.orthoEnabled.toggle()
                }

                PlanOpsisToggleButton(
                    title: "Grid",
                    systemName: "grid",
                    isOn: store.gridEnabled
                ) {
                    store.gridEnabled.toggle()
                }
            }

            if mode == .dxf {
                Button {
                    showingDXFReview = true
                } label: {
                    Image(systemName: store.dxfReadiness.isProfessionalReady ? "checkmark.seal" : "exclamationmark.triangle")
                        .frame(width: 36, height: 34)
                }
                .planOpsisGlassButton()
                .accessibilityLabel(store.dxfReadinessLabel)

                Button(action: prepareDXFExport) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 36, height: 34)
                }
                .planOpsisGlassProminentButton(active: true)
                .disabled(!store.canExportDXF)
                .accessibilityLabel("Export DXF")
            }

            Spacer(minLength: 4)

            if store.rooms.count > 1, mode != .dxf {
                roomMenu
            }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .planOpsisLiquidSurface(cornerRadius: 18)
        .accessibilityLabel("Plan editing tools")
    }

    private var modeDock: some View {
        HStack(spacing: 4) {
            ForEach(PlanOpsisViewMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                        Text(item.rawValue)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if mode == item {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .padding(4)
        .planOpsisLiquidSurface(cornerRadius: 20)
    }

    private var representationMenu: some View {
        Menu {
            Button { store.representationMode = .semanticObservations } label: {
                if store.representationMode == .semanticObservations {
                    Label("Observed", systemImage: "checkmark")
                } else {
                    Text("Observed")
                }
            }
            Button { store.representationMode = .reconciledPhysical } label: {
                if store.representationMode == .reconciledPhysical {
                    Label("Reconciled", systemImage: "checkmark")
                } else {
                    Text("Reconciled")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                Text(store.representationMode == .semanticObservations ? "Observed" : "Reconciled")
                    .font(.caption.weight(.semibold))
            }
            .frame(height: 34)
            .padding(.horizontal, 8)
        }
        .planOpsisGlassButton()
        .accessibilityLabel("Geometry representation")
    }

    private var roomMenu: some View {
        Menu {
            Button { store.focusRoom(nil) } label: {
                if store.focusedRoomID == nil { Label("All rooms", systemImage: "checkmark") }
                else { Text("All rooms") }
            }
            ForEach(Array(store.rooms.enumerated()), id: \.element.id) { index, room in
                Button { store.focusRoom(room.id) } label: {
                    if store.focusedRoomID == room.id { Label("Room \(index + 1)", systemImage: "checkmark") }
                    else { Text("Room \(index + 1)") }
                }
            }
        } label: {
            Image(systemName: "rectangle.3.group")
                .frame(width: 36, height: 34)
        }
        .planOpsisGlassButton()
        .accessibilityLabel("Room focus")
    }

    private func statusChip(_ message: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .planOpsisLiquidSurface(cornerRadius: 15)
    }

    private var workspaceSubtitle: String {
        if captureService.isStructureCaptureActive { return "LiDAR capture" }
        if mode == .ply { return "PLY → section → semantic walls" }
        guard store.project != nil else { return "LiDAR / PLY → semantic model → DXF / IFC4" }
        if let room = store.focusedRoom { return store.roomLabel(room.id) }
        if store.rooms.count > 1 { return "\(store.rooms.count) rooms · \(mode.rawValue)" }
        return "Architectural model · \(mode.rawValue)"
    }

    private var inspectorTitle: String {
        if store.selectedWall != nil { return "Wall" }
        if let opening = store.selectedOpening { return opening.kind.rawValue.capitalized }
        if let component = store.selectedComponent { return component.kind.displayName }
        return "Properties"
    }

    private func prepareDXFExport() {
        guard let text = store.exportDXFText(), !text.isEmpty else {
            showingDXFReview = true
            return
        }
        exportFormat = .dxf
        exportDocument = ArchitecturalExchangeTextDocument(text: text)
        showingExporter = true
    }

    private func prepareIFC4Export() {
        guard let text = store.exportIFC4Text(), !text.isEmpty else { return }
        exportFormat = .ifc
        exportDocument = ArchitecturalExchangeTextDocument(text: text)
        showingExporter = true
    }

    private var emptyProject: some View {
        ContentUnavailableView(
            "No project",
            systemImage: "square.dashed",
            description: Text("Scan a room, reconstruct a PLY, import a DXF, or reopen a saved PlanOpsis project.")
        )
    }
}

private struct DXFReadinessSheet: View {
    let report: ArchitecturalSurveyReadinessReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Drawing status") {
                    LabeledContent("Rooms", value: "\(report.roomCount)")
                    LabeledContent("Closed rooms", value: "\(report.closedRoomCount)/\(report.roomCount)")
                    LabeledContent("Walls", value: "\(report.wallCount)")
                    LabeledContent("Doors / windows / openings", value: "\(report.openingCount)")
                    LabeledContent("Low/unknown confidence", value: "\(report.lowConfidenceElementCount)")
                }

                Section("DXF issue check") {
                    if report.issues.isEmpty {
                        Label("Ready for architectural DXF export", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(report.issues) { issue in
                            Label {
                                Text(issue.message)
                            } icon: {
                                Image(systemName: icon(for: issue.severity))
                                    .foregroundStyle(color(for: issue.severity))
                            }
                        }
                    }
                }

                Section {
                    Text(report.errorCount == 0
                         ? "Warnings do not alter geometry. Verify flagged measurements before issuing the drawing."
                         : "DXF export is blocked until the errors above are corrected so PlanOpsis does not issue known-invalid architecture.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PlanOpsisPalette.workspace)
            .navigationTitle(report.isProfessionalReady ? "DXF Ready" : "Drawing Review")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func icon(for severity: SurveyReadinessSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for severity: SurveyReadinessSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

enum PlanOpsisPalette {
    static let workspace = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
            : UIColor(red: 0.965, green: 0.965, blue: 0.955, alpha: 1)
    })
}

private struct PlanOpsisLiquidSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    func planOpsisLiquidSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(PlanOpsisLiquidSurfaceModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func planOpsisGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func planOpsisGlassProminentButton(active: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if active {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if active {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

private struct PlanOpsisIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 34)
        }
        .planOpsisGlassButton()
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PlanOpsisToggleButton: View {
    let title: String
    let systemName: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(height: 34)
            .padding(.horizontal, 7)
        }
        .planOpsisGlassProminentButton(active: isOn)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
#endif
