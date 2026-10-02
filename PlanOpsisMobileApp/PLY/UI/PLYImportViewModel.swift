#if os(iOS)
import Foundation
import SwiftUI

@MainActor
final class PLYImportViewModel: ObservableObject {
    private(set) var sourceSHA256:String?
    @Published var sourceUnit: PLYLengthUnit = .meters {
        didSet {
            guard sourceUnit != oldValue else { return }
            invalidateWorkRevision()
            if var existing = cloud {
                existing.sourceUnit = sourceUnit
                cloud = existing
            }
            result = nil
            resetReviewToAutomatic()
            invalidatePreviewCache()
            isWorking = false
        }
    }

    @Published var settings = PLYSectionSettings()
    @Published private(set) var cloud: PLYPointCloud?
    @Published private(set) var result: PLYReconstructionResult?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    /// v11.9 review state. Absence means "use the detector's QA decision". This lets a reviewer
    /// reject an automatic accept, promote a review/suppressed candidate, or remove uncertain
    /// structure without mutating the original evidence result.
    @Published private(set) var wallInclusionOverrides: [UUID: Bool] = [:]
    @Published private(set) var structuralInclusionOverrides: [UUID: Bool] = [:]
    @Published var repairReviewedTopology = true {
        didSet {
            guard repairReviewedTopology != oldValue else { return }
            invalidatePreviewCache()
        }
    }

    /// Monotonic revision prevents a completed background import/reconstruction from overwriting
    /// newer settings or a newer file selection. The synchronous core algorithms remain pure; stale
    /// background results are simply discarded at the MainActor boundary.
    private var workRevision: UInt64 = 0
    private var previewRevision: UInt64 = 0
    private var cachedPreviewRevision: UInt64?
    private var cachedPreviewResult: PLYReconstructionResult?

    var previewResult: PLYReconstructionResult? {
        guard var reviewed = result else { return nil }
        if cachedPreviewRevision == previewRevision {
            return cachedPreviewResult
        }

        let allWalls = reviewed.wallAssessments
        let chosenWallSeeds = allWalls
            .filter { wallIncluded($0) }
            .map(\.seed)
        let finalWalls = repairReviewedTopology
            ? PLYWallCandidateEngine().refineReviewedWallNetwork(chosenWallSeeds, settings: settings)
            : chosenWallSeeds

        let allStructure = reviewed.structuralAssessments
        let chosenStructure = allStructure
            .filter { structuralIncluded($0) }
            .map(\.seed)

        let excludedWalls = allWalls.filter { !wallIncluded($0) }.map(\.seed)
        let excludedStructure = allStructure.filter { !structuralIncluded($0) }.map(\.seed)

        reviewed.wallSeeds = finalWalls
        reviewed.reviewWallSeeds = []
        reviewed.suppressedWallSeeds = excludedWalls
        reviewed.structuralSeeds = chosenStructure
        reviewed.reviewStructuralSeeds = []
        reviewed.suppressedStructuralSeeds = excludedStructure
        reviewed.qa = PLYReconstructionQAEngine().reviewedReport(
            sectionPoints: reviewed.sectionPointsMM,
            segments: reviewed.segments,
            walls: finalWalls,
            structure: chosenStructure,
            settings: settings
        )
        cachedPreviewRevision = previewRevision
        cachedPreviewResult = reviewed
        return reviewed
    }

    var resultForCommit: PLYReconstructionResult? { previewResult }
    var commitWallCount: Int { previewResult?.wallSeeds.count ?? 0 }
    var commitStructuralCount: Int { previewResult?.structuralSeeds.count ?? 0 }

    func wallIncluded(_ assessment: PLYWallAssessment) -> Bool {
        wallInclusionOverrides[assessment.id] ?? (assessment.status == .accepted)
    }

    func structuralIncluded(_ assessment: PLYStructuralAssessment) -> Bool {
        structuralInclusionOverrides[assessment.id] ?? (assessment.status == .accepted)
    }

    func wallInclusionBinding(_ assessment: PLYWallAssessment) -> Binding<Bool> {
        Binding(
            get: { self.wallIncluded(assessment) },
            set: { enabled in
                self.wallInclusionOverrides[assessment.id] = enabled
                self.invalidatePreviewCache()
            }
        )
    }

    func structuralInclusionBinding(_ assessment: PLYStructuralAssessment) -> Binding<Bool> {
        Binding(
            get: { self.structuralIncluded(assessment) },
            set: { enabled in
                self.structuralInclusionOverrides[assessment.id] = enabled
                self.invalidatePreviewCache()
            }
        )
    }

    func resetReviewToAutomatic() {
        if !wallInclusionOverrides.isEmpty || !structuralInclusionOverrides.isEmpty {
            wallInclusionOverrides.removeAll()
            structuralInclusionOverrides.removeAll()
            invalidatePreviewCache()
        }
    }

