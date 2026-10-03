import Foundation

/// v12.1 everything the editor shows that is derived from one project revision, computed in one pass.
///
/// Before v12.1 the editor recomputed the drawing preview, plan annotations and export readiness on
/// every SwiftUI access, re-running the full geometry pipeline several times per drag tick. Build a
/// derivation when the project or a view setting changes and read its stored values instead.
public struct ProjectDerivation: Sendable {
    public struct Settings: Hashable, Sendable {
        public var representation: GeometryRepresentationMode
        public var focusedRoomID: UUID?
        public var includeOpeningDimensions: Bool
        public var surveyDrawing: Bool
        /// v12.4 opening marks on the plan and in the drawing.
        public var includeTags: Bool

        public init(
            representation: GeometryRepresentationMode = .semanticObservations,
            focusedRoomID: UUID? = nil,
            includeOpeningDimensions: Bool = false,
            surveyDrawing: Bool = false,
            includeTags: Bool = false
        ) {
            self.includeTags = includeTags
            self.representation = representation
            self.focusedRoomID = focusedRoomID
            self.includeOpeningDimensions = includeOpeningDimensions
            self.surveyDrawing = surveyDrawing
        }
    }

    public let project: PlanOpsisProject
    public let settings: Settings
    public let semanticGeometry: ArchitecturalGeometrySnapshot
    public let physicalGeometry: DisplayGeometrySnapshot
    /// Full drawing for the DXF preview and export (never focus-scoped).
    public let drawing: DXFPreviewSnapshot
    /// Dimension and room-text primitives for the plan canvas, scoped to the focused room.
    public let annotations: [DXFPrimitive]
    public let readiness: ArchitecturalSurveyReadinessReport

    /// - Parameter reusing: a derivation of the same project; its geometry is reused when only view
    ///   settings or capture diagnostics changed.
    public init(
        project: PlanOpsisProject,
        settings: Settings = Settings(),
        captureDiagnostics: [RoomPlanAdapter.Diagnostic] = [],
        reusing previous: ProjectDerivation? = nil
    ) {
        let semantic: ArchitecturalGeometrySnapshot
        let physical: DisplayGeometrySnapshot
        if let previous, previous.project == project {
            semantic = previous.semanticGeometry
            physical = previous.physicalGeometry
        } else {
            semantic = ParametricGeometryEngine().generate(from: project)
            physical = PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semantic)
        }
        let engine = DXFExchangeEngine(includeOpeningDimensions: settings.includeOpeningDimensions, surveyDrawing: settings.surveyDrawing, includeTags: settings.includeTags)
        let drawing = engine.preview(for: project, representation: settings.representation, semanticGeometry: semantic, physicalGeometry: physical)

        self.project = project
        self.settings = settings
        self.semanticGeometry = semantic
        self.physicalGeometry = physical
        self.drawing = drawing
        if let focused = settings.focusedRoomID {
            // Room-scoped drafting differs from the whole drawing (shared dimensions, fit extents).
            annotations = engine.annotations(for: project, focusedRoomID: focused, representation: settings.representation)
        } else {
            annotations = drawing.primitives.filter(Self.isPlanAnnotation)
        }
        readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: project, geometry: semantic, captureDiagnostics: captureDiagnostics)
    }

    static func isPlanAnnotation(_ primitive: DXFPrimitive) -> Bool {
        primitive.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue ||
        primitive.layer == ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue ||
        primitive.layer == ArchitecturalDraftingConvention.Layer.tags.rawValue
    }
}
