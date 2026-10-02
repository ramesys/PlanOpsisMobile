#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// v11.9 PLY ingestion + human review workspace. The imported cloud and review state are owned by
/// PlanOpsisMobileStore, so navigation away from this screen does not discard the evidence.
struct PLYImportView: View {
    @ObservedObject var model: PLYImportViewModel
    @State private var showingPLYPicker = false
    @State private var exportedDXF: ExportableTextFile?

    let onCommit: (PLYReconstructionResult) -> Void

    init(model: PLYImportViewModel, onCommit: @escaping (PLYReconstructionResult) -> Void = { _ in }) {
        self.model = model
        self.onCommit = onCommit
    }

    var body: some View {
        Form {
            Section("Source") {
                Picker("PLY units", selection: $model.sourceUnit) {
                    ForEach(PLYLengthUnit.allCases, id: \.self) { unit in Text(unit.label).tag(unit) }
                }
                .pickerStyle(.segmented)

                Picker("Up axis", selection: $model.settings.upAxis) {
                    ForEach(PLYUpAxis.allCases, id: \.self) { axis in Text(axis.label).tag(axis) }
                }

                Text("Auto handles common Z-up survey files and Y-up mesh exports. Choose the source axis explicitly if the comparison appears rotated or sparse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        model.errorMessage = nil
                        showingPLYPicker = true
                    } label: {
                        Label(model.cloud == nil ? "Import PLY" : "Replace PLY", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(model.isWorking)

                    if model.cloud != nil {
                        Spacer()
                        Button("Clear", role: .destructive) { model.clear() }
                            .disabled(model.isWorking)
                    }
                }

                if let cloud = model.cloud {
                    LabeledContent("File", value: cloud.sourceName)
                    LabeledContent("Points", value: cloud.points.count.formatted())
                    if let b = cloud.boundsInSourceUnits {
                        LabeledContent("Bounds", value: String(format: "%.2f × %.2f × %.2f %@", b.width, b.depth, b.height, cloud.sourceUnit.label))
                    }
                    Text("PLY evidence and review decisions remain available while moving between PLY, Plan, 3D and DXF during this app session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.cloud != nil {
                Section("Plan section") {
                    parameter("Height", value: $model.settings.sectionHeightMM, range: 250...2400, step: 50, suffix: "mm")
                    parameter("Thickness", value: $model.settings.sectionThicknessMM, range: 50...700, step: 10, suffix: "mm")
                    parameter("Voxel", value: $model.settings.voxelSizeMM, range: 10...150, step: 5, suffix: "mm")
                    parameter("Line tolerance", value: $model.settings.lineToleranceMM, range: 10...200, step: 5, suffix: "mm")
                    parameter("Min segment", value: $model.settings.minSegmentLengthMM, range: 200...2000, step: 50, suffix: "mm")
                    parameter("Assumed wall thickness", value: $model.settings.defaultWallThicknessMM, range: 70...400, step: 10, suffix: "mm")
                    parameter("Wall height", value: $model.settings.defaultWallHeightMM, range: 1800...5000, step: 50, suffix: "mm")

                    Toggle("Allow single visible wall surfaces", isOn: $model.settings.allowSingleSurfaceWalls)
                    Toggle("Register scan face to wall interior", isOn: $model.settings.registerSingleSurfaceAsInteriorFace)
                        .disabled(!model.settings.allowSingleSurfaceWalls)
                    Toggle("Professional wall cleanup", isOn: $model.settings.professionalCleanup)
                    if model.settings.professionalCleanup {
                        parameter("Wall continuity", value: $model.settings.wallContinuityGapMM, range: 300...2500, step: 50, suffix: "mm")
                    }
                    Toggle("Noise suppression + reconstruction QA", isOn: $model.settings.noiseSuppressionEnabled)
                    if model.settings.noiseSuppressionEnabled {
                        parameter("QA support distance", value: $model.settings.qaWallSupportDistanceMM, range: 60...300, step: 10, suffix: "mm")
                    }
                    Toggle("Detect structural candidates", isOn: $model.settings.detectStructuralElements)
                    if model.settings.detectStructuralElements {
                        parameter("Structural grid", value: $model.settings.structuralGridMM, range: 60...240, step: 10, suffix: "mm")
                        parameter("Beam width", value: $model.settings.defaultBeamWidthMM, range: 120...600, step: 10, suffix: "mm")
                        parameter("Beam depth", value: $model.settings.defaultBeamDepthMM, range: 150...800, step: 10, suffix: "mm")
                    }

                    Button { model.reconstruct() } label: {
                        Label("Reconstruct Plan", systemImage: "wand.and.rays")
                    }
                    .disabled(model.isWorking)
                }
            }

            if let raw = model.result, let reviewed = model.previewResult {
                Section("Exact commit preview") {
                    PLYPlanPreview(result: reviewed, showWallLabels: true)
                        .frame(minHeight: 340)

                    Text("Grey = measured PLY. White = fitted scan lines. Blue = geometry currently selected for commit. Red dashed = excluded evidence. W1, W2… identify the post-review semantic wall network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Up axis used", value: raw.upAxisUsed.label)
                    LabeledContent("Section used", value: String(format: "%.0f mm", raw.sectionHeightUsedMM))
                    LabeledContent("Section points", value: raw.sectionPointCount.formatted())
                    LabeledContent("Downsampled", value: raw.downsampledPointCount.formatted())
                    LabeledContent("Detected lines", value: raw.segments.count.formatted())
                    LabeledContent("Raw wall candidates", value: raw.wallAssessments.count.formatted())
                    LabeledContent("Walls selected", value: reviewed.wallSeeds.count.formatted())
                    LabeledContent("Structure selected", value: reviewed.structuralSeeds.count.formatted())

                    Divider()
                    HStack {
                        Text("Post-review QA")
                        Spacer()
                        Text(reviewed.qa.status.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(qaColor(reviewed.qa.status))
                    }
                    LabeledContent("Wall-supported evidence", value: String(format: "%.0f%%", reviewed.qa.wallSupportFraction * 100))
                    if let mean = reviewed.qa.meanSupportedResidualMM {
                        LabeledContent("Mean scan→wall residual", value: String(format: "%.0f mm", mean))
                    }
                    if let p95 = reviewed.qa.p95SupportedResidualMM {
                        LabeledContent("95% scan→wall residual", value: String(format: "%.0f mm", p95))
                    }
                    LabeledContent("Unresolved wall ends", value: reviewed.qa.unresolvedWallEnds.formatted())
                    LabeledContent("Semantic wall length", value: String(format: "%.2f m", reviewed.qa.semanticWallLengthMM / 1000.0))

                    if let guidance = model.detectionGuidance {
                        Text(guidance)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Wall decisions") {
                    Toggle("Repair selected wall topology before commit", isOn: $model.repairReviewedTopology)
                    Text("When enabled, only your included walls are re-merged and their corner/T-junction intersections are solved. Scan-face registration is not applied twice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Automatic only") { model.resetReviewToAutomatic() }
                        Spacer()
                        Button("Include review walls") { model.includeReviewWalls() }
                    }
                    .font(.caption)

                    ForEach(Array(raw.wallAssessments.prefix(40).enumerated()), id: \.element.id) { index, assessment in
                        Toggle(isOn: model.wallInclusionBinding(assessment)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("W\(index + 1) · \(String(format: "%.2f m", assessment.seed.lengthMM / 1000.0))")
                                    Text(assessment.status.label.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(candidateColor(assessment.status))
                                }
                                Text("QA \(Int((assessment.score * 100).rounded()))% · \(assessment.reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if raw.wallAssessments.count > 40 {
                        Text("Showing the first 40 wall candidates. Tighten reconstruction settings before manually reviewing a larger candidate set.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !raw.structuralAssessments.isEmpty {
                    Section("Structural decisions") {
                        Text("Structure remains geometric inference. Only enabled candidates become PlanOpsis columns/beams; this does not certify structural function or capacity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Exclude all structure") { model.excludeAllStructure() }
                            Spacer()
                            Button("Include plausible") { model.includePlausibleStructure() }
                        }
                        .font(.caption)

                        ForEach(Array(raw.structuralAssessments.prefix(30).enumerated()), id: \.element.id) { index, assessment in
                            Toggle(isOn: model.structuralInclusionBinding(assessment)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("\(assessment.seed.kind.label) S\(index + 1)")
                                        Text(assessment.status.label.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(candidateColor(assessment.status))
                                    }
                                    Text("QA \(Int((assessment.score * 100).rounded()))% · \(assessment.reason)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Create") {
                    Button {
                        if let commit = model.resultForCommit { onCommit(commit) }
                    } label: {
                        Label(model.commitStructuralCount == 0 ? "Create Reviewed Room" : "Create Reviewed Room + Structure", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.commitWallCount == 0 || model.isWorking)

                    Button {
                        if let dxf = model.makePreviewDXF() { exportedDXF = ExportableTextFile(text: dxf) }
                    } label: {
                        Label("Inspect Reviewed Diagnostic DXF", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }

            if model.isWorking {
                Section { ProgressView(model.cloud == nil ? "Importing PLY…" : "Reconstructing…") }
            }

            if let message = model.errorMessage {
                Section("Error") {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.settings) { oldValue, newValue in
            if oldValue != newValue { model.invalidateReconstruction() }
        }
        .fullScreenCover(isPresented: $showingPLYPicker) {
            PLYDocumentPicker(
                onPick: { url in showingPLYPicker = false; model.importPLY(url: url) },
                onCancel: { showingPLYPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $exportedDXF) { file in
            NavigationStack {
                ScrollView {
                    Text(file.text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Reviewed Diagnostic DXF")
            }
        }
    }

    @ViewBuilder
    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)").foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func candidateColor(_ status: PLYCandidateStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .review: return .orange
        case .suppressed: return .red
        }
    }

    private func qaColor(_ status: PLYQAStatus) -> Color {
        switch status {
        case .pass: return .green
        case .review: return .orange
        case .fail: return .red
        }
    }
}

private struct PLYDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct ExportableTextFile: Identifiable {
    let id = UUID()
    let text: String
}
#endif