    func includeReviewWalls() {
        guard let result else { return }
        var changed = false
        for assessment in result.wallAssessments where assessment.status == .review {
            if wallInclusionOverrides[assessment.id] != true {
                wallInclusionOverrides[assessment.id] = true
                changed = true
            }
        }
        if changed { invalidatePreviewCache() }
    }

    func excludeAllStructure() {
        guard let result else { return }
        var changed = false
        for assessment in result.structuralAssessments {
            if structuralInclusionOverrides[assessment.id] != false {
                structuralInclusionOverrides[assessment.id] = false
                changed = true
            }
        }
        if changed { invalidatePreviewCache() }
    }

    func includePlausibleStructure() {
        guard let result else { return }
        var changed = false
        for assessment in result.structuralAssessments where assessment.status != .suppressed {
            if structuralInclusionOverrides[assessment.id] != true {
                structuralInclusionOverrides[assessment.id] = true
                changed = true
            }
        }
        if changed { invalidatePreviewCache() }
    }

    var detectionGuidance: String? {
        guard let result else { return nil }
        if result.sectionPointCount == 0 {
            return "No points intersect the plan section. Check PLY units and Up axis, or lower the section height / increase thickness."
        }
        if result.downsampledPointCount < max(12, settings.minLineSupport) {
            return "The selected section is very sparse. Increase section thickness or reduce voxel size."
        }
        if result.segments.isEmpty {
            return "Section points were found but no stable lines were fitted. Increase line tolerance, reduce minimum segment length, or select the correct Up axis."
        }
        if result.wallAssessments.isEmpty {
            return "Lines were detected but no wall candidate survived geometric reconstruction. Check units/up-axis before relaxing tolerances."
        }
        if let reviewed = previewResult {
            let qa = reviewed.qa
            if qa.status == .pass {
                return "Reviewed geometry passes the current reconstruction QA gate. Compare the grey PLY evidence with the exact commit preview before creating the semantic project."
            }
            if qa.unresolvedWallEnds > 0 {
                return "Reviewed geometry still has \(qa.unresolvedWallEnds) unresolved wall end(s). Toggle doubtful candidates or adjust Wall continuity only where the PLY evidence supports a connection."
            }
            return "Reviewed geometry remains in QA review. Use the exact commit preview and candidate decisions rather than promoting all detected geometry."
        }
        return nil
    }

    func importPLY(url: URL) {
        guard url.pathExtension.lowercased() == "ply" else {
            errorMessage = "Choose a .ply point-cloud file."
            return
        }

        let revision = nextWorkRevision()
        isWorking = true
        errorMessage = nil
        result = nil
        resetReviewToAutomatic()
        invalidatePreviewCache()
        let unit = sourceUnit

        Task {
            do {
                let parsedCloud = try await Task.detached(priority: .userInitiated) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
                    return (try PLYParser().parse(data:bytes,sourceName:url.lastPathComponent,unit:unit),SurveyHash.data(bytes))
                }.value

                guard revision == self.workRevision else { return }
                self.cloud = parsedCloud.0
                self.sourceSHA256 = parsedCloud.1
                self.isWorking = false
                self.reconstruct()
            } catch is CancellationError {
                guard revision == self.workRevision else { return }
                self.errorMessage = "PLY import was cancelled."
                self.isWorking = false
            } catch {
                guard revision == self.workRevision else { return }
                self.errorMessage = "PLY import failed: \(error.localizedDescription)"
                self.isWorking = false
            }
        }
    }

    func reconstruct() {
        guard let cloud, !isWorking else { return }
        let revision = nextWorkRevision()
        isWorking = true
        errorMessage = nil
        let settingsSnapshot = settings
        resetReviewToAutomatic()
        invalidatePreviewCache()

        Task {
            let reconstructed = await Task.detached(priority: .userInitiated) {
                PLYSectionReconstructor().reconstruct(cloud: cloud, settings: settingsSnapshot)
            }.value
            guard revision == self.workRevision else { return }
            self.result = reconstructed
            self.invalidatePreviewCache()
            self.isWorking = false
        }
    }

    func invalidateReconstruction() {
        invalidateWorkRevision()
        result = nil
        resetReviewToAutomatic()
        invalidatePreviewCache()
        // A detached pure reconstruction may still finish in the background, but its revision is now
        // stale and cannot overwrite this state. Re-enable interaction immediately for the new settings.
        isWorking = false
    }

    func clear() {
        invalidateWorkRevision()
        cloud = nil
        sourceSHA256=nil
        result = nil
        errorMessage = nil
        resetReviewToAutomatic()
        invalidatePreviewCache()
        isWorking = false
    }

    private func nextWorkRevision() -> UInt64 {
        workRevision &+= 1
        return workRevision
    }

    private func invalidateWorkRevision() {
        workRevision &+= 1
    }

    private func invalidatePreviewCache() {
        previewRevision &+= 1
        cachedPreviewRevision = nil
        cachedPreviewResult = nil
    }

    func makePreviewDXF() -> String? {
        guard let result = previewResult else { return nil }
        return PLYDXFPreviewExporter().makeDXF(result: result)
    }
}
#endif
