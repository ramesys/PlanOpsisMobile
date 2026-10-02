import Foundation

/// v12.1 retention of raw capture evidence.
///
/// The semantic project is what PlanOpsis edits; the capture snapshot is what was observed. Keeping the
/// snapshot as a hashed project attachment lets a project be re-reconstructed with newer adapters,
/// audited against its scan, and used as a benchmark case for reconstruction research.
public enum CaptureEvidence {
    /// Canonical, byte-stable encoding (sorted keys) so identical captures hash identically.
    public static func encode(_ snapshot: StructureCaptureSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> StructureCaptureSnapshot {
        try JSONDecoder().decode(StructureCaptureSnapshot.self, from: data)
    }

    /// Stores the snapshot in the project's attachment store and returns the evidence reference to append
    /// to `project.survey.evidence`.
    public static func retain(
        _ snapshot: StructureCaptureSnapshot,
        projectID: UUID,
        in store: SurveyAttachmentStore
    ) throws -> SurveyEvidenceReference {
        try store.importAsset(
            data: encode(snapshot),
            projectID: projectID,
            kind: .roomPlanCapture,
            sourceName: "RoomPlan capture \(snapshot.rooms.count) room\(snapshot.rooms.count == 1 ? "" : "s")"
        )
    }

    /// The most recent retained capture of a project, verified against its hash.
    public static func latestCapture(of project: PlanOpsisProject, in store: SurveyAttachmentStore) throws -> StructureCaptureSnapshot? {
        guard let reference = project.survey.evidence.last(where: { $0.kind == .roomPlanCapture }) else { return nil }
        return try decode(store.readVerified(reference, projectID: project.id))
    }

    /// Re-runs the RoomPlan adapter on a retained capture.
    public static func replay(
        _ project: PlanOpsisProject,
        in store: SurveyAttachmentStore,
        adapter: RoomPlanAdapter = RoomPlanAdapter()
    ) throws -> RoomPlanAdapter.Result? {
        try latestCapture(of: project, in: store).map(adapter.adapt)
    }
}
