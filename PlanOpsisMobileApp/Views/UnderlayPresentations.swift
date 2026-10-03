#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// v12.6 the PDF underlay picker, the alignment scale choice and the calibration distance prompt.
struct UnderlayPresentations: ViewModifier {
    @ObservedObject var store: PlanOpsisMobileStore
    @Binding var showingPDFImporter: Bool
    @Binding var mode: PlanOpsisViewMode
    @State private var calibrationText = ""

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    Task {
                        if await store.openPDFUnderlay(data: data, name: url.deletingPathExtension().lastPathComponent), store.project != nil {
                            mode = .plan
                        }
                    }
                } catch {
                    store.statusMessage = "PDF underlay failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog(
                "The drawing and the plan differ in scale",
                isPresented: Binding(get: { store.pendingAlignmentScale != nil }, set: { if !$0 { store.pendingAlignmentScale = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(format: "Scale the underlay to fit (×%.4g)", store.pendingAlignmentScale ?? 1)) { store.applyUnderlayAlignment(matchScale: true) }
                Button("Keep the drawing's scale") { store.applyUnderlayAlignment(matchScale: false) }
                Button("Pick again", role: .cancel) { store.undoUnderlayAlignmentPoint() }
            } message: {
                Text("Between the picked points the drawing measures \(String(format: "%.3g", store.pendingAlignmentScale ?? 1))× the plan. Scale it when its units are wrong; keep it when the points were only approximate.")
            }
            .alert("Real distance", isPresented: Binding(get: { store.needsCalibrationLength }, set: { _ in })) {
                TextField("Millimetres", text: $calibrationText)
                    .keyboardType(.decimalPad)
                Button("Calibrate") {
                    let value = Double(calibrationText.replacingOccurrences(of: ",", with: ".")) ?? 0
                    store.applyUnderlayCalibration(knownLength: value)
                }
                Button("Pick again", role: .cancel) { store.undoUnderlayAlignmentPoint() }
            } message: {
                Text("Enter the true distance between the two points in millimetres. They measure \(Int((store.underlayAlignment?.measuredLength ?? 0).rounded())) mm now.")
            }
            .onChange(of: store.needsCalibrationLength) { _, needed in
                if needed { calibrationText = "" }
            }
            .sheet(isPresented: $store.showDeviationReport) {
                DeviationReportView(store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}
#endif
