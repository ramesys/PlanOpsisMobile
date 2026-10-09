#if os(iOS)
import Foundation
import SwiftUI

@MainActor
final class PlanOpsisMobileStore: ObservableObject {
    private let storageRoot:URL?
    init(storageRoot:URL?=nil) { self.storageRoot=storageRoot }
    private func projectStore() throws -> ProjectStore {
        guard let storageRoot else { return try ProjectStore.defaultStore() }
        try FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true)
        return ProjectStore(url:storageRoot.appendingPathComponent("project-v2.json"))
    }
    /// v12.2 one file per project; replaces the single project-v2.json slot.
    private func projectLibrary() throws -> ProjectLibrary {
        guard let storageRoot else { return try ProjectLibrary.defaultLibrary() }
        return ProjectLibrary(directory: storageRoot.appendingPathComponent("Projects", isDirectory: true))
    }
    @Published private(set) var libraryEntries: [ProjectLibrary.Entry] = []
    private var autosaveTask: Task<Void, Never>?
    private var lastSavedProject: PlanOpsisProject?
    private var didImportLegacyProject = false
    @Published private(set) var project: PlanOpsisProject?
    @Published private(set) var geometry = ArchitecturalGeometrySnapshot(
        planWallSegments: [],
        wallSolids: [],
        hostedOpenings: [],
        roomFloors: []
    )
    @Published private(set) var physicalGeometry = DisplayGeometrySnapshot.empty
    @Published var representationMode: GeometryRepresentationMode = .semanticObservations { didSet { rederive() } }
    /// v12.1 drawing, annotations and readiness for the current project revision and view settings.
    @Published private(set) var derivation: ProjectDerivation?
    // Selection is published as one atomic UI invalidation in setSelection().
    // Keeping these as two @Published properties caused two full Plan canvas
    // refreshes for every tap on device.
    private(set) var selectedID: UUID?
    private(set) var selectedIDs: Set<UUID> = []
    @Published var multiSelectEnabled: Bool = false
    @Published var arrayCount: Int = 3
    @Published var arrayStepMM: Double = 1_000
    @Published var transformDeltaXMM: Double = 500
    @Published var transformDeltaYMM: Double = 0
    @Published var transformRotationDegrees: Double = 90
    @Published var wallOffsetMM: Double = 200
    /// nil means show the complete multi-room structure.
    @Published var focusedRoomID: UUID? { didSet { rederive() } }
    /// v8.3 drafting aids. These are editor/session state, not architectural persistence.
    @Published var orthoEnabled: Bool = false
    @Published var gridEnabled: Bool = false
    @Published var creationTool: PlanObjectKind?
    @Published var doorCreationOperation: PlanOpsisDoor.Operation = .singleHinged
    @Published var windowCreationOperation: PlanOpsisWindow.Operation = .fixed
    @Published var componentCreationTool: PlanOpsisComponent.Kind?
    @Published private(set) var pendingWallStart: Point2D?
    /// v12.3: first corner of the wall chain being drawn; reaching it again closes the outline.
    private var wallChainStart: Point2D?
    /// Direction of the last drawn wall, used by a typed length without an angle.
    private var lastWallDirection: Point2D?
    /// v12.3 polar tracking: wall directions within a few degrees of a 15° multiple snap to it.
    @Published var polarTrackingEnabled = true
    /// v12.3 object snaps (endpoint, midpoint, intersection, perpendicular…) while drawing and dragging.
    @Published var objectSnapsEnabled = true
    /// v12.3 the DXF opened in the viewer, drawn faded under the plan.
    @Published var showUnderlay = false { didSet { syncProjectUnderlay() } }
    /// Where the DXF underlay sits on the plan.
    @Published private(set) var underlayPlacement = UnderlayPlacement() { didSet { syncProjectUnderlay() } }
    @Published var isMovingUnderlay = false
    /// v12.6 a PDF page under the plan; while loaded it is the underlay shown instead of the DXF.
    @Published private(set) var rasterUnderlay: RasterUnderlay?
    @Published private(set) var rasterPlacement = UnderlayPlacement() { didSet { syncProjectUnderlay() } }
    /// v12.7 the PDF's pages and the page shown (0-based).
    @Published private(set) var rasterPageCount = 1
    @Published private(set) var rasterPageIndex = 0
    /// v12.7 the PDF page's lines in paper millimetres, for snapping and tracing; nil for scanned sheets.
    private var rasterVectors: CADDocument?
    /// Source bytes of the underlays, for another PDF page and for saving with the project.
    private var rasterSource: (data: Data, name: String)?
    private var openedDrawingData: (data: Data, name: String)?
    private var underlayAssetCache: (projectID: UUID, name: String, size: Int, reference: SurveyEvidenceReference)?
    private var isRestoringUnderlay = false
    /// v12.7 the survey compared with the aligned drawing; refreshed after model edits.
    @Published private(set) var deviation: DeviationAnalysis?
    @Published var showDeviation = false
    @Published var showDeviationReport = false
    private var deviationReferenceCache: (key: String, reference: UnderlayTraceResult)?
    /// v12.7 renders a PDF page; injected by the app because PDFKit is not part of the core.
    var pdfPageLoader: ((Data, String, Int) throws -> PDFUnderlayPage)? {
        didSet { if project?.underlay?.format == .pdf, rasterUnderlay == nil { restoreUnderlay() } }
    }
    /// v12.9 straightens (when the flag is set), reads and vectorises a photo of a plan; injected by the
    /// app (Vision, UIKit).
    var photoPlanLoader: ((Data, String, Bool) throws -> PDFUnderlayPage)? {
        didSet { if project?.underlay?.format == .image, rasterUnderlay == nil { restoreUnderlay() } }
    }
    /// What the raster underlay was made from, for saving it with the project.
    private var rasterFormat: ProjectUnderlay.Format = .pdf
    /// v12.10 the photo's plan read as walls, openings, stairs and scale.
    private var photoReading: PlanPhotoReading?
    /// v12.10 the rooms last built from the photo, so a new scale can rebuild them while untouched.
    private var photoBuild: [PlanOpsisRoom] = []
    /// v12.10 what was recognised in the photo, shown for a quick check after building.
    @Published var photoReview: PhotoPlanReview?
    /// v12.6 two-point alignment or scale calibration in progress.
    @Published private(set) var underlayAlignment: UnderlayAlignmentSession?
    /// v12.6 alignment whose scale differs from the drawing's units, waiting for the user's choice.
    @Published var pendingAlignmentScale: Double?
    /// v12.6 tapping between two parallel underlay lines adds a wall of that thickness.
    @Published private(set) var isTracingWalls = false
    /// A plan dimension being edited by value.
    @Published var dimensionEdit: PlanDimensionEdit?
    private var underlayCache: (key: String, scene: CADScene)?
    private var snapperCache: (project: PlanOpsisProject, excluded: Set<UUID>, snapper: PlanObjectSnapper)?
    private var pushPullBase: (project: PlanOpsisProject, wall: PlanOpsisWall)?
    @Published private(set) var pushPullOffset: Double?
    @Published private(set) var importedDXFPreview: DXFPreviewSnapshot?
    @Published private(set) var dxfImportDiagnostics: [DXFImportDiagnostic] = []
    /// v12.3: a DXF opened in the viewer only. It never replaces or edits the project.
    @Published private(set) var openedDrawing: CADViewerDocument?
    /// Whether the DXF tab shows the opened drawing (true) or the project's own drawing.
    @Published var viewerShowsOpenedDrawing = true
    @Published private(set) var isOpeningDrawing = false
    /// Hidden layers per viewer source, so switching drawings keeps each one's layer state.
    @Published var viewerHiddenLayers: [CADViewerDocument.Source: Set<String>] = [:]
    private var projectDrawingCache: (preview: DXFPreviewSnapshot, drawing: CADViewerDocument)?
    @Published private(set) var diagnostics: [RoomPlanAdapter.Diagnostic] = [] { didSet { rederive() } }
    @Published var statusMessage: String?
    @Published var surveyImportProposal:SurveyDXFChangeProposal?
    @Published var showSurveyImportReview=false
    @Published var dxfExportProfile=DXFExportProfile.compatible { didSet { rederive() } }
    /// v12.3 DXF layer names: one layer per IFC class (default) or the CAD discipline layers.
    @Published var dxfLayerNaming = DXFLayerNaming(rawValue: UserDefaults.standard.string(forKey: "PlanOpsis.dxfLayerNaming") ?? "") ?? .ifcClass {
        didSet {
            UserDefaults.standard.set(dxfLayerNaming.rawValue, forKey: "PlanOpsis.dxfLayerNaming")
            projectDrawingCache = nil
        }
    }
    @Published private(set) var physicalEditDraft: PhysicalPartitionEditDraft?
    @Published private(set) var physicalEditPlan: PhysicalPartitionEditPlan?
    @Published private(set) var physicalEditPreviewGeometry: DisplayGeometrySnapshot?
    @Published private(set) var lastPhysicalEditReceipt: PhysicalEditTransactionReceipt?

    /// Session-scoped PLY evidence/reconstruction state. Keeping this outside the transient PLY
    /// workspace view means imported point clouds survive PLY → Plan/3D/DXF → PLY navigation.
    let plyImportModel = PLYImportViewModel()

    private let adapter = RoomPlanAdapter()
    private let geometryEngine = ParametricGeometryEngine()
    private let physicalDisplayEngine = PhysicalDisplayGeometryEngine()
    private let physicalEditEngine = PhysicalPartitionEditTransactionEngine()
    private let editingConstraintEngine = PlanEditingConstraintEngine()
    private let semanticEditingEngine = SemanticObjectEditingEngine()
    private var dxfExchangeEngine: DXFExchangeEngine { DXFExchangeEngine(includeOpeningDimensions:showOpeningWidths,surveyDrawing:dxfExportProfile == .rhinoEditable || (project.map{$0.survey != .empty} ?? false),layerNaming:dxfLayerNaming) }
    private let ifc4ExchangeEngine = IFC4ExchangeEngine()
    @Published var showDimensions = true
    @Published var showRoomText = true
    @Published var showOpeningWidths = false { didSet { rederive() } }
    /// v12.4 door, window and opening marks on the plan.
    @Published var showTags = true { didSet { rederive() } }
    /// v12.4 placing a section line: the first tap sets the start, the second the end.
    @Published private(set) var isPlacingSection = false
    @Published private(set) var pendingSectionStart: Point2D?
    private var drawingSetCache: (project: PlanOpsisProject, representation: GeometryRepresentationMode, set: DrawingSet)?
    /// Keeps the latest PLY plan-section evidence visible under the semantic drawing for direct
    /// scan-vs-reconstruction comparison. This is editor/session state, not architectural state.
    @Published var showPLYEvidenceOverlay = false
    /// Associates session PLY evidence with the semantic project it produced. Raw PLY can remain
    /// available in the PLY workspace, but it must never be overlaid on an unrelated RoomPlan/DXF/
    /// reopened project.
    @Published private(set) var plyEvidenceProjectID: UUID?
    /// Frozen evidence associated with the committed semantic project. This must not point directly
    /// at the mutable PLY import workspace: importing a second PLY for review must not replace the
    /// comparison evidence for the currently committed project until that second reconstruction is committed.
    @Published private(set) var committedPLYEvidence: PLYReconstructionResult?
    @Published var gridSpacingMM: Double = 250
    private var editHistory = PlanOpsisEditHistory(maxDepth: 100)
    private var historyCoalescingKey: String?



    var canUndo: Bool { editHistory.canUndo }
    var canRedo: Bool { editHistory.canRedo }

    var activePLYEvidence: PLYReconstructionResult? {
        guard let project,
              plyEvidenceProjectID == project.id else { return nil }
        return committedPLYEvidence
    }
    var undoLabel: String { editHistory.undoLabel.map { "Undo \($0)" } ?? "Undo" }
    var redoLabel: String { editHistory.redoLabel.map { "Redo \($0)" } ?? "Redo" }

    var selectedComponentIDs: Set<UUID> {
        guard let project else { return [] }
        let componentIDs = Set(project.rooms.flatMap(\.components).map(\.id))
        return selectedIDs.intersection(componentIDs)
    }

    var selectedComponentCount: Int { selectedComponentIDs.count }
    var selectedWallIDs: Set<UUID> {
        guard let project else { return [] }
        let wallIDs = Set(project.rooms.flatMap(\.walls).map(\.id))
        return selectedIDs.intersection(wallIDs)
    }

    var selectedWallCount: Int { selectedWallIDs.count }
    var selectedTransformCount: Int { selectedWallCount + selectedComponentCount }
    var canArchitecturalTransformSelection: Bool { representationMode == .semanticObservations && selectedTransformCount > 0 }

    var canAlignSelection: Bool { selectedComponentCount >= 2 }
    var canDistributeSelection: Bool { selectedComponentCount >= 3 }
    var canArraySelection: Bool { selectedComponentCount >= 1 && arrayCount >= 2 && arrayStepMM.isFinite && abs(arrayStepMM) > 1e-9 }

    private func selectionSet(primary: UUID?) -> Set<UUID> {
        if !selectedIDs.isEmpty { return selectedIDs }
        return primary.map { [$0] } ?? []
    }

    private func setSelection(_ ids: Set<UUID>, primary: UUID?) {
        let resolvedPrimary = primary.flatMap { ids.contains($0) ? $0 : nil } ?? ids.sorted { $0.uuidString < $1.uuidString }.first
        // Avoid publishing identical selection state. Selection drives a full
        // Canvas redraw plus inspector recomputation, so repeated assignments
        // were visible as occasional tap lag on device.
        guard ids != selectedIDs || resolvedPrimary != selectedID else { return }
        objectWillChange.send()
        selectedIDs = ids
        selectedID = resolvedPrimary
    }

    private func resetEditHistory() {
        editHistory.clear()
        historyCoalescingKey = nil
    }

    private func currentHistorySnapshot() -> EditorHistorySnapshot? {
        guard let project else { return nil }
        return EditorHistorySnapshot(project: project, selectionIDs: selectionSet(primary: selectedID), primarySelectionID: selectedID)
    }

    @discardableResult
    private func commitSemanticProject(
        _ next: PlanOpsisProject,
        label: String,
        selectionAfter: Set<UUID>? = nil,
        primaryAfter: UUID? = nil,
        coalescingKey: String? = nil
    ) -> Bool {
        guard let current = project else { return false };guard current != next else { return true }
        do { try SurveyValidation.validate(next)
            if current.rooms != next.rooms && current.survey.observations.contains(where:{$0.locked}) { try SurveyCorrectionEngine().validateChange(from:current,to:next) }
        } catch { statusMessage = error.localizedDescription; return false }
        if coalescingKey == nil || historyCoalescingKey != coalescingKey {
            editHistory.record(
                EditorHistorySnapshot(project: current, selectionIDs: selectionSet(primary: selectedID), primarySelectionID: selectedID),
                label: label
            )
        }
        historyCoalescingKey = coalescingKey
        project = next
        if let selectionAfter {
            setSelection(selectionAfter, primary: primaryAfter)
        } else {
            let valid = Set(next.rooms.flatMap { room in room.walls.map(\.id) + room.openings.map(\.id) + room.components.map(\.id) })
            let kept = selectionSet(primary: selectedID).intersection(valid)
            setSelection(kept, primary: selectedID)
        }
        clearPhysicalEditState(clearUndo: true)
        regenerate()
        return true
    }

    func undo() {
        guard let current = currentHistorySnapshot(), let previous = editHistory.undo(current: current) else { return }
        historyCoalescingKey = nil
        // The underlay's placement is not a model edit: undo leaves it where it is.
        var restored = previous.project
        restored.underlay = project?.underlay
        project = restored
        setSelection(previous.selectionIDs, primary: previous.primarySelectionID)
        clearPhysicalEditState(clearUndo: true)
        regenerate()
        statusMessage = "Undid last semantic edit."
    }

    func redo() {
        guard let current = currentHistorySnapshot(), let next = editHistory.redo(current: current) else { return }
        historyCoalescingKey = nil
        var restored = next.project
        restored.underlay = project?.underlay
        project = restored
        setSelection(next.selectionIDs, primary: next.primarySelectionID)
        clearPhysicalEditState(clearUndo: true)
        regenerate()
        statusMessage = "Redid semantic edit."
    }

    var dxfPreview: DXFPreviewSnapshot {
        if project != nil { return derivation?.drawing ?? .empty }
        return importedDXFPreview ?? .empty
    }

    /// The project's drawing in the CAD viewer, rebuilt only when the drawing changes.
    var projectDrawing: CADViewerDocument? {
        let preview = dxfPreview
        guard !preview.primitives.isEmpty else { return nil }
        if let cache = projectDrawingCache, cache.preview == preview { return cache.drawing }
        let drawing = CADViewerDocument(source: .project, document: CADDocument(preview: preview, layerNaming: dxfLayerNaming))
        projectDrawingCache = (preview, drawing)
        return drawing
    }

    /// The drawing the DXF tab shows.
    var viewerDrawing: CADViewerDocument? {
        if viewerShowsOpenedDrawing, let openedDrawing { return openedDrawing }
        return projectDrawing ?? openedDrawing
    }

    func hiddenLayers(for drawing: CADViewerDocument) -> Set<String> {
        viewerHiddenLayers[drawing.source] ?? drawing.scene.initiallyHiddenLayers
    }

    func setHiddenLayers(_ layers: Set<String>, for drawing: CADViewerDocument) {
        viewerHiddenLayers[drawing.source] = layers
        if drawing.id == openedDrawing?.id { syncProjectUnderlay() }
    }

    /// Opens a DXF for viewing. Parsing runs off the main thread; large drawings take a moment.
    func openDrawing(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            statusMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        let name = url.lastPathComponent
        isOpeningDrawing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CADViewerDocument.open(data: data, fileName: name) }
            }.value
            guard let self else { return }
            self.isOpeningDrawing = false
            switch result {
            case let .success(drawing):
                self.openedDrawing = drawing
                self.openedDrawingData = (data, name)
                self.viewerShowsOpenedDrawing = true
                self.viewerHiddenLayers[drawing.source] = nil
                let notes = drawing.scene.diagnostics.summary
                self.statusMessage = notes.isEmpty
                    ? "Opened \(name) for viewing (\(drawing.document.units.symbol))."
                    : "Opened \(name). \(notes.joined(separator: " "))"
            case let .failure(error):
                self.statusMessage = "Could not open \(name): \(error.localizedDescription)"
            }
        }
    }

    func closeOpenedDrawing() {
        if let openedDrawing { viewerHiddenLayers[openedDrawing.source] = nil }
        openedDrawing = nil
        viewerShowsOpenedDrawing = false
    }

    var planAnnotations: [DXFPrimitive] {
        guard project != nil, let annotations = derivation?.annotations else { return [] }
        return annotations.filter {
            (showDimensions && $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue) ||
            (showRoomText && $0.layer == ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue)
        }
    }

    var dxfReadiness: ArchitecturalSurveyReadinessReport {
        guard project != nil else { return .empty }
        return derivation?.readiness ?? .empty
    }

    private var derivationSettings: ProjectDerivation.Settings {
        ProjectDerivation.Settings(
            representation: representationMode,
            focusedRoomID: focusedRoomID,
            includeOpeningDimensions: showOpeningWidths,
            surveyDrawing: dxfExportProfile == .rhinoEditable || (project.map { $0.survey != .empty } ?? false),
            includeTags: showTags
        )
    }

    /// Rebuilds derived drawing data for a settings change, reusing geometry when the project is unchanged.
    private func rederive() {
        guard let project else { derivation = nil; return }
        derivation = ProjectDerivation(project: project, settings: derivationSettings, captureDiagnostics: diagnostics, reusing: derivation)
    }

    var canExportDXF: Bool { dxfReadiness.canExportDXF }

    var dxfReadinessLabel: String {
        let report = dxfReadiness
        if report.isProfessionalReady { return "DXF ready" }
        if report.errorCount > 0 { return "Fix \(report.errorCount) issue\(report.errorCount == 1 ? "" : "s")" }
        if report.warningCount > 0 { return "Review \(report.warningCount) warning\(report.warningCount == 1 ? "" : "s")" }
        return "DXF review"
    }

    func beginCreation(_ kind: PlanObjectKind) {
        guard representationMode == .semanticObservations else {
            statusMessage = "Add objects in Observed mode so edits target semantic architecture."
            return
        }
        componentCreationTool = nil
        creationTool = kind
        pendingWallStart = nil
        wallChainStart = nil
        underlayAlignment = nil
        isTracingWalls = false
        cancelSectionPlacement()
        statusMessage = kind == .wall ? "Draw walls: tap corners (or type lengths); tap Done to finish." : "Add \(kind.rawValue.capitalized): tap a host wall."
    }

    func beginDoorCreation(_ operation: PlanOpsisDoor.Operation) {
        doorCreationOperation = operation
        beginCreation(.door)
        statusMessage = "Add \(doorOperationLabel(operation)): tap a host wall."
    }

    func beginWindowCreation(_ operation: PlanOpsisWindow.Operation) {
        windowCreationOperation = operation
        beginCreation(.window)
        statusMessage = "Add \(windowOperationLabel(operation)): tap a host wall."
    }

    func beginComponentCreation(_ kind: PlanOpsisComponent.Kind) {
        guard representationMode == .semanticObservations else {
            statusMessage = "Add components in Observed mode so edits target semantic architecture."
            return
        }
        creationTool = nil
        pendingWallStart = nil
        componentCreationTool = kind
        statusMessage = "Add \(kind.displayName): tap the plan to place it."
    }

    func cancelCreation() {
        let wasDrawingWalls = creationTool == .wall && wallChainStart != nil
        let wasPlacingSection = isPlacingSection
        cancelSectionPlacement()
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        wallChainStart = nil
        if underlayAlignment != nil || isTracingWalls {
            let wasTracing = isTracingWalls
            underlayAlignment = nil
            pendingAlignmentScale = nil
            isTracingWalls = false
            statusMessage = wasTracing ? "Finished tracing walls." : "Underlay alignment cancelled."
            return
        }
        statusMessage = wasDrawingWalls ? "Finished drawing walls." : (wasPlacingSection ? "Section cancelled." : "Add-object tool cancelled.")
    }

    /// - Parameter snapped: the point is an object snap the view already resolved; drafting constraints
    ///   (grid, ortho, polar) must not move it again.
    func handlePlanTap(point: Point2D, hitID: UUID?, snapped: Bool = false) {
        guard let project else { return }
        if placeSectionPoint(point) { return }
        if addUnderlayAlignmentPoint(point) { return }
        if isTracingWalls { traceWall(at: point); return }
        let roomID = focusedRoomID ?? selectedRoom?.id ?? project.rooms.first?.id
        guard let roomID else { return }

        if let componentKind = componentCreationTool {
            let position = gridEnabled ? editingConstraintEngine.snapToGrid(point, spacing: gridSpacingMM) : point
            if let result = semanticEditingEngine.addComponent(kind: componentKind, to: roomID, position: position, project: project) {
                componentCreationTool = nil
                commitSemanticProject(
                    result.0,
                    label: "Add \(componentKind.displayName)",
                    selectionAfter: [result.1],
                    primaryAfter: result.1
                )
                statusMessage = "Added semantic \(componentKind.displayName)."
            }
            return
        }

        guard let tool = creationTool else { return }
        switch tool {
        case .wall:
            guard let start = pendingWallStart else {
                let first = snapped ? point : constrainedCreationPoint(point, anchor: nil, project: project, roomID: roomID)
                pendingWallStart = first
                wallChainStart = first
                statusMessage = "Wall start set. Tap the next corner or type a length."
                return
            }
            let end = snapped ? point : constrainedCreationPoint(point, anchor: start, project: project, roomID: roomID)
            addChainWall(from: start, to: end, roomID: roomID)
        case .door, .window, .opening:
            guard let hostWallID = hitID,
                  let hostRoomID = project.rooms.first(where: { $0.walls.contains(where: { $0.id == hostWallID }) })?.id else {
                statusMessage = "Tap a wall to host the new \(tool.rawValue)."
                return
            }
            if let result = semanticEditingEngine.addOpening(
                kind: tool,
                to: hostRoomID,
                hostWallID: hostWallID,
                center: point,
                project: project,
                doorOperation: doorCreationOperation,
                windowOperation: windowCreationOperation
            ) {
                creationTool = nil
                commitSemanticProject(
                    result.0,
                    label: "Add \(tool.rawValue)",
                    selectionAfter: [result.1],
                    primaryAfter: result.1
                )
                statusMessage = "Added architectural \(tool.rawValue) hosted by the selected wall."
            } else {
                statusMessage = "The selected wall is too short or cannot host that object."
            }
        }
    }

    // MARK: - v12.3 direct editing

    /// Adds one wall of the chain being drawn and continues from its end, or closes the outline when
    /// the end returns to the first corner.
    private func addChainWall(from start: Point2D, to end: Point2D, roomID: UUID) {
        guard let project else { return }
        guard let result = semanticEditingEngine.addWall(to: roomID, start: start, end: end, project: project) else {
            statusMessage = "Wall was not added because its length is too small."
            return
        }
        guard commitSemanticProject(result.0, label: "Add wall", selectionAfter: [result.1], primaryAfter: result.1) else { return }
        lastWallDirection = (end - start).normalized
        let length = (end - start).length
        if let first = wallChainStart, (end - first).length <= GeometryTolerances.coincidenceMM, (start - first).length > GeometryTolerances.coincidenceMM {
            pendingWallStart = nil
            wallChainStart = nil
            creationTool = nil
            statusMessage = "Closed the wall outline."
        } else {
            pendingWallStart = end
            statusMessage = "Added wall \(Int(length.rounded())) mm. Tap the next corner, type a length, or tap Done."
        }
    }

    /// Typed point for wall drawing: `3450` (along the last wall), `3450<90`, `@dx,dy` or `#x,y`.
    /// The first corner is an absolute `x,y`.
    @discardableResult
    func enterPrecisionPoint(_ text: String) -> Bool {
        guard creationTool == .wall, let project,
              let roomID = focusedRoomID ?? selectedRoom?.id ?? project.rooms.first?.id else { return false }
        guard let start = pendingWallStart else {
            let absolute = text.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? text : "#" + text
            guard let first = PlanPrecisionInput.point(from: absolute, anchor: .zero, direction: nil) else {
                statusMessage = "Type the first corner as x,y in millimetres."
                return false
            }
            pendingWallStart = first
            wallChainStart = first
            statusMessage = "Wall start set at \(Int(first.x.rounded())), \(Int(first.y.rounded()))."
            return true
        }
        guard let end = PlanPrecisionInput.point(from: text, anchor: start, direction: lastWallDirection ?? Point2D(x: 1, y: 0)) else {
            statusMessage = "Type a length (3450), length<angle (3450<90), @dx,dy or #x,y in millimetres."
            return false
        }
        addChainWall(from: start, to: end, roomID: roomID)
        return true
    }

    /// Walls a grip drag must not snap to: the selected walls and the walls joined to their ends,
    /// which move with them.
    var snapExclusions: Set<UUID> {
        guard let project else { return [] }
        let selected = selectedWallIDs
        guard !selected.isEmpty else { return [] }
        let walls = project.rooms.flatMap(\.walls)
        let ends = walls.filter { selected.contains($0.id) }.flatMap { [$0.start, $0.end] }
        let joined = walls.filter { wall in
            ends.contains { ($0 - wall.start).length <= GeometryTolerances.coincidenceMM || ($0 - wall.end).length <= GeometryTolerances.coincidenceMM }
        }
        return selected.union(joined.map(\.id))
    }

    /// Object snaps for the plan, excluding the walls being edited. Rebuilt only when the project changes.
    func editorSnapper(excluding excluded: Set<UUID>) -> PlanObjectSnapper? {
        guard objectSnapsEnabled, let project else { return nil }
        if let cache = snapperCache, cache.excluded == excluded, cache.project == project { return cache.snapper }
        let snapper = PlanObjectSnapper(project: project, excludingWallIDs: excluded)
        snapperCache = (project, excluded, snapper)
        return snapper
    }

    // MARK: Selection

    func boxSelect(_ rect: CADRect, mode: PlanBoxSelectionMode, adding: Bool) {
        guard representationMode == .semanticObservations else {
            statusMessage = "Box selection works in Observed mode."
            return
        }
        historyCoalescingKey = nil
        let found = PlanSelectionQuery.objects(in: rect, mode: mode, snapshot: displayGeometry, components: displayComponents)
        let next = adding ? selectionSet(primary: selectedID).union(found) : found
        setSelection(next, primary: found.sorted { $0.uuidString < $1.uuidString }.first ?? selectedID)
        statusMessage = next.isEmpty
            ? "Nothing inside the \(mode == .window ? "window" : "crossing box")."
            : "Selected \(next.count) object\(next.count == 1 ? "" : "s") (\(mode == .window ? "window: fully inside" : "crossing: touching"))."
    }

    func selectConnectedWalls() {
        guard let project, let wall = selectedWall else {
            statusMessage = "Select a wall first."
            return
        }
        let ids = PlanSelectionQuery.connectedWalls(from: wall.id, in: project)
        setSelection(ids, primary: wall.id)
        statusMessage = "Selected \(ids.count) connected wall\(ids.count == 1 ? "" : "s")."
    }

    func selectSimilar() {
        guard let project, let selectedID else {
            statusMessage = "Select an object first."
            return
        }
        let ids = PlanSelectionQuery.similar(to: selectedID, in: project, roomID: focusedRoomID)
        setSelection(ids, primary: selectedID)
        statusMessage = "Selected \(ids.count) similar object\(ids.count == 1 ? "" : "s")."
    }

    func selectAll() {
        guard let project else { return }
        let rooms = project.rooms.filter { focusedRoomID == nil || $0.id == focusedRoomID }
        let ids = Set(rooms.flatMap { $0.walls.map(\.id) + $0.openings.map(\.id) + $0.components.map(\.id) })
        setSelection(ids, primary: selectedID)
        statusMessage = "Selected \(ids.count) object\(ids.count == 1 ? "" : "s")."
    }

    // MARK: Push/pull and opening slide

    func beginPushPull() {
        guard representationMode == .semanticObservations, let project, let wall = selectedWall else { return }
        historyCoalescingKey = nil
        pushPullBase = (project, wall)
    }

    /// Moves the selected wall parallel to itself so it passes through `point` (projected on its
    /// normal); connected walls stretch. Offsets round to 10 mm, or to the grid when it is on.
    func updatePushPull(to point: Point2D, snapped: Bool) {
        guard let base = pushPullBase else { return }
        var offset = (point - base.wall.center).dot(base.wall.normal)
        if !snapped {
            let step = gridEnabled ? gridSpacingMM : 10
            offset = (offset / step).rounded() * step
        }
        pushPullOffset = offset
        do {
            let result = try WallPushPullEngine().pushPull(wallID: base.wall.id, offset: offset, in: base.project)
            commitSemanticProject(result.project, label: "Push/pull wall", coalescingKey: "push-pull-\(base.wall.id.uuidString)")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func endPushPull() {
        if let offset = pushPullOffset, abs(offset) > 1e-9 {
            statusMessage = "Moved wall \(Int(offset.rounded())) mm; connected walls followed."
        }
        pushPullBase = nil
        pushPullOffset = nil
        endInteractiveEdit()
    }

    /// Slides the selected opening along its wall toward `point`; clear distances round to 10 mm
    /// (or the grid) and the centre snaps to the wall midpoint.
    func slideSelectedOpening(to point: Point2D) {
        guard representationMode == .semanticObservations, let project, let opening = selectedOpening else { return }
        let step = gridEnabled ? gridSpacingMM : 10
        guard let next = PlanOpeningEditing.slide(openingID: opening.id, toward: point, in: project, step: step) else { return }
        commitSemanticProject(next, label: "Move opening", coalescingKey: "opening-slide-\(opening.id.uuidString)")
    }

    var selectedOpeningClearances: (fromStart: Double, toEnd: Double)? {
        guard let project, let opening = selectedOpening else { return nil }
        return PlanOpeningEditing.clearances(openingID: opening.id, in: project)
    }

    var selectedOpeningHostWall: PlanOpsisWall? {
        guard let opening = selectedOpening else { return nil }
        return project?.rooms.flatMap(\.walls).first { $0.id == opening.parameters.hostWallID }
    }

    // MARK: Driving dimensions

    /// Plan dimensions that can be edited by value (wall lengths and opening widths).
    var planDimensions: [PlanDimensionEdit] {
        PlanDimensionTarget.dimensions(in: planAnnotations).compactMap { entry in
            guard let point = entry.text.points.first else { return nil }
            return PlanDimensionEdit(target: entry.target, measured: entry.measured, labelPosition: point, rotationDegrees: entry.text.rotationDegrees ?? 0)
        }
    }

    func beginDimensionEdit(_ edit: PlanDimensionEdit) {
        guard representationMode == .semanticObservations else {
            statusMessage = "Edit dimensions in Observed mode."
            return
        }
        dimensionEdit = edit
    }

    /// Applies a typed dimension: walls change length about the chosen anchor (connected walls follow);
    /// openings change width about their centre.
    @discardableResult
    func applyDimension(_ edit: PlanDimensionEdit, value: Double, anchor: PlanLengthAnchor) -> Bool {
        guard let project, value.isFinite, value > 0 else { return false }
        switch edit.target {
        case let .wallLength(wallID):
            do {
                let next = try editingConstraintEngine.changeWallLength(wallID: wallID, by: value - edit.measured, anchor: anchor, in: project)
                guard commitSemanticProject(next, label: "Dimension", selectionAfter: [wallID], primaryAfter: wallID) else { return false }
                statusMessage = "Wall dimension set to \(Int(value.rounded())) mm."
                return true
            } catch {
                statusMessage = error.localizedDescription
                return false
            }
        case let .openingWidth(openingID):
            guard let room = project.rooms.first(where: { $0.openings.contains { $0.id == openingID } }),
                  var opening = room.openings.first(where: { $0.id == openingID }),
                  let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { return false }
            var parameters = opening.parameters
            guard parameters.offsetAlongWall - value / 2 >= -1e-6, parameters.offsetAlongWall + value / 2 <= wall.length + 1e-6 else {
                statusMessage = "A \(Int(value.rounded())) mm opening does not fit on its wall at this position."
                return false
            }
            parameters.width = value
            opening.parameters = parameters
            var next = project
            for roomIndex in next.rooms.indices {
                if let index = next.rooms[roomIndex].openings.firstIndex(where: { $0.id == openingID }) { next.rooms[roomIndex].openings[index] = opening }
            }
            guard commitSemanticProject(next, label: "Dimension", selectionAfter: [openingID], primaryAfter: openingID) else { return false }
            statusMessage = "Opening width set to \(Int(value.rounded())) mm."
            return true
        }
    }

    // MARK: Underlay

    /// The opened DXF placed under the plan in millimetres, or nil when the underlay is off or a PDF
    /// page is the underlay.
    var underlayScene: CADScene? {
        guard showUnderlay else { return nil }
        if let rasterUnderlay {
            // v12.7 a vector PDF's lines, placed with the page: snapped to and traced, not drawn.
            guard let vectors = rasterVectors else { return nil }
            let p = rasterPlacement
            let key = "pdf|\(rasterUnderlay.id)|\(rasterUnderlay.paperScale)|\(p.offset.x)|\(p.offset.y)|\(p.rotationDegrees)|\(p.scale)"
            if let cache = underlayCache, cache.key == key { return cache.scene }
            let scene = CADScene(document: vectors, transform: p.transform(unitScale: rasterUnderlay.paperScale))
            underlayCache = (key, scene)
            return scene
        }
        guard let drawing = openedDrawing else { return nil }
        let p = underlayPlacement
        let key = "\(drawing.id)|\(p.offset.x)|\(p.offset.y)|\(p.rotationDegrees)|\(p.scale)"
        if let cache = underlayCache, cache.key == key { return cache.scene }
        let scene = CADScene(document: drawing.document, transform: p.transform(unitScale: Self.millimetresPerUnit(drawing)))
        underlayCache = (key, scene)
        return scene
    }

    var underlayHiddenLayers: Set<String> {
        rasterUnderlay != nil ? [] : openedDrawing.map(hiddenLayers(for:)) ?? []
    }

    /// The PDF page under the plan and its drawing-to-plan transform, when shown.
    var visibleRasterUnderlay: (underlay: RasterUnderlay, transform: CADAffine)? {
        guard showUnderlay, let rasterUnderlay else { return nil }
        return (rasterUnderlay, rasterPlacement.transform(unitScale: rasterUnderlay.paperScale))
    }

    var hasUnderlaySource: Bool { openedDrawing != nil || rasterUnderlay != nil }

    /// "Drawing.dxf" or "Sheet.pdf · 1:100".
    var underlayTitle: String? {
        if let rasterUnderlay {
            if rasterUnderlay.isPhoto {
                if rasterPlacement.scale != 1 { return "\(rasterUnderlay.name) · calibrated" }
                return "\(rasterUnderlay.name) · " + (photoReading.map { "scale \($0.scaleSource.summary)" } ?? "not calibrated")
            }
            let scale = rasterUnderlay.paperScale * rasterPlacement.scale
            return "\(rasterUnderlay.name) · 1:\(Self.scaleText(scale))"
        }
        guard let openedDrawing else { return nil }
        return underlayPlacement.scale == 1 ? openedDrawing.title : "\(openedDrawing.title) · ×\(Self.scaleText(underlayPlacement.scale))"
    }

    private static func scaleText(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005 ? String(Int(value.rounded())) : String(format: "%.3g", value)
    }

    private static func millimetresPerUnit(_ drawing: CADViewerDocument) -> Double {
        drawing.document.units.millimetresPerUnit ?? 1
    }

    /// The placement of whichever underlay is shown.
    private var activeUnderlayPlacement: UnderlayPlacement {
        get { rasterUnderlay != nil ? rasterPlacement : underlayPlacement }
        set { if rasterUnderlay != nil { rasterPlacement = newValue } else { underlayPlacement = newValue } }
    }

    /// Plan bounds of the shown underlay at a placement.
    private func underlayBounds(_ placement: UnderlayPlacement) -> CADRect? {
        if let rasterUnderlay { return rasterUnderlay.bounds(placement: placement) }
        guard let drawing = openedDrawing else { return nil }
        let scene = CADScene(document: drawing.document, transform: placement.transform(unitScale: Self.millimetresPerUnit(drawing)))
        let bounds = scene.visibleBounds(hiddenLayers: hiddenLayers(for: drawing))
        return bounds.isEmpty ? (scene.bounds.isEmpty ? nil : scene.bounds) : bounds
    }

    func toggleUnderlay() {
        guard hasUnderlaySource else {
            showUnderlay = false
            statusMessage = "Open a DXF in the DXF tab, or a PDF from this menu, to use it as an underlay."
            return
        }
        showUnderlay.toggle()
        if !showUnderlay {
            isMovingUnderlay = false
            underlayAlignment = nil
            isTracingWalls = false
        }
        if showUnderlay, activeUnderlayPlacement == UnderlayPlacement() {
            centreUnderlayOnPlan()
        }
        statusMessage = showUnderlay ? "Showing \(underlayTitle ?? "the drawing") under the plan." : "Underlay hidden."
    }

    /// Places the underlay so the centre of its drawing sits on the centre of the plan.
    func centreUnderlayOnPlan() {
        var placement = activeUnderlayPlacement
        placement.offset = .zero
        guard let placed = underlayBounds(placement), !placed.isEmpty else { return }
        // An empty plan centres the drawing on the origin, where new walls start.
        placement.offset = (displayGeometry.floor?.center ?? .zero) - placed.center
        activeUnderlayPlacement = placement
    }

    func moveUnderlay(by delta: Point2D) {
        activeUnderlayPlacement = activeUnderlayPlacement.moved(by: delta)
    }

    /// Rotates the underlay about the centre of what it currently shows.
    func rotateUnderlay(byDegrees degrees: Double) {
        guard let bounds = underlayBounds(activeUnderlayPlacement), !bounds.isEmpty else { return }
        activeUnderlayPlacement = activeUnderlayPlacement.rotated(byDegrees: degrees, about: bounds.center)
    }

    /// Back to the drawing's own units and orientation, centred on the plan.
    func resetUnderlayPlacement() {
        activeUnderlayPlacement = UnderlayPlacement()
        centreUnderlayOnPlan()
        statusMessage = "Underlay reset to its drawing units."
    }

    // MARK: v12.6 alignment and calibration

    func beginUnderlayAlignment(_ mode: UnderlayAlignmentSession.Mode) {
        guard hasUnderlaySource else {
            statusMessage = "Open a DXF or PDF underlay first."
            return
        }
        if !showUnderlay { toggleUnderlay() }
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        cancelSectionPlacement()
        isMovingUnderlay = false
        isTracingWalls = false
        pendingAlignmentScale = nil
        let session = UnderlayAlignmentSession(mode: mode)
        underlayAlignment = session
        statusMessage = (mode == .align ? "Align underlay: " : "Calibrate scale: ") + session.prompt
    }

    /// Points picked so far, in plan mm, for markers.
    var underlayAlignmentMarkers: (underlay: [Point2D], plan: [Point2D]) {
        (underlayAlignment?.underlayPoints ?? [], underlayAlignment?.planPoints ?? [])
    }

    /// True while the next alignment pick belongs on the underlay (snap to it, not to the model).
    var isPickingUnderlayPoint: Bool { underlayAlignment?.needsUnderlayPoint ?? false }

    /// Calibration has both points and waits for the real distance.
    var needsCalibrationLength: Bool {
        guard let underlayAlignment else { return false }
        return underlayAlignment.mode == .calibrate && underlayAlignment.isComplete
    }

    /// Takes a tap for an alignment in progress; false when none is.
    private func addUnderlayAlignmentPoint(_ point: Point2D) -> Bool {
        guard var session = underlayAlignment else { return false }
        guard !session.isComplete else { return true }
        session.add(point)
        underlayAlignment = session
        if session.mode == .align, session.isComplete {
            finishAlignment(session)
        } else {
            statusMessage = session.prompt
        }
        return true
    }

    func undoUnderlayAlignmentPoint() {
        guard var session = underlayAlignment else { return }
        session.undo()
        underlayAlignment = session
        pendingAlignmentScale = nil
        statusMessage = session.prompt
    }

    private func finishAlignment(_ session: UnderlayAlignmentSession) {
        guard let factor = session.alignmentScaleFactor else {
            statusMessage = "The two points must be apart. " + session.prompt
            undoUnderlayAlignmentPoint()
            return
        }
        // A PDF has no reliable units, so it always takes the fitted scale. A DXF keeps its units
        // unless the points disagree clearly, and then the user decides.
        if rasterUnderlay != nil || abs(factor - 1) <= 0.02 {
            applyUnderlayAlignment(matchScale: rasterUnderlay != nil)
        } else {
            pendingAlignmentScale = factor
            statusMessage = "The drawing measures \(String(format: "%.3g", factor))× the plan between those points."
        }
    }

    /// Applies the picked alignment; `matchScale` also scales the underlay so both points fit exactly.
    func applyUnderlayAlignment(matchScale: Bool) {
        pendingAlignmentScale = nil
        guard let session = underlayAlignment, let correction = session.alignment(matchScale: matchScale) else { return }
        activeUnderlayPlacement = activeUnderlayPlacement.applying(correction)
        underlayAlignment = nil
        let turn = correction.rotation * 180 / .pi
        let normalized = (turn + 540).truncatingRemainder(dividingBy: 360) - 180
        statusMessage = String(format: "Underlay aligned: turned %.1f°", normalized)
            + (matchScale && abs(correction.scale - 1) > 1e-6 ? String(format: ", scaled ×%.4g.", correction.scale) : ", drawing scale kept.")
    }

    /// Scales the underlay so the two picked points are `knownLength` mm apart.
    func applyUnderlayCalibration(knownLength: Double) {
        guard let session = underlayAlignment, let measured = session.measuredLength,
              let correction = session.calibration(knownLength: knownLength) else {
            statusMessage = "Enter a distance greater than zero."
            return
        }
        activeUnderlayPlacement = activeUnderlayPlacement.applying(correction)
        underlayAlignment = nil
        statusMessage = String(format: "Underlay calibrated: %.0f mm measured, %.0f mm entered (×%.4g).", measured, knownLength, correction.scale)
            + (rasterUnderlay != nil && rasterUnderlay?.isPhoto != true ? " Now 1:\(underlayTitle?.components(separatedBy: "1:").last ?? "")." : "")
        // v12.10 a plan built from the photo and not edited since follows the new scale.
        if photoReading != nil, !photoBuild.isEmpty, isPhotoBuildUntouched {
            buildPlanFromPhoto(calibrated: true)
        }
    }

    // MARK: v12.6 PDF underlay

    /// Renders and places a PDF page as the underlay, at an assumed 1:100 until calibrated.
    @discardableResult
    func openPDFUnderlay(data: Data, name: String) async -> Bool {
        guard let loader = pdfPageLoader else { return false }
        statusMessage = "Rendering \(name)\u{2026}"
        let result = await Task.detached(priority: .userInitiated) { Result { try loader(data, name, 0) } }.value
        switch result {
        case let .success(page):
            rasterSource = (data, name)
            rasterFormat = .pdf
            setRasterUnderlay(page)
            return true
        case let .failure(error):
            statusMessage = "PDF underlay failed: \(error.localizedDescription)"
            return false
        }
    }

    /// v12.9 turns a photo of a plan into an underlay: straightened, its walls and lines found, its text
    /// read. Calibration starts straight away; then Import all walls makes the walls and rooms. A blank
    /// project is started when none is open. A document camera scan is already squared up, so it is not
    /// straightened again.
    @discardableResult
    func openPhotoPlan(data: Data, name: String, straighten: Bool = true) async -> Bool {
        guard let loader = photoPlanLoader else { return false }
        statusMessage = "Reading the plan in \(name)\u{2026}"
        let result = await Task.detached(priority: .userInitiated) { Result { try loader(data, name, straighten) } }.value
        switch result {
        case let .success(page):
            if project == nil { startBlankProject() }
            // The straightened photo is what is kept with the project.
            rasterSource = (page.raster.imageData, name + ".jpg")
            rasterFormat = .image
            setRasterUnderlay(page)
            // v12.10 straight to a plan when there is nothing drawn yet, as a scan does.
            if photoReading != nil, project?.rooms.allSatisfy({ $0.walls.isEmpty }) ?? true { buildPlanFromPhoto() }
            return true
        case let .failure(error):
            statusMessage = "The photo could not be read: \(error.localizedDescription)"
            return false
        }
    }

    /// Uses a rendered PDF page as the underlay, at an assumed 1:100 until calibrated.
    func setRasterUnderlay(_ page: PDFUnderlayPage) {
        rasterUnderlay = page.raster
        rasterVectors = page.vectors
        rasterPageCount = page.pageCount
        rasterPageIndex = page.pageIndex
        rasterPlacement = UnderlayPlacement()
        showUnderlay = true
        isMovingUnderlay = false
        photoReading = page.reading
        photoBuild = []
        photoReview = nil
        centreUnderlayOnPlan()
        if let reading = page.reading {
            // v12.10 the photo comes with its own scale: no calibration needed unless it looks wrong.
            statusMessage = "\(page.raster.name): scale \(reading.scaleSource.summary). Build plan from photo reads it into walls and rooms."
            return
        }
        beginUnderlayAlignment(.calibrate)
        if page.raster.isPhoto {
            let wallLayers = Set(page.vectors?.layers.map(\.name).filter(UnderlayWallTracer.isWallLayer) ?? [])
            let faces = page.vectors?.entities.filter { wallLayers.contains($0.layer) }.count ?? 0
            let lines = (page.vectors?.entities.count ?? 0) - faces
            statusMessage = "\(page.raster.name): \(faces / 2) wall stroke(s) and \(lines) other line(s) found. Calibrate: tap both ends of a dimension you know, then enter it."
            return
        }
        let lines = page.vectors.map { " \($0.entities.count) lines to snap to and trace." } ?? " A scanned page: no lines to snap to."
        statusMessage = "\(page.raster.name) placed at 1:\(Self.scaleText(page.raster.paperScale)).\(lines) Calibrate: tap two points a known distance apart."
    }

    /// v12.7 shows another page of the PDF in the same place and scale.
    func setRasterPage(_ index: Int) {
        guard let source = rasterSource, let loader = pdfPageLoader, let current = rasterUnderlay,
              index != rasterPageIndex, (0..<rasterPageCount).contains(index) else { return }
        let placement = rasterPlacement
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try loader(source.data, source.name, index) } }.value
            guard case let .success(page) = result, rasterSource?.data == source.data else {
                if case let .failure(error) = result { statusMessage = "Page \(index + 1) failed: \(error.localizedDescription)" }
                return
            }
            var raster = page.raster
            raster.paperScale = current.paperScale
            rasterUnderlay = raster
            rasterVectors = page.vectors
            rasterPageIndex = page.pageIndex
            rasterPlacement = placement
            syncProjectUnderlay()
            statusMessage = "Showing page \(index + 1) of \(rasterPageCount)."
        }
    }

    /// Sets the PDF's drawing scale (1:50, 1:100…) and clears any calibration.
    func setRasterPaperScale(_ scale: Double) {
        guard var underlay = rasterUnderlay, scale > 0 else { return }
        let before = underlayBounds(rasterPlacement)?.center
        underlay.paperScale = scale
        rasterUnderlay = underlay
        rasterPlacement.scale = 1
        // Keep the sheet centred where it was.
        if let before, let after = underlayBounds(rasterPlacement)?.center {
            rasterPlacement = rasterPlacement.moved(by: before - after)
        }
        statusMessage = "\(underlay.name) at 1:\(Self.scaleText(scale))."
    }

    func removeRasterUnderlay() {
        rasterUnderlay = nil
        rasterVectors = nil
        rasterSource = nil
        underlayAlignment = nil
        photoReading = nil
        photoBuild = []
        photoReview = nil
        if openedDrawing == nil {
            showUnderlay = false
            if var next = project, next.underlay?.format == .pdf || next.underlay?.format == .image {
                next.underlay = nil
                project = next
                scheduleAutosave()
            }
        } else {
            syncProjectUnderlay()
        }
        statusMessage = openedDrawing == nil ? "PDF underlay removed." : "PDF underlay removed; the DXF is the underlay again."
    }

    // MARK: v12.7 survey against the drawing

    /// Compares the surveyed walls and openings with the aligned underlay and shows the result.
    func compareWithDrawing() {
        guard let project else { return }
        guard showUnderlay, let reference = deviationReference() else {
            statusMessage = "Show and align a DXF, IFC or vector PDF underlay first; its walls are the reference."
            return
        }
        guard !reference.walls.isEmpty else {
            statusMessage = "No walls found in the drawing to compare with (double lines 50–700 mm apart, or IFC walls)."
            return
        }
        let analysis = DeviationAnalysis(project: project, reference: reference)
        deviation = analysis
        showDeviation = true
        showDeviationReport = true
        let counts = analysis.summary
        statusMessage = "Compared with \(reference.walls.count) drawing wall(s): \(counts[.ok] ?? 0) within tolerance, "
            + "\(counts[.warning] ?? 0) to check, \(counts[.deviation] ?? 0) off, \(counts[.unmatched] ?? 0) unmatched."
    }

    func clearDeviation() {
        deviation = nil
        showDeviation = false
        showDeviationReport = false
    }

    func exportDeviationCSV() -> Data? {
        guard let deviation else { return nil }
        return Data(("\u{FEFF}" + ProjectSchedules.csv(deviation.tables)).utf8)
    }

    /// Walls and openings of the shown underlay in plan millimetres: an IFC's model, a DXF's wall
    /// layers (all its visible lines when it has none), or a vector PDF's lines.
    private func deviationReference() -> UnderlayTraceResult? {
        if let rasterUnderlay {
            guard let scene = underlayScene else { return nil }
            let p = rasterPlacement
            let key = "pdf|\(rasterUnderlay.id)|\(rasterUnderlay.paperScale)|\(p)"
            if let cache = deviationReferenceCache, cache.key == key { return cache.reference }
            let reference = UnderlayWallTracer(scene: scene).traceAll()
            deviationReferenceCache = (key, reference)
            return reference
        }
        guard let drawing = openedDrawing, let scene = underlayScene else { return nil }
        let hidden = hiddenLayers(for: drawing)
        let key = "\(drawing.id)|\(underlayPlacement)|\(hidden.sorted())"
        if let cache = deviationReferenceCache, cache.key == key { return cache.reference }
        let reference: UnderlayTraceResult
        if let source = openedDrawingData, ProjectUnderlay.format(forFileName: source.name) == .ifc,
           let model = try? IFCModelReader().read(data: source.data) {
            let moved = model.transformed(by: underlayPlacement.transform(unitScale: Self.millimetresPerUnit(drawing)))
            reference = UnderlayTraceResult(walls: moved.walls, openings: moved.openings)
        } else {
            let wallLayers = Set(drawingWallLayers)
            reference = UnderlayWallTracer(scene: scene, hiddenLayers: hidden, layers: wallLayers.isEmpty ? nil : { wallLayers.contains($0) }).traceAll()
        }
        deviationReferenceCache = (key, reference)
        return reference
    }

    /// After a model edit the comparison follows the model; the drawing's walls are reused.
    private func refreshDeviation() {
        guard deviation != nil, let project, let reference = deviationReferenceCache?.reference else { return }
        deviation = DeviationAnalysis(project: project, reference: reference)
    }

    // MARK: v12.7 the underlay kept with the project

    /// Writes the shown underlay's source and placement into the project, without an undo step.
    private func syncProjectUnderlay() {
        guard !isRestoringUnderlay, var next = project else { return }
        let source: (data: Data, name: String)
        let format: ProjectUnderlay.Format
        if rasterUnderlay != nil, let raster = rasterSource {
            source = raster
            format = rasterFormat
        } else if openedDrawing != nil, let drawing = openedDrawingData {
            source = drawing
            format = ProjectUnderlay.format(forFileName: drawing.name)
        } else {
            return
        }
        // Nothing to keep until the drawing has been shown under this project.
        guard showUnderlay || next.underlay != nil else { return }
        let reference: SurveyEvidenceReference
        if let cache = underlayAssetCache, cache.projectID == next.id, cache.name == source.name, cache.size == source.data.count {
            reference = cache.reference
        } else {
            do {
                reference = try surveyAttachmentStore().importAsset(data: source.data, projectID: next.id, kind: .underlay, sourceName: source.name)
                underlayAssetCache = (next.id, source.name, source.data.count, reference)
            } catch {
                statusMessage = "The underlay could not be saved with the project: \(error.localizedDescription)"
                return
            }
        }
        next.underlay = ProjectUnderlay(
            format: format, asset: reference, fileName: source.name, placement: activeUnderlayPlacement,
            paperScale: rasterUnderlay != nil ? rasterUnderlay?.paperScale : nil, pageIndex: format == .pdf ? rasterPageIndex : nil,
            hiddenLayers: rasterUnderlay != nil ? nil : openedDrawing.map { hiddenLayers(for: $0).sorted() }, isVisible: showUnderlay)
        guard next != project else { return }
        project = next
        if project != lastSavedProject { scheduleAutosave() }
    }

    /// Reloads the project's underlay (or clears the last project's) after a project is opened.
    private func restoreUnderlay() {
        isRestoringUnderlay = true
        defer { isRestoringUnderlay = false }
        clearDeviation()
        deviationReferenceCache = nil
        underlayAlignment = nil
        isTracingWalls = false
        isMovingUnderlay = false
        guard let project, let saved = project.underlay else {
            rasterUnderlay = nil
            rasterVectors = nil
            rasterSource = nil
            showUnderlay = false
            underlayPlacement = UnderlayPlacement()
            return
        }
        let data: Data
        do {
            data = try surveyAttachmentStore().readVerified(saved.asset, projectID: project.id)
        } catch {
            showUnderlay = false
            statusMessage = "The project's underlay \(saved.fileName) could not be read: \(error.localizedDescription)"
            return
        }
        underlayAssetCache = (project.id, saved.fileName, data.count, saved.asset)
        let projectID = project.id
        switch saved.format {
        case .pdf, .image:
            let load: ((Data) throws -> PDFUnderlayPage)?
            if saved.format == .pdf {
                load = pdfPageLoader.map { loader in { try loader($0, saved.fileName, saved.pageIndex ?? 0) } }
            } else {
                // A photo is kept straightened, so it is not cut again (a border could pass for the sheet);
                // its name keeps the extension the format is read from.
                let name = (saved.fileName as NSString).deletingPathExtension
                load = photoPlanLoader.map { loader in { try loader($0, name, false) } }
            }
            guard let load else { return }
            Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try load(data) } }.value
                guard self.project?.id == projectID, case let .success(page) = result else { return }
                self.isRestoringUnderlay = true
                defer { self.isRestoringUnderlay = false }
                self.rasterFormat = saved.format
                var raster = page.raster
                raster.paperScale = saved.paperScale ?? raster.paperScale
                self.rasterSource = (data, saved.fileName)
                self.rasterUnderlay = raster
                self.rasterVectors = page.vectors
                self.photoReading = page.reading
                self.rasterPageCount = page.pageCount
                self.rasterPageIndex = page.pageIndex
                self.rasterPlacement = saved.placement
                self.showUnderlay = saved.isVisible
            }
        case .dxf, .ifc:
            Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try CADViewerDocument.open(data: data, fileName: saved.fileName) } }.value
                guard self.project?.id == projectID, case let .success(drawing) = result else { return }
                self.isRestoringUnderlay = true
                defer { self.isRestoringUnderlay = false }
                self.rasterUnderlay = nil
                self.rasterVectors = nil
                self.rasterSource = nil
                self.openedDrawing = drawing
                self.openedDrawingData = (data, saved.fileName)
                if let hidden = saved.hiddenLayers { self.viewerHiddenLayers[drawing.source] = Set(hidden) }
                self.underlayPlacement = saved.placement
                self.showUnderlay = saved.isVisible
            }
        }
    }

    // MARK: v12.6 walls from drawings

    /// A new project with one empty room, for drawing or tracing over an underlay.
    func startBlankProject() {
        flushAutosave()
        clearPhysicalEditState(clearUndo: true)
        project = PlanOpsisProject(rooms: [PlanOpsisRoom()], name: openedDrawing?.title ?? rasterUnderlay?.name)
        plyEvidenceProjectID = nil
        committedPLYEvidence = nil
        showPLYEvidenceOverlay = false
        plyImportModel.clear()
        resetEditHistory()
        diagnostics = []
        focusedRoomID = nil
        representationMode = .semanticObservations
        setSelection([], primary: nil)
        regenerate()
        if hasUnderlaySource, !showUnderlay { toggleUnderlay() }
        statusMessage = hasUnderlaySource
            ? "Blank plan over \(underlayTitle ?? "the drawing"). Align it, then trace or draw walls."
            : "Blank plan. Draw walls, or open a DXF or PDF underlay to trace."
    }

    func beginTracingWalls() {
        guard representationMode == .semanticObservations else {
            statusMessage = "Trace walls in Observed mode so they become semantic walls."
            return
        }
        if !showUnderlay, hasUnderlaySource { toggleUnderlay() }
        guard underlayScene != nil else {
            statusMessage = rasterUnderlay != nil
                ? "This PDF page is a scan with no lines to follow. Draw walls over it instead."
                : "Open a DXF, IFC or vector PDF underlay to trace walls from it."
            return
        }
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        cancelSectionPlacement()
        underlayAlignment = nil
        isMovingUnderlay = false
        isTracingWalls = true
        statusMessage = "Trace walls: tap inside a wall on the underlay, between its two lines."
    }

    /// Adds the wall whose two faces straddle `point` on the underlay, joined to walls it meets.
    func traceWall(at point: Point2D) {
        guard var project, let scene = underlayScene else {
            statusMessage = "Show a DXF underlay to trace walls."
            return
        }
        let reach = 900.0
        let region = CADRect(minX: point.x - reach, minY: point.y - reach, maxX: point.x + reach, maxY: point.y + reach)
        let tracer = UnderlayWallTracer(scene: scene, hiddenLayers: underlayHiddenLayers, near: region)
        guard let traced = tracer.trace(at: point) else {
            statusMessage = "No wall there: tap between two parallel lines 50–700 mm apart."
            return
        }
        var roomID = focusedRoomID ?? selectedRoom?.id ?? project.rooms.first?.id
        if roomID == nil {
            let room = PlanOpsisRoom()
            project.rooms.append(room)
            roomID = room.id
        }
        guard let roomID, let room = project.rooms.first(where: { $0.id == roomID }) else { return }
        let existing = room.walls.map { TracedWall(start: $0.start, end: $0.end, thickness: $0.thickness) }
        let wall = UnderlayWallTracer.joined([traced], against: existing)[0]
        guard !existing.contains(where: { (($0.start - wall.start).length < 20 && ($0.end - wall.end).length < 20) || (($0.start - wall.end).length < 20 && ($0.end - wall.start).length < 20) }) else {
            statusMessage = "That wall is already in the model."
            return
        }
        guard var result = semanticEditingEngine.addWall(to: roomID, start: wall.start, end: wall.end, project: project),
              let roomIndex = result.0.rooms.firstIndex(where: { $0.id == roomID }),
              let wallIndex = result.0.rooms[roomIndex].walls.firstIndex(where: { $0.id == result.1 }) else {
            statusMessage = "That wall is too short to add."
            return
        }
        result.0.rooms[roomIndex].walls[wallIndex].thickness = wall.thickness
        if commitSemanticProject(result.0, label: "Trace wall", selectionAfter: [result.1], primaryAfter: result.1) {
            statusMessage = "Traced wall \(Int(wall.length.rounded())) mm long, \(Int(wall.thickness.rounded())) mm thick. Tap the next wall or tap Done."
        }
    }

    /// v12.7 splits a room's walls into rooms, one per closed loop, keeping openings, door swings and
    /// furniture with the room they belong to. Rooms are named from underlay text inside them.
    func detectRooms() {
        guard representationMode == .semanticObservations, var next = project else {
            statusMessage = "Detect rooms in Observed mode."
            return
        }
        guard let room = focusedRoom ?? selectedRoom ?? (next.rooms.count == 1 ? next.rooms.first : nil) else {
            statusMessage = "Focus or select the room whose walls should be split into rooms."
            return
        }
        let boundary = ArchitecturalRoomEnvelope.polygon(for: room, topology: StructureTopologyEngine().generate(from: next))
        let split = RoomLoopDetector().split(room, previousBoundary: boundary)
        guard !split.rooms.isEmpty else {
            statusMessage = "No closed wall loops found. Close the gaps (Close junctions) and try again."
            return
        }
        guard split.rooms.count > 1 || split.unenclosed != nil else {
            statusMessage = "The walls already form one room."
            return
        }
        guard let index = next.rooms.firstIndex(where: { $0.id == room.id }) else { return }
        next.rooms.replaceSubrange(index...index, with: split.allRooms)
        if let scene = underlayScene {
            let names = RoomLoopDetector.names(for: split.rooms.map(\.loop), texts: scene.texts(hiddenLayers: underlayHiddenLayers))
            for (entry, name) in zip(split.rooms, names) where next.survey.roomNames[entry.room.id]?.isEmpty ?? true {
                if let name { next.survey.roomNames[entry.room.id] = name }
            }
        }
        if commitSemanticProject(next, label: "Detect rooms") {
            focusedRoomID = nil
            let leftover = split.unenclosed.map { " \($0.walls.count) wall(s) outside any loop kept together." } ?? ""
            statusMessage = "Found \(split.rooms.count) room(s)." + leftover
        }
    }

    /// Layers of the opened DXF that hold walls (IfcWall, A-WALL, WALL…).
    var drawingWallLayers: [String] {
        openedDrawing?.scene.layers.map(\.id).filter(UnderlayWallTracer.isWallLayer) ?? []
    }

    /// v12.9 whether Import all walls has something to read: a DXF or IFC with wall layers, or a photo
    /// or PDF underlay with line work.
    var canImportWalls: Bool {
        rasterUnderlay != nil ? photoReading.map { !$0.walls.isEmpty } ?? rasterVectors.map { !$0.entities.isEmpty } ?? false : !drawingWallLayers.isEmpty
    }

    /// v12.9 whether the underlay has line work to write as a DXF.
    var canExportUnderlayLines: Bool {
        rasterUnderlay != nil ? rasterVectors.map { !$0.entities.isEmpty } ?? false : openedDrawing != nil
    }

    /// v12.9 the underlay's line work as a DXF in plan millimetres (placed and calibrated as it shows),
    /// on PlanOpsis's semantic layers in the chosen naming: the direct photo- or PDF-to-DXF conversion.
    func exportUnderlayLinesDXF() -> String? {
        let document: CADDocument
        let transform: CADAffine
        if let rasterUnderlay {
            guard let vectors = rasterVectors, !vectors.entities.isEmpty else {
                statusMessage = "The underlay has no line work to export."
                return nil
            }
            document = vectors
            transform = rasterPlacement.transform(unitScale: rasterUnderlay.paperScale)
        } else if let drawing = openedDrawing {
            document = drawing.document
            transform = underlayPlacement.transform(unitScale: Self.millimetresPerUnit(drawing))
        } else {
            statusMessage = "There are no underlay lines to export."
            return nil
        }
        statusMessage = rasterUnderlay?.isPhoto == true && rasterPlacement.scale == 1
            ? "Exported the photo's lines before calibration: sizes follow the assumed scale."
            : "Exported the underlay's lines in millimetres."
        return CADDocumentDXFWriter().write(document, transform: transform, layerNaming: dxfLayerNaming)
    }

    // MARK: v12.10 plan from a photo

    var canBuildPlanFromPhoto: Bool { photoReading.map { !$0.walls.isEmpty } ?? false }

    /// Whether the rooms last built from the photo are still in the plan as built.
    private var isPhotoBuildUntouched: Bool {
        guard let rooms = project?.rooms, !photoBuild.isEmpty else { return false }
        return photoBuild.allSatisfy { built in rooms.contains(built) }
    }

    /// Builds the plan the photo shows: walls, doors with their swing, windows, doorways, stairs, and the
    /// rooms they close, named from the photo's text. Replaces the rooms built from it before while they
    /// are untouched; one undo step.
    func buildPlanFromPhoto(calibrated: Bool = false) {
        guard let reading = photoReading, let raster = rasterUnderlay, var next = project else {
            statusMessage = "Open a photo of a plan first."
            return
        }
        let plan = reading.plan(transform: rasterPlacement.transform(unitScale: raster.paperScale))
        guard !plan.rooms.isEmpty else {
            statusMessage = "No walls found in \(raster.name). Try a sharper, straighter photo in even light, or trace the walls by tapping them."
            return
        }
        let replacing = isPhotoBuildUntouched ? Set(photoBuild.map(\.id)) : []
        next.rooms.removeAll { replacing.contains($0.id) || ($0.walls.isEmpty && $0.openings.isEmpty && $0.components.isEmpty) }
        for id in replacing { next.survey.roomNames[id] = nil }
        next.rooms += plan.rooms
        for (id, name) in plan.roomNames { next.survey.roomNames[id] = name }
        let label = replacing.isEmpty ? "Plan from photo" : "Rebuild plan from photo"
        guard commitSemanticProject(next, label: label, selectionAfter: []) else { return }
        let built = Set(plan.rooms.map(\.id))
        photoBuild = project?.rooms.filter { built.contains($0.id) } ?? []
        focusedRoomID = nil
        let review = PhotoPlanReview(reading: reading, plan: plan, calibrated: calibrated || rasterPlacement.scale != 1,
                                     millimetresPerPixel: raster.paperScale * rasterPlacement.scale)
        photoReview = calibrated ? nil : review
        statusMessage = (calibrated ? "Rebuilt at the calibrated scale: " : "Plan from photo: ") + review.summary
    }

    /// The scale from the photo looks wrong: measure a known dimension; the plan rebuilds to it.
    func fixPhotoScale() {
        photoReview = nil
        if !showUnderlay { toggleUnderlay() }
        beginUnderlayAlignment(.calibrate)
        statusMessage = "Tap both ends of a dimension you know on the photo, then enter it. The plan rebuilds at that scale."
    }

    /// Takes the plan built from the photo back out.
    func discardPhotoPlan() {
        photoReview = nil
        guard isPhotoBuildUntouched else { return }
        undo()
        photoBuild = []
        statusMessage = "Plan from photo removed. The photo stays under the plan to trace or rebuild."
    }

    /// v12.9 walls from a photo's or PDF's line work: thick strokes and double lines become walls, closed
    /// loops rooms, named from the text read inside them. Needs the scale calibrated first.
    private func importWallsFromRasterLines() {
        if photoReading != nil {
            buildPlanFromPhoto()
            return
        }
        guard var next = project, let raster = rasterUnderlay, let scene = underlayScene else {
            statusMessage = "This underlay has no lines to read walls from. Trace or draw them instead."
            return
        }
        let wallLayers = Set(scene.layers.map(\.id).filter(UnderlayWallTracer.isWallLayer))
        let traced = UnderlayWallTracer(scene: scene, layers: wallLayers.isEmpty ? nil : { wallLayers.contains($0) }).traceAll()
        guard !traced.walls.isEmpty else {
            statusMessage = raster.isPhoto && rasterPlacement.scale == 1
                ? "No walls at the assumed scale. Calibrate first (tap a known dimension) so walls read 50–700 mm thick."
                : "No walls found: no thick strokes or double lines 50–700 mm apart."
            return
        }
        let room = traced.makeRoom()
        let split = RoomLoopDetector().split(room)
        let rooms = split.allRooms.isEmpty ? [room] : split.allRooms
        let names = RoomLoopDetector.names(for: split.rooms.map(\.loop), texts: scene.texts())
        // A blank plan's empty room gives way to the rooms found.
        next.rooms.removeAll { $0.walls.isEmpty && $0.openings.isEmpty && $0.components.isEmpty }
        next.rooms += rooms
        for (entry, name) in zip(split.rooms, names) {
            if let name { next.survey.roomNames[entry.room.id] = name }
        }
        let wallIDs = Set(rooms.flatMap { $0.walls.map(\.id) })
        if commitSemanticProject(next, label: "Import walls", selectionAfter: wallIDs, primaryAfter: rooms.first?.walls.first?.id) {
            focusedRoomID = nil
            statusMessage = "Imported \(traced.walls.count) wall(s) in \(split.rooms.count) room(s) from \(raster.name). Doors and windows show as gaps: add them on the walls."
        }
    }

    /// Converts every wall drawn on the opened DXF's wall layers into model walls, with doors and windows
    /// where a swing or window symbol sits in a gap. Starts a project when none is open; otherwise adds
    /// one room holding the imported walls. The underlay placement is used, so walls land where the
    /// drawing shows.
    func importWallsFromDrawing() {
        if rasterUnderlay != nil {
            importWallsFromRasterLines()
            return
        }
        guard let drawing = openedDrawing else {
            statusMessage = "Open a DXF or IFC in the DXF tab first."
            return
        }
        let wallLayers = Set(drawingWallLayers)
        guard !wallLayers.isEmpty else {
            statusMessage = "No wall layers in \(drawing.title). Name them IfcWall, A-WALL or WALL, or trace walls by tapping them."
            return
        }
        let placement = project == nil ? UnderlayPlacement(scale: underlayPlacement.scale) : underlayPlacement
        let transform = placement.transform(unitScale: Self.millimetresPerUnit(drawing))
        let traced: UnderlayTraceResult
        let room: PlanOpsisRoom
        let split: RoomLoopDetector.Result
        let names: [String?]
        if let source = openedDrawingData, ProjectUnderlay.format(forFileName: source.name) == .ifc,
           let model = try? IFCModelReader().read(data: source.data).transformed(by: transform) {
            // v12.7 an IFC gives its walls, openings, heights and room names directly.
            traced = UnderlayTraceResult(walls: model.walls, openings: model.openings)
            room = model.makeRoom()
            split = RoomLoopDetector().split(room)
            names = model.spaceNames(for: split.rooms.map(\.loop))
        } else {
            let scene = CADScene(document: drawing.document, transform: transform)
            let tracer = UnderlayWallTracer(scene: scene, hiddenLayers: hiddenLayers(for: drawing), layers: { wallLayers.contains($0) })
            traced = tracer.traceAll()
            room = traced.makeRoom()
            // v12.7 closed loops of walls become rooms, named from the drawing's text inside them.
            split = RoomLoopDetector().split(room)
            names = RoomLoopDetector.names(for: split.rooms.map(\.loop), texts: scene.texts(hiddenLayers: hiddenLayers(for: drawing)))
        }
        guard !traced.walls.isEmpty else {
            statusMessage = "No double-line walls (50–700 mm) found on \(wallLayers.sorted().joined(separator: ", "))."
            return
        }
        let rooms = split.allRooms.isEmpty ? [room] : split.allRooms
        let doors = traced.openings.filter { $0.kind == .door }.count
        let summary = "\(traced.walls.count) wall(s), \(doors) door(s) and \(traced.openings.count - doors) window(s) in \(split.rooms.count) room(s) from \(drawing.title)"
        func name(_ project: inout PlanOpsisProject) {
            for (entry, name) in zip(split.rooms, names) {
                if let name { project.survey.roomNames[entry.room.id] = name }
            }
        }
        if var next = project {
            next.rooms += rooms
            name(&next)
            let wallIDs = Set(rooms.flatMap { $0.walls.map(\.id) })
            if commitSemanticProject(next, label: "Import walls", selectionAfter: wallIDs, primaryAfter: rooms.first?.walls.first?.id) {
                focusedRoomID = nil
                statusMessage = "Imported \(summary). Openings without a symbol stay as gaps."
            }
        } else {
            flushAutosave()
            clearPhysicalEditState(clearUndo: true)
            var created = PlanOpsisProject(rooms: rooms, name: drawing.title)
            name(&created)
            project = created
            plyEvidenceProjectID = nil
            committedPLYEvidence = nil
            showPLYEvidenceOverlay = false
            plyImportModel.clear()
            resetEditHistory()
            diagnostics = []
            focusedRoomID = nil
            creationTool = nil
            componentCreationTool = nil
            pendingWallStart = nil
            representationMode = .semanticObservations
            setSelection([], primary: nil)
            underlayPlacement = placement
            showUnderlay = true
            regenerate()
            statusMessage = "Started a project with \(summary)."
        }
    }

    // MARK: - v12.4 documentation

    var documentationSettings: DocumentationSettings {
        project?.documentationSettings ?? DocumentationSettings()
    }

    /// Changes the drawing set settings (title block, paper, scales, sections) as one undoable edit.
    func updateDocumentation(_ label: String = "Drawing settings", _ mutate: (inout DocumentationSettings) -> Void) {
        guard var next = project else { return }
        var settings = next.documentationSettings
        mutate(&settings)
        guard settings != next.documentationSettings || next.documentation == nil else { return }
        next.documentation = settings
        commitSemanticProject(next, label: label, coalescingKey: "documentation-\(label)")
    }

    /// The drawing set for the current project, rebuilt only when the project or view mode changes.
    var drawingSet: DrawingSet? {
        guard let project else { return nil }
        if let cache = drawingSetCache, cache.representation == representationMode, cache.project == project { return cache.set }
        let set = DrawingSetComposer().compose(
            project: project,
            representation: representationMode,
            semanticGeometry: derivation?.project == project ? derivation?.semanticGeometry : nil,
            physicalGeometry: derivation?.project == project ? derivation?.physicalGeometry : nil
        )
        drawingSetCache = (project, representationMode, set)
        return set
    }

    var schedules: ProjectSchedules? { drawingSet?.schedules }

    /// The schedule mark of the selected door, window or opening (D01, W01…).
    var selectedOpeningMark: String? {
        guard let id = selectedOpening?.id else { return nil }
        return schedules?.marks[id]
    }

    var selectedRoomSchedule: ProjectSchedules.RoomRow? {
        guard let room = selectedRoom else { return nil }
        return schedules?.rooms.first { $0.roomID == room.id }
    }

    func exportDrawingSetPDF() -> Data? {
        guard let set = drawingSet, !set.sheets.isEmpty else {
            statusMessage = "Open or scan a project to produce drawings."
            return nil
        }
        do {
            let data = try SheetPDFRenderer().render(set, title: project?.displayName ?? "PlanOpsis drawings")
            statusMessage = "Drawing set ready: \(set.sheets.count) sheet\(set.sheets.count == 1 ? "" : "s") on \(documentationSettings.paper.title)."
            return data
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// Schedules as CSV with a UTF-8 byte-order mark so spreadsheet apps read m² correctly.
    func exportSchedulesCSV() -> Data? {
        guard let tables = drawingSet?.tables, !tables.isEmpty else {
            statusMessage = "There is nothing to schedule yet."
            return nil
        }
        return Data(("\u{FEFF}" + ProjectSchedules.csv(tables)).utf8)
    }

    // MARK: - v12.5 quantities and finishes

    var quantities: ProjectQuantities? { drawingSet?.quantities }

    var selectedRoomQuantities: ProjectQuantities.RoomRow? {
        guard let room = selectedRoom else { return nil }
        return quantities?.rooms.first { $0.roomID == room.id }
    }

    func finishes(for roomID: UUID) -> RoomFinishes {
        documentationSettings.finishes[roomID] ?? RoomFinishes()
    }

    /// Sets a room's finishes (one undoable edit per field while typing).
    func setFinishes(_ roomID: UUID, field: String, _ mutate: (inout RoomFinishes) -> Void) {
        updateDocumentation("Finishes \(field)") { settings in
            var finishes = settings.finishes[roomID] ?? RoomFinishes()
            mutate(&finishes)
            settings.finishes[roomID] = finishes.isEmpty ? nil : finishes
        }
    }

    var exportBaseName: String {
        let name = project?.displayName ?? "PlanOpsis"
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "PlanOpsis" : cleaned
    }

    /// Starts placing a section line on the plan (two taps).
    func beginSectionPlacement() {
        guard project != nil else { return }
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        isPlacingSection = true
        pendingSectionStart = nil
        statusMessage = "Section: tap where the cut starts, then where it ends. It looks to the left of the line."
    }

    func cancelSectionPlacement() {
        isPlacingSection = false
        pendingSectionStart = nil
    }

    /// Handles a plan tap while placing a section; returns false when not placing one.
    @discardableResult
    func placeSectionPoint(_ point: Point2D) -> Bool {
        guard isPlacingSection else { return false }
        guard let start = pendingSectionStart else {
            pendingSectionStart = point
            statusMessage = "Section start set. Tap where the cut ends."
            return true
        }
        guard (point - start).length > 300 else {
            statusMessage = "A section needs to be longer than 300 mm."
            return true
        }
        let label = documentationSettings.nextSectionLabel
        updateDocumentation("Add section") { $0.sections.append(SectionLine(label: label, start: start, end: point)) }
        isPlacingSection = false
        pendingSectionStart = nil
        statusMessage = "Section \(label)–\(label) added to the drawing set."
        return true
    }

    func flipSection(_ id: UUID) {
        updateDocumentation("Flip section") { settings in
            guard let index = settings.sections.firstIndex(where: { $0.id == id }) else { return }
            settings.sections[index].looksLeft.toggle()
        }
    }

    func deleteSection(_ id: UUID) {
        updateDocumentation("Delete section") { $0.sections.removeAll { $0.id == id } }
    }

    func duplicateSelectedObject() {
        guard representationMode == .semanticObservations,
              let selectedID,
              let project,
              let result = semanticEditingEngine.duplicate(entityID: selectedID, in: project, offsetMM: gridSpacingMM) else {
            statusMessage = "Duplicate is available for semantic walls, openings, and components in Observed mode."
            return
        }
        commitSemanticProject(
            result.0,
            label: "Duplicate",
            selectionAfter: [result.1],
            primaryAfter: result.1
        )
        statusMessage = "Duplicated selected semantic object by \(Int(gridSpacingMM.rounded())) mm."
    }

    func moveSelectedComponent(to point: Point2D) {
        guard let selectedID, let project else { return }
        let spacing: Double? = gridEnabled ? gridSpacingMM : nil
        guard let next = semanticEditingEngine.moveComponent(entityID: selectedID, to: point, in: project, gridSpacing: spacing) else { return }
        commitSemanticProject(
            next,
            label: "Move component",
            coalescingKey: "component-move-\(selectedID.uuidString)"
        )
    }

    func nudgeSelectedComponent(dx: Double, dy: Double) {
        guard let selectedID, let project,
              let next = semanticEditingEngine.nudgeComponent(entityID: selectedID, delta: Point2D(x: dx, y: dy), in: project) else { return }
        commitSemanticProject(next, label: "Nudge component")
        statusMessage = "Moved component ΔX \(Int(dx.rounded())) mm · ΔY \(Int(dy.rounded())) mm."
    }

    func rotateSelectedComponent(byDegrees degrees: Double) {
        guard let selectedID, let project,
              let next = semanticEditingEngine.rotateComponent(entityID: selectedID, byDegrees: degrees, in: project, snapIncrementDegrees: 15) else { return }
        commitSemanticProject(next, label: "Rotate component")
        statusMessage = "Rotated component by \(Int(degrees.rounded()))°."
    }

    func setSelectedComponentRotationRadians(_ radians: Double) {
        updateSelectedComponent { component in
            let degrees = radians * 180 / .pi
            let snapped = (degrees / 15).rounded() * 15
            component.rotationRadians = snapped * .pi / 180
        }
    }

    func snapSelectedComponentToGrid() {
        guard let selectedID, let project,
              let next = semanticEditingEngine.snapComponentToGrid(entityID: selectedID, spacing: gridSpacingMM, in: project) else { return }
        commitSemanticProject(next, label: "Snap component")
        statusMessage = "Snapped component origin to \(Int(gridSpacingMM.rounded())) mm grid."
    }

    func deleteSelectedObject() {
        let ids = selectionSet(primary: selectedID)
        guard let project, !ids.isEmpty else { return }
        let deletion: SemanticDeleteResult?
        do { deletion = try semanticEditingEngine.deleteReportingSurveyConflicts(entityIDs: ids, from: project) }
        catch { statusMessage = error.localizedDescription; return }
        guard let result = deletion else { return }
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        guard commitSemanticProject(result.project, label: "Delete", selectionAfter: [], primaryAfter: nil) else { return }
        let surveyCount = result.removedObservationIDs.count + result.removedDimensionIDs.count
        statusMessage = "Deleted \(result.deletedIDs.count) semantic object\(result.deletedIDs.count == 1 ? "" : "s")"
            + (surveyCount > 0 ? " and \(surveyCount) measurement/dimension reference\(surveyCount == 1 ? "" : "s")." : ".")
    }

    func alignSelection(_ alignment: PlanAlignment) {
        guard representationMode == .semanticObservations, let project,
              let result = semanticEditingEngine.alignComponents(entityIDs: selectedComponentIDs, alignment: alignment, in: project) else {
            statusMessage = "Align requires at least two selected independent components."
            return
        }
        commitSemanticProject(result.project, label: "Align components")
        statusMessage = "Aligned \(result.affectedIDs.count) components."
    }

    func distributeSelection(_ axis: PlanDistributionAxis) {
        guard representationMode == .semanticObservations, let project,
              let result = semanticEditingEngine.distributeComponents(entityIDs: selectedComponentIDs, axis: axis, in: project) else {
            statusMessage = "Distribute requires at least three selected independent components."
            return
        }
        commitSemanticProject(result.project, label: "Distribute components")
        statusMessage = "Distributed \(result.affectedIDs.count) components \(axis.rawValue)."
    }

    func arraySelection(_ axis: PlanArrayAxis) {
        guard representationMode == .semanticObservations, let project,
              let result = semanticEditingEngine.linearArrayComponents(
                entityIDs: selectedComponentIDs,
                axis: axis,
                count: arrayCount,
                stepMM: arrayStepMM,
                in: project
              ) else {
            statusMessage = "Array requires at least one selected component, count ≥ 2, and non-zero step."
            return
        }
        let newSelection = Set(result.createdIDs)
        commitSemanticProject(
            result.project,
            label: "Array components",
            selectionAfter: newSelection.isEmpty ? selectedComponentIDs : newSelection,
            primaryAfter: result.createdIDs.first ?? selectedID
        )
        statusMessage = "Created \(result.createdIDs.count) component instance\(result.createdIDs.count == 1 ? "" : "s") in a \(axis.rawValue) array."
    }

    func moveArchitecturalSelection() {
        guard representationMode == .semanticObservations, let project else { return }
        let ids = selectionSet(primary: selectedID)
        let delta = Point2D(x: transformDeltaXMM, y: transformDeltaYMM)
        guard let result = semanticEditingEngine.moveArchitecturalSelection(entityIDs: ids, delta: delta, in: project) else {
            statusMessage = "Move blocked: select walls/components from one room and include every wall connected at a moved junction."
            return
        }
        commitSemanticProject(result.project, label: "Move architecture")
        statusMessage = "Moved \(result.affectedIDs.count) architectural object(s)."
    }

    func copyArchitecturalSelection() {
        guard representationMode == .semanticObservations, let project else { return }
        let ids = selectionSet(primary: selectedID)
        let delta = Point2D(x: transformDeltaXMM, y: transformDeltaYMM)
        guard let result = semanticEditingEngine.copyArchitecturalSelection(entityIDs: ids, delta: delta, in: project) else {
            statusMessage = "Copy requires walls/components from one room; hosted openings copy with their wall."
            return
        }
        let created = Set(result.createdIDs)
        commitSemanticProject(result.project, label: "Copy architecture", selectionAfter: created, primaryAfter: result.createdIDs.first)
        statusMessage = "Copied \(result.createdIDs.count) semantic object(s)."
    }

    func rotateArchitecturalSelection() {
        guard representationMode == .semanticObservations, let project else { return }
        let ids = selectionSet(primary: selectedID)
        guard let result = semanticEditingEngine.rotateArchitecturalSelection(entityIDs: ids, degrees: transformRotationDegrees, in: project) else {
            statusMessage = "Rotate blocked: include the full connected wall junction or transform independent components."
            return
        }
        commitSemanticProject(result.project, label: "Rotate architecture")
        statusMessage = "Rotated selection \(transformRotationDegrees.formatted(.number.precision(.fractionLength(0...1))))°."
    }

    func mirrorArchitecturalSelection(_ axis: PlanMirrorAxis) {
        guard representationMode == .semanticObservations, let project else { return }
        let ids = selectionSet(primary: selectedID)
        guard let result = semanticEditingEngine.mirrorArchitecturalSelection(entityIDs: ids, axis: axis, in: project) else {
            statusMessage = "Mirror blocked: include the full connected wall junction or transform independent components."
            return
        }
        commitSemanticProject(result.project, label: "Mirror architecture")
        statusMessage = "Mirrored selection \(axis.rawValue)."
    }

    func offsetSelectedWall(_ sign: Double = 1) {
        guard representationMode == .semanticObservations, let project, let wall = selectedWall else { return }
        guard let result = semanticEditingEngine.offsetWall(wallID: wall.id, distanceMM: wallOffsetMM * sign, in: project) else {
            statusMessage = "Offset blocked: detach the wall from external junctions or transform the connected wall group."
            return
        }
        commitSemanticProject(result.project, label: "Offset wall")
        statusMessage = "Offset wall \((wallOffsetMM * sign).formatted(.number.precision(.fractionLength(0...1)))) mm."
    }

    func trimOrExtendSelectedWall() {
        guard representationMode == .semanticObservations, let project, let wall = selectedWall else { return }
        guard let result = semanticEditingEngine.trimOrExtendWallToNearestIntersection(wallID: wall.id, in: project) else {
            statusMessage = "Trim/Extend unavailable: no safe nearest intersection, external junction, or hosted opening would become invalid."
            return
        }
        commitSemanticProject(result.project, label: "Trim/Extend wall")
        statusMessage = "Trimmed/extended wall to nearest safe intersection."
    }

    /// v12.1: write near-coincident wall endpoints back as exact junctions (one undoable edit).
    func closeWallJunctions() {
        guard representationMode == .semanticObservations, let project else { return }
        let result = JunctionNormalizer().normalize(project)
        let skippedNote = result.skippedRoomIDs.isEmpty
            ? ""
            : " \(result.skippedRoomIDs.count) room(s) unchanged: an opening would leave its wall."
        guard result.movedEndpointCount > 0 else {
            statusMessage = "No open wall junctions within \(Int(GeometryTolerances.junctionJoinMM)) mm." + skippedNote
            return
        }
        if commitSemanticProject(result.project, label: "Close junctions") {
            statusMessage = "Closed \(result.movedEndpointCount) wall endpoint(s) into exact junctions." + skippedNote
        }
    }

    func exportDXFText() -> String? {
        guard let project else { return nil }
        let readiness = dxfReadiness
        guard readiness.canExportDXF else {
            statusMessage = "DXF export blocked: resolve \(readiness.errorCount) architectural QA error\(readiness.errorCount == 1 ? "" : "s") first."
            return nil
        }
        if dxfExportProfile == .rhinoEditable {
            do {
                let export=EditableDXFWriter().export(project:project,dimensions:SurveyDimensionBuilder().build(project:project),revisionID:UUID(),layerNaming:dxfLayerNaming)
                guard export.canWrite else { throw SurveyError.invalid(export.issues.joined(separator:"\n")) }
                try surveyExchangeStore().save(export.manifest)
                statusMessage="Rhino drawing ready; its baseline is retained for reviewed return."
                return export.text
            } catch { statusMessage=error.localizedDescription;return nil }
        }
        let export = dxfExchangeEngine.exportValidated(project: project, representation: representationMode)
        guard export.canWrite, !export.text.isEmpty else {
            let detail = export.issues.first(where: { $0.severity == .error })?.message ?? "Unknown DXF serialization error."
            statusMessage = "DXF export blocked: \(detail)"
            return nil
        }
        if let warning = export.issues.first(where: { $0.severity == .warning }) {
            statusMessage = "DXF exported with warning: \(warning.message)"
        }
        return export.text
    }

    func exportIFC4Text() -> String? {
        guard let project else { return nil }
        let export = ifc4ExchangeEngine.exportValidated(project: project)
        guard export.canWrite else {
            let detail = export.issues.first(where: { $0.severity == .error })?.message ?? "Unknown IFC4 serialization error."
            statusMessage = "IFC4 export blocked: \(detail)"
            return nil
        }
        if let warning = export.issues.first(where: { $0.severity == .warning }) {
            statusMessage = "IFC4 exported with warning: \(warning.message)"
        } else {
            statusMessage = "IFC4 semantic model ready for export."
        }
        return export.text
    }

    func importDXF(data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            statusMessage = "DXF import failed: file is not readable ASCII/UTF-8 DXF."
            return
        }
        // Survey-profile remnants still identify a return when CAD has stripped XDATA.
        // Keep it in reconciliation so missing identity can never trigger legacy replacement.
        if text.contains("PO12:") || text.contains("PO12_") || text.contains("PLANOPSIS_SURVEY") || text.contains("PlanOpsisControl") {
            previewSurveyReturn(text)
            return
        }
        let result = dxfExchangeEngine.import(text)
        importedDXFPreview = result.preview
        dxfImportDiagnostics = result.diagnostics
        if let imported = result.project {
            flushAutosave()
            project = imported
            plyEvidenceProjectID = nil
            committedPLYEvidence = nil
            showPLYEvidenceOverlay = false
            plyImportModel.clear()
            resetEditHistory()
            diagnostics = []
            focusedRoomID = nil
            let first = imported.rooms.first?.walls.first?.id
            setSelection(first.map { [$0] } ?? [], primary: first)
            creationTool = nil
            componentCreationTool = nil
            pendingWallStart = nil
            clearPhysicalEditState(clearUndo: true)
            representationMode = .semanticObservations
            regenerate()
            statusMessage = "Imported DXF as \(imported.rooms.count) parametric room(s); \(result.diagnostics.count) diagnostic(s)."
        } else {
            statusMessage = "DXF loaded for viewing only. Parametric import was intentionally refused because architectural wall axes were not explicit."
        }
    }

    private func constrainedCreationPoint(_ point: Point2D, anchor: Point2D?, project: PlanOpsisProject, roomID: UUID) -> Point2D {
        var candidate = gridEnabled ? editingConstraintEngine.snapToGrid(point, spacing: gridSpacingMM) : point
        if orthoEnabled, let anchor { candidate = editingConstraintEngine.orthoPoint(candidate, anchor: anchor) }
        else if polarTrackingEnabled, let anchor, let polar = editingConstraintEngine.polarPoint(candidate, anchor: anchor, incrementDegrees: 15) { candidate = polar }
        guard let room = project.rooms.first(where: { $0.id == roomID }) else { return candidate }
        let tolerance = GeometryTolerances.endpointSnapMM
        let endpoints = room.walls.flatMap { [($0.start, $0.id), ($0.end, $0.id)] }
        if let nearest = endpoints.map({ ($0.0, ($0.0 - candidate).length) }).filter({ $0.1 <= tolerance }).min(by: { $0.1 < $1.1 }) {
            if orthoEnabled, let anchor {
                let delta = nearest.0 - anchor
                if abs(delta.x) > 1e-6 && abs(delta.y) > 1e-6 { return candidate }
            }
            return nearest.0
        }
        return candidate
    }

    func importSnapshot(_ snapshot: RoomCaptureSnapshot) {
        importStructureSnapshot(StructureCaptureSnapshot(room: snapshot))
    }

    func importStructureSnapshot(_ snapshot: StructureCaptureSnapshot) {
        let result = adapter.adapt(snapshot)
        // v12.1: keep what was observed next to what was modelled. Failing to store the evidence must not
        // lose the capture itself, so it is reported rather than blocking the import.
        var imported = result.project
        var evidenceNote = ""
        do {
            imported.survey.evidence.append(try CaptureEvidence.retain(snapshot, projectID: imported.id, in: surveyAttachmentStore()))
        } catch {
            evidenceNote = " Raw capture was not retained: \(error.localizedDescription)"
        }
        let keptNote = project == nil ? "" : " Previous project kept in Projects."
        flushAutosave()
        diagnostics = result.diagnostics
        clearPhysicalEditState(clearUndo: true)
        project = imported
        // RoomPlan is a different evidence source. Preserve the PLY workspace session if the user
        // returns to it, but never overlay stale PLY evidence on this newly captured project.
        plyEvidenceProjectID = nil
        committedPLYEvidence = nil
        showPLYEvidenceOverlay = false
        plyImportModel.clear()
        resetEditHistory()
        focusedRoomID = nil
        let first = result.project.rooms.first?.walls.first?.id
        setSelection(first.map { [$0] } ?? [], primary: first)
        regenerate()
        let adjacencyCount = geometry.topology.adjacencies.count
        // v12.8 recognised furniture, fixtures and appliances come in as editable objects.
        let objectCount = result.project.rooms.reduce(0) { $0 + $1.components.count }
        let objectNote = objectCount > 0 ? " \(objectCount) recognised object(s) placed." : ""
        statusMessage = (diagnostics.isEmpty
            ? "Imported \(result.project.rooms.count) semantic room(s); derived \(adjacencyCount) room adjacency relation(s)."
            : "Imported \(result.project.rooms.count) room(s) with \(diagnostics.count) capture diagnostic(s). Review Inspector.")
            + objectNote + evidenceNote + keptNote
    }

    func importPLYReconstruction(_ reconstruction: PLYReconstructionResult) {
        Task { await commitPLYReconstruction(reconstruction) }
    }
    private func commitPLYReconstruction(_ reconstruction:PLYReconstructionResult) async {
        let initialProject=project
        let evidenceSnapshot=plyImportModel.result ?? reconstruction
        let sourceHash=plyImportModel.sourceSHA256
        let sourceUnit=plyImportModel.cloud?.sourceUnit
        let result = PLYPlanOpsisAdapter().adapt(reconstruction)
        guard result.acceptedWallCount > 0 else {
            statusMessage = "PLY reconstruction produced no valid wall candidates. Adjust section/tolerance settings and reconstruct."
            return
        }

        var surveyedProject = result.project
        do {
            let payload=PLYSurveyEvidence(sourceSHA256:sourceHash,sourceUnit:sourceUnit,reconstruction:evidenceSnapshot)
            let attachments=try surveyAttachmentStore(),id=surveyedProject.id
            let reference=try await Task.detached(priority:.userInitiated) {
                try attachments.importAsset(data:JSONEncoder().encode(payload),projectID:id,kind:.plyComparison,sourceName:reconstruction.sourceName)
            }.value
            guard project==initialProject,plyImportModel.sourceSHA256==sourceHash,(plyImportModel.result ?? reconstruction)==evidenceSnapshot else { throw SurveyError.invalid("Project or PLY reconstruction changed while evidence was being saved. Review and commit again.") }
            surveyedProject.survey.evidence.append(reference)
        } catch { statusMessage = "Could not preserve comparison evidence: \(error.localizedDescription)"; return }
        flushAutosave()
        diagnostics=[];importedDXFPreview=nil;dxfImportDiagnostics=[];clearPhysicalEditState(clearUndo:true)
        project = surveyedProject
        plyEvidenceProjectID = result.project.id
        committedPLYEvidence = evidenceSnapshot
        showPLYEvidenceOverlay = true
        resetEditHistory()
        focusedRoomID = nil
        representationMode = .semanticObservations
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil

        let first = result.project.rooms.first?.walls.first?.id
        setSelection(first.map { [$0] } ?? [], primary: first)
        regenerate()

        let rejected = result.rejectedWallCount
        let structure = result.acceptedStructuralCount
        let rejectedStructure = result.rejectedStructuralCount
        let structuralText: String
        if structure > 0 || rejectedStructure > 0 {
            structuralText = " · \(structure) structural committed / \(rejectedStructure) invalid rejected"
        } else {
            structuralText = ""
        }
        let qa = reconstruction.qa
        let qaText = " · QA \(qa.status.label) · support \(Int((qa.wallSupportFraction * 100).rounded()))% · residual \(qa.meanSupportedResidualMM.map { String(format: "%.0f mm", $0) } ?? "n/a")"
        statusMessage = rejected == 0
            ? "Created QA-reviewed PLY room · \(result.acceptedWallCount) wall(s)\(structuralText)\(qaText)."
            : "Created QA-reviewed PLY room · \(result.acceptedWallCount) wall(s), \(rejected) invalid rejected\(structuralText)\(qaText)."
    }

    func loadMock() {
        importSnapshot(MockRoomCaptureProvider().snapshot())
        applyMockDoorSwing(sourceID: MockRoomCaptureProvider.doorSourceID, swing: .leftIn)
        statusMessage = "Loaded deterministic single-room mock with joined-wall display, direct wall grips, and one explicit left-in door swing."
    }

    func loadMultiRoomMock() {
        importStructureSnapshot(MockStructureCaptureProvider().snapshot())
        applyMockDoorSwing(sourceID: MockRoomCaptureProvider.doorSourceID, swing: .leftIn)
        applyMockDoorSwing(sourceID: MockStructureCaptureProvider.room2DoorSourceID, swing: .rightIn)
        statusMessage = "Loaded deterministic two-room structure mock with explicit test door swings."
    }

    var displayGeometry: DisplayGeometrySnapshot {
        let base: DisplayGeometrySnapshot
        switch representationMode {
        case .semanticObservations:
            base = geometry.semanticDisplaySnapshot()
        case .reconciledPhysical:
            base = physicalEditPreviewGeometry ?? physicalGeometry
        }
        return base.filtered(to: focusedRoomID)
    }

    /// v12.1 the plan view refits its camera when this changes (another project or room focus),
    /// not when edits change the drawing extent.
    var planFitIdentity: String {
        "\(project?.id.uuidString ?? "none")|\(focusedRoomID?.uuidString ?? "all")"
    }

    var rooms: [PlanOpsisRoom] {
        project?.rooms ?? []
    }

    var focusedRoom: PlanOpsisRoom? {
        guard let project else { return nil }
        if let focusedRoomID {
            return project.rooms.first { $0.id == focusedRoomID }
        }
        return nil
    }

    var selectedRoom: PlanOpsisRoom? {
        guard let selectedID, let project else { return focusedRoom }
        return project.rooms.first { room in
            room.walls.contains { $0.id == selectedID } ||
            room.openings.contains { $0.id == selectedID } ||
            room.components.contains { $0.id == selectedID }
        }
    }

    /// v12.6: rooms are numbered in plan order (north-west first), the same as IFC, DXF and schedules.
    func roomLabel(_ roomID: UUID) -> String {
        guard let project else { return "Room" }
        return PlanOrdering(project: project).roomLabel(roomID) ?? "Room"
    }

    /// "Wall 07": the wall number used by IFC, clockwise from the north-west.
    func wallLabel(_ wallID: UUID) -> String {
        guard let project else { return "Wall" }
        return PlanOrdering(project: project).wallName(wallID) ?? "Wall"
    }

    /// Rooms in plan order, for room pickers.
    var orderedRooms: [PlanOpsisRoom] {
        guard let project else { return [] }
        return PlanOrdering(project: project).rooms
    }

    func focusRoom(_ roomID: UUID?) {
        focusedRoomID = roomID
        historyCoalescingKey = nil
        guard let roomID, let project, let room = project.rooms.first(where: { $0.id == roomID }) else { return }
        let valid = Set(room.walls.map(\.id) + room.openings.map(\.id) + room.components.map(\.id))
        let kept = selectionSet(primary: selectedID).intersection(valid)
        if kept.isEmpty {
            let first = room.walls.first?.id ?? room.components.first?.id ?? room.openings.first?.id
            setSelection(first.map { [$0] } ?? [], primary: first)
        } else {
            setSelection(kept, primary: selectedID)
        }
    }

    var selectedWall: PlanOpsisWall? {
        guard selectionSet(primary: selectedID).count <= 1, let selectedID, let project else { return nil }
        for room in project.rooms {
            if let wall = room.walls.first(where: { $0.id == selectedID }) {
                return wall
            }
        }
        return nil
    }

    var selectedOpening: PlanOpsisOpening? {
        guard selectionSet(primary: selectedID).count <= 1, let selectedID, let project else { return nil }
        for room in project.rooms {
            if let opening = room.openings.first(where: { $0.id == selectedID }) {
                return opening
            }
        }
        return nil
    }

    var canMirrorSelectedDoor: Bool {
        guard let opening = selectedOpening, opening.kind == .door else { return false }
        let operation = opening.doorOperation ?? .singleHinged
        return (operation == .singleHinged || operation == .doubleHinged) && opening.doorSwing != .unspecified
    }

    func mirrorSelectedDoorHanding() {
        guard representationMode == .semanticObservations,
              let selectedID,
              let opening = selectedOpening,
              opening.kind == .door,
              canMirrorSelectedDoor,
              var next = project else { return }

        let mirrored: PlanOpsisDoor.Swing
        switch opening.doorSwing ?? .unspecified {
        case .leftIn: mirrored = .rightIn
        case .leftOut: mirrored = .rightOut
        case .rightIn: mirrored = .leftIn
        case .rightOut: mirrored = .leftOut
        case .unspecified: return
        }

        for roomIndex in next.rooms.indices {
            guard let openingIndex = next.rooms[roomIndex].openings.firstIndex(where: { $0.id == selectedID }) else { continue }
            next.rooms[roomIndex].openings[openingIndex].doorSwing = mirrored
            commitSemanticProject(next, label: "Mirror door handing")
            historyCoalescingKey = nil
            statusMessage = "Mirrored door handing."
            return
        }
    }

    var selectedComponent: PlanOpsisComponent? {
        guard selectionSet(primary: selectedID).count <= 1, let selectedID, let project else { return nil }
        for room in project.rooms {
            if let component = room.components.first(where: { $0.id == selectedID }) {
                return component
            }
        }
        return nil
    }

    var displayComponents: [PlanOpsisComponent] {
        guard let project else { return [] }
        if let focusedRoomID {
            return project.rooms.first(where: { $0.id == focusedRoomID })?.components ?? []
        }
        return project.rooms.flatMap(\.components)
    }

    var diagnosticMessages: [String] {
        diagnostics.map(Self.describe)
    }

    var topologyMessages: [String] {
        geometry.topology.issues.map(Self.describe)
    }

    var selectedSharedBoundaries: [SharedBoundary] {
        guard let selectedID else { return [] }
        return geometry.topology.sharedBoundaries.filter { $0.contains(wallID: selectedID) }
    }

    var selectedPassageConnections: [RoomPassageConnection] {
        guard let selectedID else { return [] }
        return geometry.topology.passageConnections.filter {
            $0.openingAID == selectedID || $0.openingBID == selectedID
        }
    }

    var selectedPhysicalPartitions: [PhysicalPartition] {
        guard let selectedID else { return [] }
        return geometry.reconciliation.partitions.filter { $0.contains(wallID: selectedID) }
    }

    var selectedPhysicalPassages: [PhysicalPassage] {
        guard let selectedID else { return [] }
        return geometry.reconciliation.passages.filter { $0.contains(openingID: selectedID) }
    }

    var reconciliationMessages: [String] {
        geometry.reconciliation.conflicts.map(Self.describe)
    }

    var physicalDisplayMessages: [String] {
        physicalGeometry.issues.map(Self.describe)
    }

    var physicalPartitionCount: Int {
        physicalGeometry.physicalPartitionIDs.count
    }

    func select(_ id: UUID?) {
        historyCoalescingKey = nil
        if representationMode != .semanticObservations {
            if selectedID != id {
                physicalEditDraft = nil
                physicalEditPlan = nil
                physicalEditPreviewGeometry = nil
            }
            setSelection(id.map { [$0] } ?? [], primary: id)
            return
        }

        if multiSelectEnabled {
            guard let id else { return }
            var next = selectionSet(primary: selectedID)
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            setSelection(next, primary: next.contains(id) ? id : next.sorted { $0.uuidString < $1.uuidString }.first)
            statusMessage = next.isEmpty ? "Selection cleared." : "Selected \(next.count) object\(next.count == 1 ? "" : "s")."
        } else {
            setSelection(id.map { [$0] } ?? [], primary: id)
        }
        physicalEditDraft = nil
        physicalEditPlan = nil
        physicalEditPreviewGeometry = nil
    }

    func clearSelection() {
        historyCoalescingKey = nil
        setSelection([], primary: nil)
    }

    func endInteractiveEdit() {
        historyCoalescingKey = nil
    }

    func setMultiSelectEnabled(_ enabled: Bool) {
        multiSelectEnabled = enabled
        historyCoalescingKey = nil
        if !enabled, selectedIDs.count > 1 {
            setSelection(selectedID.map { [$0] } ?? [], primary: selectedID)
        }
        statusMessage = enabled ? "Multi-selection enabled. Tap objects to add or remove them." : "Multi-selection disabled."
    }

    func editSelectedWall(_ mutate: (inout PlanOpsisWall) -> Void) {
        guard let selectedID else { return }
        updateWall(id: selectedID, mutate)
    }

    /// v8.3 direct-manipulation API used by the 2D wall grips.
    /// Endpoint coincidence is the connection contract: when two endpoints touch, future
    /// edits to that junction propagate to every coincident endpoint in the same room.
    func moveSelectedWallStart(to point: Point2D) {
        moveSelectedWallEndpoint(.start, proposed: point, applyDraftingConstraints: true)
    }

    func moveSelectedWallEnd(to point: Point2D) {
        moveSelectedWallEndpoint(.end, proposed: point, applyDraftingConstraints: true)
    }

    /// v12.3 grip drags that may carry an object snap resolved by the view.
    func moveSelectedWallEndpoint(_ endpoint: WallEndpointKind, to point: Point2D, snapped: Bool) {
        moveSelectedWallEndpoint(endpoint, proposed: point, applyDraftingConstraints: !snapped)
    }

    func setSelectedWallLength(_ length: Double) {
        guard let wall = selectedWall else { return }
        let target = wall.start + wall.direction * max(0, length)
        moveSelectedWallEndpoint(.end, proposed: target, applyDraftingConstraints: false)
    }

    func setSelectedWallDeltaX(_ deltaX: Double) {
        guard let wall = selectedWall else { return }
        let target = Point2D(x: wall.start.x + deltaX, y: wall.end.y)
        moveSelectedWallEndpoint(.end, proposed: target, applyDraftingConstraints: false)
    }

    func setSelectedWallDeltaY(_ deltaY: Double) {
        guard let wall = selectedWall else { return }
        let target = Point2D(x: wall.end.x, y: wall.start.y + deltaY)
        moveSelectedWallEndpoint(.end, proposed: target, applyDraftingConstraints: false)
    }

    var selectedWallDeltaX: Double {
        guard let wall = selectedWall else { return 0 }
        return wall.end.x - wall.start.x
    }

    var selectedWallDeltaY: Double {
        guard let wall = selectedWall else { return 0 }
        return wall.end.y - wall.start.y
    }

    func moveSelectedWallThicknessGrip(to point: Point2D) {
        guard let wall = selectedWall else { return }
        let constrained = gridEnabled
            ? editingConstraintEngine.snapToGrid(point, spacing: gridSpacingMM)
            : point
        let signedDistance = (constrained - wall.center).dot(wall.normal)
        let thickness = max(20, abs(signedDistance) * 2)
        editSelectedWall { $0.editThickness(thickness) }
    }

    private func moveSelectedWallEndpoint(
        _ endpoint: WallEndpointKind,
        proposed: Point2D,
        applyDraftingConstraints: Bool
    ) {
        guard let selectedID, let project else { return }
        guard let roomID = project.rooms.first(where: { room in
            room.walls.contains(where: { $0.id == selectedID })
        })?.id else { return }

        let settings = PlanEditingSettings(
            orthoEnabled: orthoEnabled,
            gridEnabled: gridEnabled,
            gridSpacing: gridSpacingMM,
            polarIncrementDegrees: polarTrackingEnabled ? 15 : nil
        )
        let edit: ProjectEndpointMoveResult
        do {
            edit = try editingConstraintEngine.moveEndpoint(
                wallID: selectedID,
                endpoint: endpoint,
                proposed: proposed,
                in: project,
                roomID: roomID,
                settings: settings,
                applyConstraints: applyDraftingConstraints
            )
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let result = edit.move

        commitSemanticProject(
            edit.project,
            label: "Edit wall",
            coalescingKey: "wall-\(selectedID.uuidString)-\(endpoint.rawValue)"
        )

        if let snapped = result.constraint.snappedEndpoint {
            statusMessage = "Connected wall junction to \(String(snapped.wallID.uuidString.prefix(8))) · \(snapped.endpoint.rawValue)."
        } else if !result.propagatedEndpointIDs.isEmpty {
            statusMessage = "Moved connected junction across \(result.propagatedEndpointIDs.count + 1) wall endpoint(s)."
        }
    }

    func setSelectedDoorSwing(_ swing: PlanOpsisDoor.Swing) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            opening.doorSwing = swing
        }
    }

    func setSelectedDoorOperation(_ operation: PlanOpsisDoor.Operation) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            opening.doorOperation = operation
            if operation == .sliding || operation == .pocket {
                opening.doorSwing = .unspecified
            } else if opening.doorSwing == .unspecified {
                opening.doorSwing = .leftIn
            }
        }
    }

    func setSelectedWindowOperation(_ operation: PlanOpsisWindow.Operation) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            opening.windowOperation = operation
        }
    }

    func setSelectedOpeningOffset(_ value: Double) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            var p = opening.parameters
            if let wall = self.project?.rooms.flatMap(\.walls).first(where: { $0.id == p.hostWallID }) {
                p.offsetAlongWall = max(p.width * 0.5, min(wall.length - p.width * 0.5, value))
            } else {
                p.offsetAlongWall = max(0, value)
            }
            opening.parameters = p
        }
    }

    func setSelectedOpeningWidth(_ value: Double) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            var p = opening.parameters
            let width = max(20, value)
            if let wall = self.project?.rooms.flatMap(\.walls).first(where: { $0.id == p.hostWallID }) {
                p.width = min(width, wall.length)
                p.offsetAlongWall = max(p.width * 0.5, min(wall.length - p.width * 0.5, p.offsetAlongWall))
            } else { p.width = width }
            opening.parameters = p
        }
    }

    func setSelectedOpeningHeight(_ value: Double) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            var p = opening.parameters
            let hostHeight = self.project?.rooms.flatMap(\.walls).first(where: { $0.id == p.hostWallID })?.height ?? max(20, value)
            p.height = max(20, min(value, max(20, hostHeight - p.sillHeight)))
            opening.parameters = p
        }
    }

    func setSelectedOpeningSill(_ value: Double) {
        guard let selectedID else { return }
        updateOpening(id: selectedID) { opening in
            var p = opening.parameters
            let hostHeight = self.project?.rooms.flatMap(\.walls).first(where: { $0.id == p.hostWallID })?.height ?? p.sillHeight + p.height
            p.sillHeight = max(0, min(value, max(0, hostHeight - p.height)))
            opening.parameters = p
        }
    }

    func setSelectedComponentPositionX(_ value: Double) { updateSelectedComponent { $0.position.x = value } }
    func setSelectedComponentPositionY(_ value: Double) { updateSelectedComponent { $0.position.y = value } }
    func setSelectedComponentWidth(_ value: Double) { updateSelectedComponent { $0.width = max(20, value) } }
    func setSelectedComponentDepth(_ value: Double) { updateSelectedComponent { $0.depth = max(20, value) } }
    func setSelectedComponentHeight(_ value: Double) { updateSelectedComponent { $0.height = max(20, value) } }
    func setSelectedComponentElevation(_ value: Double) { updateSelectedComponent { $0.elevationMM = max(0, value) } }
    func setSelectedComponentRotationDegrees(_ value: Double) { updateSelectedComponent { $0.rotationRadians = value * .pi / 180 } }
    /// v12.8 re-types an object (RoomPlan sometimes calls a dresser "storage" or a desk a "table").
    func setSelectedComponentKind(_ kind: PlanOpsisComponent.Kind) { updateSelectedComponent { $0.kind = kind } }
    /// v12.8 swaps front and back, for an object whose front faces the wall.
    func turnSelectedComponentAround() {
        updateSelectedComponent { $0.rotationRadians = ($0.rotationRadians + .pi).truncatingRemainder(dividingBy: 2 * .pi) }
    }

    /// v12.8 objects RoomPlan recognised in the project.
    var scannedObjectCount: Int {
        project?.rooms.reduce(0) { $0 + $1.components.filter { $0.sourceRoomPlanID != nil }.count } ?? 0
    }

    /// v12.8 removes every object the scan added (hand-placed objects stay), as one undoable edit.
    func removeScannedObjects() {
        guard var next = project else { return }
        let count = scannedObjectCount
        guard count > 0 else { return }
        for index in next.rooms.indices { next.rooms[index].components.removeAll { $0.sourceRoomPlanID != nil } }
        if commitSemanticProject(next, label: "Remove scanned objects", selectionAfter: [], primaryAfter: nil) {
            statusMessage = "Removed \(count) scanned object(s); objects placed by hand stay."
        }
    }

    private func updateSelectedComponent(_ mutate: (inout PlanOpsisComponent) -> Void) {
        guard let selectedID, var next = project else { return }
        for roomIndex in next.rooms.indices {
            guard let componentIndex = next.rooms[roomIndex].components.firstIndex(where: { $0.id == selectedID }) else { continue }
            mutate(&next.rooms[roomIndex].components[componentIndex])
            commitSemanticProject(
                next,
                label: "Edit component",
                coalescingKey: "component-edit-\(selectedID.uuidString)"
            )
            return
        }
    }

    func updateWall(id: UUID, _ mutate: (inout PlanOpsisWall) -> Void) {
        guard var next = project else { return }
        for roomIndex in next.rooms.indices {
            guard let wallIndex = next.rooms[roomIndex].walls.firstIndex(where: { $0.id == id }) else { continue }
            mutate(&next.rooms[roomIndex].walls[wallIndex])
            commitSemanticProject(
                next,
                label: "Edit wall",
                coalescingKey: "wall-edit-\(id.uuidString)"
            )
            return
        }
    }


    private func updateOpening(id: UUID, _ mutate: (inout PlanOpsisOpening) -> Void) {
        guard var next = project else { return }
        for roomIndex in next.rooms.indices {
            guard let openingIndex = next.rooms[roomIndex].openings.firstIndex(where: { $0.id == id }) else { continue }
            mutate(&next.rooms[roomIndex].openings[openingIndex])
            commitSemanticProject(
                next,
                label: "Edit opening",
                coalescingKey: "opening-edit-\(id.uuidString)"
            )
            return
        }
    }

    private func applyMockDoorSwing(sourceID: UUID, swing: PlanOpsisDoor.Swing) {
        guard var next = project else { return }
        for roomIndex in next.rooms.indices {
            guard let openingIndex = next.rooms[roomIndex].openings.firstIndex(where: {
                $0.parameters.sourceRoomPlanID == sourceID && $0.kind == .door
            }) else { continue }
            next.rooms[roomIndex].openings[openingIndex].doorSwing = swing
        }
        project = next
        regenerate()
    }


    var selectedEditablePhysicalPartition: PhysicalPartition? {
        selectedPhysicalPartitions
            .filter { $0.geometry != nil && $0.resolution != .conflicted }
            .sorted { $0.id < $1.id }
            .first
    }

    func beginPhysicalEdit() {
        guard representationMode == .reconciledPhysical,
              let partition = selectedEditablePhysicalPartition,
              let draft = physicalEditEngine.draft(for: partition),
              let project else {
            statusMessage = "Physical edit requires a resolved reconciled partition."
            return
        }
        physicalEditDraft = draft
        physicalEditPlan = physicalEditEngine.preview(draft: draft, project: project, reconciliation: geometry.reconciliation)
        refreshPhysicalEditPreview()
        statusMessage = "Physical edit preview started. 2D/3D now show the uncommitted transaction result; review semantic mutations before applying."
    }

    func setPhysicalEditLength(_ length: Double) {
        mutatePhysicalDraft { draft in
            let direction = (draft.targetGeometry.end - draft.targetGeometry.start).normalized
            draft.targetGeometry.end = draft.targetGeometry.start + direction * max(0, length)
        }
    }

    func setPhysicalEditHeight(_ height: Double) {
        mutatePhysicalDraft { $0.targetGeometry.height = max(0, height) }
    }

    func setPhysicalEditThickness(_ thickness: Double) {
        mutatePhysicalDraft { $0.targetGeometry.thickness = max(0, thickness) }
    }

    func setPhysicalEditAngleDegrees(_ degrees: Double) {
        mutatePhysicalDraft { draft in
            let length = draft.targetGeometry.length
            let radians = degrees * .pi / 180
            let direction = Point2D(x: cos(radians), y: sin(radians))
            draft.targetGeometry.end = draft.targetGeometry.start + direction * length
        }
    }

    func setPhysicalEditStartX(_ x: Double) {
        mutatePhysicalDraft { draft in
            let delta = Point2D(x: x - draft.targetGeometry.start.x, y: 0)
            draft.targetGeometry.start = draft.targetGeometry.start + delta
            draft.targetGeometry.end = draft.targetGeometry.end + delta
        }
    }

    func setPhysicalEditStartY(_ y: Double) {
        mutatePhysicalDraft { draft in
            let delta = Point2D(x: 0, y: y - draft.targetGeometry.start.y)
            draft.targetGeometry.start = draft.targetGeometry.start + delta
            draft.targetGeometry.end = draft.targetGeometry.end + delta
        }
    }

    func cancelPhysicalEdit() {
        physicalEditDraft = nil
        physicalEditPlan = nil
        physicalEditPreviewGeometry = nil
        statusMessage = "Physical edit cancelled; semantic project was not changed."
    }

    func applyPhysicalEdit() {
        guard let project, let plan = physicalEditPlan else { return }
        do {
            let result = try physicalEditEngine.apply(plan, to: project)
            physicalEditDraft = nil
            physicalEditPlan = nil
            physicalEditPreviewGeometry = nil
            commitSemanticProject(result.project, label: "Physical wall edit")
            self.lastPhysicalEditReceipt = result.receipt
            statusMessage = "Applied one atomic physical-edit transaction to \(result.receipt.wallMutations.count) semantic wall(s) and \(result.receipt.openingMutations.count) hosted opening(s)."
        } catch PhysicalEditTransactionError.staleSemanticState {
            statusMessage = "Physical edit was not applied because semantic state changed after preview. Start a new preview."
            refreshPhysicalEditPreview()
        } catch {
            statusMessage = "Physical edit was not applied. Resolve preview validation issues first."
        }
    }

    func undoLastPhysicalEdit() {
        guard lastPhysicalEditReceipt != nil else { return }
        undo()
        lastPhysicalEditReceipt = nil
    }

    var physicalEditValidationMessages: [String] {
        physicalEditPlan?.issues.map(Self.describe) ?? []
    }

    private func mutatePhysicalDraft(_ mutation: (inout PhysicalPartitionEditDraft) -> Void) {
        guard var draft = physicalEditDraft else { return }
        mutation(&draft)
        physicalEditDraft = draft
        refreshPhysicalEditPreview()
    }

    private func refreshPhysicalEditPreview() {
        guard let project, let draft = physicalEditDraft else {
            physicalEditPlan = nil
            physicalEditPreviewGeometry = nil
            return
        }
        let plan = physicalEditEngine.preview(draft: draft, project: project, reconciliation: geometry.reconciliation)
        physicalEditPlan = plan
        if plan.canApply, let simulated = try? physicalEditEngine.simulate(plan, on: project) {
            let simulatedSemantic = geometryEngine.generate(from: simulated)
            physicalEditPreviewGeometry = physicalDisplayEngine.generate(from: simulated, semanticGeometry: simulatedSemantic)
        } else {
            physicalEditPreviewGeometry = nil
        }
    }

    private func clearPhysicalEditState(clearUndo: Bool) {
        physicalEditDraft = nil
        physicalEditPlan = nil
        physicalEditPreviewGeometry = nil
        if clearUndo { lastPhysicalEditReceipt = nil }
    }

    func prepareSurveyDelivery() async -> URL? {
        guard let project else { return nil }
        do {
            let attachments=try surveyAttachmentStore()
            let destination=FileManager.default.temporaryDirectory.appendingPathComponent("PlanOpsis-Survey-"+UUID().uuidString)
            _ = try await Task.detached(priority:.userInitiated) { try SurveyDeliveryWriter().write(project:project,attachmentStore:attachments,destination:destination) }.value
            let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:Data(contentsOf:destination.appendingPathComponent("Survey.exchange.json")))
            try surveyExchangeStore().save(manifest)
            return destination
        } catch { statusMessage="Delivery failed: \(error.localizedDescription)";return nil }
    }
    func attachSurveyPhoto(_ data:Data,projectID:UUID,entityID:UUID?) async {
        do {
            let attachments=try surveyAttachmentStore()
            var reference=try await Task.detached(priority:.userInitiated) { try attachments.importAsset(data:data,projectID:projectID,kind:.photo,sourceName:"Survey photo") }.value
            guard var next=project,next.id==projectID else { throw SurveyError.invalid("Project changed before the photo was attached.") }
            reference.entityID=entityID;next.survey.evidence.append(reference)
            commitSemanticProject(next,label:"Attach photo")
            statusMessage="Photo attached to this project."
        } catch { statusMessage=error.localizedDescription }
    }
    func openSurveyDelivery(_ url:URL) async {
        let initial=project
        do {
            let attachments=try surveyAttachmentStore()
            let imported=try await Task.detached(priority:.userInitiated) { () throws -> PlanOpsisProject in
                let access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
                let loaded=try SurveyDeliveryReader().read(root:url)
                let source=SurveyAttachmentStore(root:url)
                for ref in loaded.survey.evidence {
                    _ = try attachments.importAsset(data:source.readVerified(ref,projectID:loaded.id),projectID:loaded.id,kind:ref.kind,sourceName:ref.sourceName)
                }
                let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:Data(contentsOf:url.appendingPathComponent("Survey.exchange.json")))
                try SurveyExchangeStore(root:attachments.root).save(manifest)
                return loaded
            }.value
            guard project==initial else { throw SurveyError.invalid("Project changed while the folder was loading; open it again to replace the current project.") }
            flushAutosave()
            project=imported;plyImportModel.clear();committedPLYEvidence=nil;plyEvidenceProjectID=nil;showPLYEvidenceOverlay=false
            resetEditHistory();clearPhysicalEditState(clearUndo:true);focusedRoomID=nil;setSelection([],primary:nil);regenerate();restoreSurveyEvidence();restoreUnderlay()
            statusMessage="Survey folder opened with verified project and evidence."
        } catch { statusMessage="Open survey failed: \(error.localizedDescription)" }
    }

    private func surveyExchangeStore() throws -> SurveyExchangeStore {
        SurveyExchangeStore(root:try projectStore().url.deletingLastPathComponent())
    }
    func retainSurveyManifest(_ data:Data) {
        do {
            let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:data)
            guard manifest.projectID==project?.id else { throw SurveyError.invalid("Open the originating project before loading this manifest.") }
            try surveyExchangeStore().save(manifest)
            statusMessage="Exchange baseline loaded. Choose the returned DXF next."
        } catch { statusMessage=error.localizedDescription }
    }
    func previewSurveyReturn(_ text:String) {
        guard let project else { statusMessage="Open the originating PlanOpsis project before returning a Rhino drawing.";return }
        do {
            let drawing=EditableDXFReader().read(text)
            let revisions=Set((drawing.controls+drawing.dimensions).map(\.revisionID))
            guard revisions.count==1,let revision=revisions.first else { throw SurveyError.invalid("Missing or mixed export identity. Choose the matching exchange manifest; do not reconstruct this drawing automatically.") }
            let baseline=try surveyExchangeStore().load(projectID:project.id,revisionID:revision)
            // Retain the received source independently of whether reconciliation accepts it.
            let root=try projectStore().url.deletingLastPathComponent().appendingPathComponent("received")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try Data(text.utf8).write(to:root.appendingPathComponent(UUID().uuidString+".dxf"),options:.atomic)
            surveyImportProposal=SurveyDXFReconciliationEngine().preview(drawing:drawing,baseline:baseline,current:project)
            showSurveyImportReview=true
        } catch { statusMessage="Rhino return unavailable: \(error.localizedDescription)" }
    }
    func applySurveyReturn() {
        guard let project,let proposal=surveyImportProposal else { return }
        do {
            let next=try SurveyDXFReconciliationEngine().apply(proposal,to:project)
            commitSemanticProject(next,label:"Apply Rhino edits")
            showSurveyImportReview=false;surveyImportProposal=nil
            statusMessage="Rhino changes applied as one undoable transaction."
        } catch { statusMessage=error.localizedDescription }
    }
    @discardableResult
    func applySurveyCorrection(_ proposal:SurveyCorrectionProposal) -> Bool {
        guard let project else { return false }
        do { return commitSemanticProject(try SurveyCorrectionEngine().apply(proposal,to:project),label:"Apply measured correction") }
        catch { statusMessage=error.localizedDescription;return false }
    }
    func setSurveyLock(_ id:UUID,locked:Bool) {
        guard var next=project,let i=next.survey.observations.firstIndex(where:{$0.id==id}) else { return }
        let evaluation=SurveyMeasurementEngine().evaluate(next.survey.observations[i],in:next)
        guard !locked || evaluation.status == .withinTolerance else { statusMessage="Verify this measurement within a declared tolerance before locking it.";return }
        next.survey.observations[i].locked=locked
        commitSemanticProject(next,label:"Lock measured check")
    }
    func setSurveySettings(_ settings:SurveyDrawingSettings) {
        guard var next=project else { return };next.survey.settings=settings
        commitSemanticProject(next,label:"Drawing settings")
    }
    func setSurveyDimension(_ definition:SurveyDimensionDefinition) {
        guard var next=project else { return }
        next.survey.dimensions.removeAll{$0.id==definition.id || $0.target==definition.target}
        next.survey.dimensions.append(definition)
        commitSemanticProject(next,label:"Dimension placement")
    }

    func renameRoom(_ id: UUID, name: String) {
        guard var next = project else { return }
        next.survey.roomNames[id] = name
        commitSemanticProject(next, label: "Rename room", coalescingKey: "room-name-" + id.uuidString)
    }
    func recordObservation(_ observation: SurveyObservation) {
        guard var next = project else { return }
        next.survey.observations.append(observation)
        commitSemanticProject(next, label: "Record measurement")
    }
    func removeObservation(_ id: UUID) {
        guard var next = project else { return }
        next.survey.observations.removeAll { $0.id == id }
        commitSemanticProject(next, label: "Remove measurement")
    }
    func verifyObservation(_ id: UUID) {
        guard var next = project, let i = next.survey.observations.firstIndex(where: { $0.id == id }) else { return }
        do {
            next.survey.observations[i].verificationFingerprint = try SurveyMeasurementEngine().fingerprint(for: next.survey.observations[i].target, in: next)
            commitSemanticProject(next, label: "Verify measurement")
        } catch { statusMessage = error.localizedDescription }
    }
    func setSurveyScale(_ scale: Int) {
        guard var next = project else { return }
        next.survey.settings.scale = scale
        commitSemanticProject(next, label: "Drawing scale")
    }
    private func surveyAttachmentStore() throws -> SurveyAttachmentStore {
        SurveyAttachmentStore(root: try projectStore().url.deletingLastPathComponent())
    }
    private func restoreSurveyEvidence() {
        guard let project, let reference = project.survey.evidence.last(where: { $0.kind == .plyComparison }) else { return }
        do {
            let data = try surveyAttachmentStore().readVerified(reference, projectID: project.id)
            let evidence = try JSONDecoder().decode(PLYSurveyEvidence.self, from: data)
            committedPLYEvidence = try evidence.validated()
            plyEvidenceProjectID = project.id
            showPLYEvidenceOverlay = true
        } catch { statusMessage = "Project opened; comparison evidence unavailable: \(error.localizedDescription)" }
    }

    /// Saves the current project to the library now (it is also saved automatically after every change).
    func save() {
        guard let project else { return }
        if flushAutosave() {
            refreshLibrary()
            statusMessage = "Saved \u{201C}\(project.displayName)\u{201D} to Projects."
        }
    }

    /// Opens the most recently changed library project.
    func reopen() {
        refreshLibrary()
        guard let latest = libraryEntries.first(where: { $0.id != project?.id }) ?? libraryEntries.first else {
            statusMessage = "No saved projects yet."
            return
        }
        openProject(latest.id)
    }

    /// Lists the library, importing a pre-v12.2 single-slot project once.
    func refreshLibrary() {
        do {
            let library = try projectLibrary()
            if !didImportLegacyProject {
                didImportLegacyProject = true
                _ = try? library.importLegacy(from: projectStore())
            }
            libraryEntries = library.entries()
        } catch {
            statusMessage = "Projects unavailable: \(error.localizedDescription)"
        }
    }

    func openProject(_ id: UUID) {
        guard id != project?.id else { return }
        do {
            let loaded = try projectLibrary().load(id)
            flushAutosave()
            project = loaded
            lastSavedProject = loaded
            plyEvidenceProjectID = nil
            committedPLYEvidence = nil
            showPLYEvidenceOverlay = false
            plyImportModel.clear()
            resetEditHistory()
            clearPhysicalEditState(clearUndo: true)
            diagnostics = []
            importedDXFPreview = nil
            dxfImportDiagnostics = []
            creationTool = nil
            componentCreationTool = nil
            pendingWallStart = nil
            focusedRoomID = nil
            let first = loaded.rooms.first?.walls.first?.id
            setSelection(first.map { [$0] } ?? [], primary: first)
            regenerate()
            statusMessage = "Opened \u{201C}\(loaded.displayName)\u{201D}."
            restoreSurveyEvidence()
            restoreUnderlay()
            refreshLibrary()
        } catch {
            statusMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    /// Deletes a library project. Deleting the open project closes it without saving it again.
    func deleteProject(_ id: UUID) {
        do {
            if project?.id == id {
                autosaveTask?.cancel()
                lastSavedProject = nil
                closeProject(saving: false)
            }
            try projectLibrary().delete(id)
            refreshLibrary()
            statusMessage = "Deleted project."
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func renameProject(_ name: String) {
        guard var next = project else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.name = trimmed.isEmpty ? nil : name
        commitSemanticProject(next, label: "Rename project", coalescingKey: "project-name")
    }

    /// v12.2 autosave: every project change is written to the library shortly after it happens.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.persistCurrentProject()
        }
    }

    /// Writes any pending change immediately. Called before the open project is replaced and when the app
    /// leaves the foreground, so a new scan or import can never discard unsaved work.
    @discardableResult
    func flushAutosave() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        return persistCurrentProject()
    }

    @discardableResult
    private func persistCurrentProject() -> Bool {
        guard let project else { return true }
        guard project != lastSavedProject else { return true }
        do {
            try projectLibrary().save(project)
            lastSavedProject = project
            return true
        } catch {
            statusMessage = "Autosave failed: \(error.localizedDescription)"
            return false
        }
    }

    func closeProject(saving: Bool = true) {
        if saving { flushAutosave() } else { autosaveTask?.cancel() }
        project = nil
        lastSavedProject = nil
        plyEvidenceProjectID = nil
        committedPLYEvidence = nil
        showPLYEvidenceOverlay = false
        plyImportModel.clear()
        setSelection([], primary: nil)
        resetEditHistory()
        multiSelectEnabled = false
        focusedRoomID = nil
        diagnostics = []
        clearPhysicalEditState(clearUndo: true)
        geometry = ArchitecturalGeometrySnapshot(
            planWallSegments: [],
            wallSolids: [],
            hostedOpenings: [],
            roomFloors: []
        )
        physicalGeometry = .empty
        derivation = nil
        representationMode = .semanticObservations
        orthoEnabled = false
        gridEnabled = false
        creationTool = nil
        componentCreationTool = nil
        pendingWallStart = nil
        importedDXFPreview = nil
        dxfImportDiagnostics = []
        statusMessage = saving ? "Closed project; it is kept in Projects." : "Closed project."
    }

    private func doorOperationLabel(_ operation: PlanOpsisDoor.Operation) -> String {
        switch operation {
        case .singleHinged: return "Single hinged door"
        case .doubleHinged: return "Double hinged door"
        case .sliding: return "Sliding door"
        case .pocket: return "Pocket door"
        }
    }

    private func windowOperationLabel(_ operation: PlanOpsisWindow.Operation) -> String {
        switch operation {
        case .fixed: return "Fixed window"
        case .singleCasement: return "Single casement window"
        case .doubleCasement: return "Double casement window"
        case .sliding: return "Sliding window"
        }
    }

    private func regenerate() {
        guard let project else {
            geometry = ArchitecturalGeometrySnapshot(
                planWallSegments: [],
                wallSolids: [],
                hostedOpenings: [],
                roomFloors: []
            )
            physicalGeometry = .empty
            derivation = nil
            return
        }
        // One geometry pass per project revision; drawing, annotations and readiness come with it.
        let next = ProjectDerivation(project: project, settings: derivationSettings, captureDiagnostics: diagnostics, reusing: derivation)
        geometry = next.semanticGeometry
        physicalGeometry = next.physicalGeometry
        derivation = next
        refreshDeviation()
        if project != lastSavedProject { scheduleAutosave() }
    }

    private static func describe(_ diagnostic: RoomPlanAdapter.Diagnostic) -> String {
        switch diagnostic {
        case .missingHost(let sourceID, let parentID):
            return "Opening \(short(sourceID)) has no imported host wall (RoomPlan parent \(parentID.map(short) ?? "nil"))."
        case .invalidWallDirection(let sourceID):
            return "Wall \(short(sourceID)) has an invalid plan direction and was skipped."
        case .invalidWallDimensions(let sourceID):
            return "Wall \(short(sourceID)) has invalid dimensions and was skipped."
        case .invalidOpeningDimensions(let sourceID):
            return "Opening \(short(sourceID)) has invalid dimensions and was skipped."
        case .unsupportedCurvedWall(let sourceID):
            return "Wall \(short(sourceID)) is curved and was imported as a straight wall. Check it against the room."
        case .unsupportedComplexWall(let sourceID, let count):
            return "Wall \(short(sourceID)) is not rectangular (\(count) corners) and was imported as a full-height straight wall. Check its height."
        case .openingExtendsBeyondHost(let sourceID, _):
            return "Opening \(short(sourceID)) extended beyond its host wall and was clipped to the wall."
        case .openingVerticalExtentOutsideHost(let sourceID, _):
            return "Opening \(short(sourceID)) extended below the floor or above its host wall and was clipped vertically."
        case .openingMostlyOutsideHost(let sourceID, _):
            return "Opening \(short(sourceID)) lay mostly outside its host wall and was not imported."
        case .unsupportedObject(let sourceID, let category):
            return "Object \(short(sourceID)) (\(category)) has no PlanOpsis kind and was not added."
        case .invalidObjectGeometry(let sourceID):
            return "Object \(short(sourceID)) had an empty box and was skipped."
        }
    }

    private static func describe(_ conflict: ReconciliationConflict) -> String {
        let magnitude = conflict.magnitudeMM.map { " (\($0.formatted(.number.precision(.fractionLength(0...1))))) mm" } ?? ""
        switch conflict.code {
        case .partitionEndpointMismatch:
            return "Physical partition endpoint disagreement remains unresolved\(magnitude)."
        case .partitionHeightMismatch:
            return "Physical partition height disagreement remains unresolved\(magnitude)."
        case .partitionThicknessMismatch:
            return "Physical partition thickness disagreement remains unresolved\(magnitude)."
        case .ambiguousSharedBoundary:
            return "Shared-wall evidence is ambiguous; the reconciliation layer did not fuse semantic walls."
        case .candidateSharedBoundary:
            return "Candidate shared wall was not promoted to a physical partition\(magnitude)."
        case .passageWithoutResolvedPartition:
            return "Cross-room passage has no resolved physical partition and was not canonicalized."
        case .passageCenterMismatch:
            return "Passage center disagreement remains unresolved\(magnitude)."
        case .passageWidthMismatch:
            return "Passage width disagreement remains unresolved\(magnitude)."
        case .passageHeightMismatch:
            return "Passage height disagreement remains unresolved\(magnitude)."
        case .passageSillMismatch:
            return "Passage sill disagreement remains unresolved\(magnitude)."
        }
    }

    private static func describe(_ issue: PhysicalDisplayIssue) -> String {
        switch issue.code {
        case .conflictedPartitionSemanticFallback:
            return "A conflicted physical partition is shown using its original semantic wall observations."
        case .conflictedPassageEvidenceOnly:
            return "A conflicted passage is shown as evidence only and does not cut the reconciled wall."
        case .sourceOpeningCouldNotProject:
            return "A single-sided opening observation could not be projected safely onto the physical partition."
        }
    }

    private static func describe(_ issue: PhysicalEditValidationIssue) -> String {
        let magnitude = issue.magnitudeMM.map { " (\($0.formatted(.number.precision(.fractionLength(0...1))))) mm" } ?? ""
        switch issue.code {
        case .partitionNotFound:
            return "The physical partition no longer exists. Regenerate and start a new edit."
        case .unresolvedPartition:
            return "This physical partition is unresolved/conflicted and cannot drive a semantic transaction."
        case .invalidTargetLength:
            return "Target wall length must be greater than zero."
        case .invalidTargetHeight:
            return "Target wall height must be greater than zero."
        case .invalidTargetThickness:
            return "Target wall thickness must be greater than zero."
        case .missingSourceWall:
            return "A source semantic wall is missing; transaction cannot be applied atomically."
        case .openingDoesNotFitLength:
            return "A hosted opening would extend beyond the edited wall\(magnitude)."
        case .openingExceedsWallHeight:
            return "A hosted opening would exceed the edited wall height\(magnitude)."
        case .staleSemanticState:
            return "Semantic state changed after preview; regenerate the transaction before applying."
        }
    }

    private static func describe(_ issue: StructureTopologyIssue) -> String {
        switch issue.code {
        case .openRoomBoundary:
            return "Room boundary is not a closed wall loop (\(issue.relatedCount) unmatched/unused endpoint condition(s))."
        case .ambiguousSharedBoundary:
            return "Wall \(issue.wallID.map(short) ?? "unknown") matches \(issue.relatedCount) possible shared partitions; keep this as unresolved evidence."
        }
    }

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
#endif
