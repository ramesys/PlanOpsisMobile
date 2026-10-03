#if os(iOS)
import SwiftUI

/// v12.7 the survey compared with the aligned drawing: totals, each wall and opening, and what the
/// drawing has that the survey does not.
struct DeviationReportView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var csvURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let deviation = store.deviation {
                    List {
                        summary(deviation)
                        if !deviation.walls.isEmpty {
                            Section("Walls") {
                                ForEach(deviation.walls) { row in wallRow(row) }
                            }
                        }
                        if !deviation.openings.isEmpty {
                            Section("Doors, windows and openings") {
                                ForEach(deviation.openings) { row in openingRow(row) }
                            }
                        }
                        if !deviation.missingWalls.isEmpty || !deviation.missingOpenings.isEmpty {
                            Section {
                                if !deviation.missingWalls.isEmpty {
                                    LabeledContent("Walls", value: "\(deviation.missingWalls.count)")
                                }
                                if !deviation.missingOpenings.isEmpty {
                                    LabeledContent("Doors and windows", value: "\(deviation.missingOpenings.count)")
                                }
                            } header: {
                                Text("In the drawing, not surveyed")
                            } footer: {
                                Text("Shown dashed in purple on the plan.")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No comparison", systemImage: "ruler",
                                           description: Text("Align a drawing under the plan, then choose Compare with drawing."))
                }
            }
            .navigationTitle("Survey against drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let csvURL {
                        ShareLink(item: csvURL) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: store.deviation?.walls.count) { writeCSV() }
        }
    }

    private func summary(_ deviation: DeviationAnalysis) -> some View {
        let counts = deviation.summary
        return Section {
            ForEach(DeviationAnalysis.Status.allCases, id: \.self) { status in
                HStack {
                    Circle().fill(FloorPlanView.deviationColor(status)).frame(width: 10, height: 10)
                    Text(status.title)
                    Spacer()
                    Text("\(counts[status] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LabeledContent("Largest wall deviation", value: "\(Int(deviation.largestOffset.rounded())) mm")
            Toggle("Show on the plan", isOn: $store.showDeviation)
        } header: {
            Text("Summary")
        } footer: {
            Text("Within \(Int(deviation.tolerances.ok)) mm is within tolerance; up to \(Int(deviation.tolerances.warning)) mm is worth a check. Walls are measured at their ends, so a turned wall shows too.")
        }
    }

    private func wallRow(_ row: DeviationAnalysis.WallRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(FloorPlanView.deviationColor(row.status)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.subheadline.weight(.semibold))
                Text(row.room).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let end = row.endDeviation {
                    Text("\(Int(end.rounded())) mm").font(.subheadline.monospacedDigit())
                    Text(details(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("Not in the drawing").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(row.wallID)
            dismiss()
        }
    }

    private func details(_ row: DeviationAnalysis.WallRow) -> String {
        var parts: [String] = []
        if let offset = row.offset, offset >= 1 { parts.append("\(Int(offset.rounded())) \(row.direction ?? "")") }
        if let angle = row.angleDegrees, abs(angle) >= 0.1 { parts.append(String(format: "%+.1f°", angle)) }
        if let thickness = row.thicknessDifference, abs(thickness) >= 5 { parts.append(String(format: "t %+.0f", thickness)) }
        return parts.joined(separator: " · ")
    }

    private func openingRow(_ row: DeviationAnalysis.OpeningRow) -> some View {
        HStack {
            Circle().fill(FloorPlanView.deviationColor(row.status)).frame(width: 10, height: 10)
            Text(row.mark).font(.subheadline.weight(.semibold))
            Spacer()
            if let position = row.positionDifference, let width = row.widthDifference {
                Text("\(Int(position.rounded())) mm · width \(String(format: "%+.0f", width))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("Not in the drawing").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func writeCSV() {
        guard let data = store.exportDeviationCSV() else { csvURL = nil; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(store.exportBaseName) - Deviations.csv")
        do {
            try data.write(to: url, options: .atomic)
            csvURL = url
        } catch {
            csvURL = nil
        }
    }
}
#endif
