#if os(iOS)
import SwiftUI

struct SurveyExchangeReviewView:View {
    @ObservedObject var store:PlanOpsisMobileStore
    var body:some View {
        NavigationStack {
            List {
                if let proposal=store.surveyImportProposal {
                    Section("Rhino changes") {
                        if proposal.changes.isEmpty { Text(proposal.canApply ? "No architectural or documentation changes." : "Drawing requires resolution.") }
                        ForEach(proposal.changes,id:\.self) { Text($0) }
                    }
                    if let before=store.project,let after=proposal.proposedProject { SurveyChangeDetails(before:before,after:after) }
                    Section("Review") {
                        ForEach(proposal.issues,id:\.self) { Text($0).foregroundStyle(.red) }
                        Text("Apply preserves project identity and records one undo step. The received DXF is retained for recovery.")
                        Button("Apply reviewed changes") { store.applySurveyReturn() }.disabled(!proposal.canApply)
                    }
                }
                if let status=store.statusMessage { Text(status).font(.caption) }
            }
            .navigationTitle("Review Rhino return")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { store.showSurveyImportReview=false } } }
        }
    }
}
struct SurveyChangeDetails:View {
    let before:PlanOpsisProject
    let after:PlanOpsisProject
    var body:some View {
        Section("Before → after") {
            ForEach(after.rooms) { room in
                let old=before.rooms.first{$0.id==room.id}
                ForEach(room.walls) { w in
                    if let prior=old?.walls.first(where:{$0.id==w.id}),prior != w {
                        Text("Wall \(w.id.uuidString.prefix(8)): \(prior.length, specifier:"%.1f") → \(w.length, specifier:"%.1f") mm; thickness \(prior.thickness, specifier:"%.1f") → \(w.thickness, specifier:"%.1f") mm")
                        Text("Start (\(w.start.x, specifier:"%.1f"), \(w.start.y, specifier:"%.1f")); end (\(w.end.x, specifier:"%.1f"), \(w.end.y, specifier:"%.1f"))").font(.caption)
                        ForEach(room.openings.filter{$0.parameters.hostWallID==w.id}) { o in
                            Text("Hosted \(o.kind.rawValue) \(o.id.uuidString.prefix(8)) follows this wall; offset \(o.parameters.offsetAlongWall, specifier:"%.1f") mm").font(.caption)
                        }
                    }
                }
                ForEach(room.openings) { o in
                    if let prior=old?.openings.first(where:{$0.id==o.id}),prior != o {
                        Text("Opening \(o.id.uuidString.prefix(8)): width \(prior.parameters.width, specifier:"%.1f") → \(o.parameters.width, specifier:"%.1f") mm; offset \(prior.parameters.offsetAlongWall, specifier:"%.1f") → \(o.parameters.offsetAlongWall, specifier:"%.1f") mm")
                    }
                }
                ForEach(room.components) { c in
                    if let prior=old?.components.first(where:{$0.id==c.id}),prior != c {
                        Text("\(c.kind.rawValue) \(c.id.uuidString.prefix(8)): (\(prior.position.x, specifier:"%.1f"), \(prior.position.y, specifier:"%.1f")) → (\(c.position.x, specifier:"%.1f"), \(c.position.y, specifier:"%.1f")) mm; rotation \(c.rotationRadians*180/Double.pi, specifier:"%.1f")°")
                    }
                }
            }
            ForEach(before.survey.observations) { o in
                let a=SurveyMeasurementEngine().evaluate(o,in:before)
                let b=SurveyMeasurementEngine().evaluate(o,in:after)
                if a != b {
                    Text("Check \(o.id.uuidString.prefix(8)): residual \(a.residualMM ?? 0, specifier:"%+.1f") → \(b.residualMM ?? 0, specifier:"%+.1f") mm · \(b.status.displayName)")
                }
            }
        }
    }
}
extension SurveyMeasurementEvaluation.Status {
    var displayName:String {
        switch self {
        case .unchecked:return "Unchecked"
        case .withinTolerance:return "Within declared tolerance"
        case .outsideTolerance:return "Outside declared tolerance"
        case .needsRecheck:return "Needs recheck"
        case .invalidReference:return "Invalid reference"
        }
    }
}
struct SurveyCorrectionReviewView:View {
    @ObservedObject var store:PlanOpsisMobileStore
    let observationID:UUID
    @Environment(\.dismiss) private var dismiss
    @State private var anchor=WallEndpointKind.start
    @State private var proposal:SurveyCorrectionProposal?
    var body:some View {
        NavigationStack {
            List {
                Section("Correction") {
                    Picker("Fixed endpoint",selection:$anchor) { Text("Start").tag(WallEndpointKind.start);Text("End").tag(WallEndpointKind.end) }
                    Button("Preview correction") {
                        if let p=store.project { proposal=SurveyCorrectionEngine().preview(observationID:observationID,anchor:anchor,project:p) }
                    }
                    Text("Face distances and diagonals remain checks; change their defining walls explicitly.").font(.caption)
                }
                if let proposal {
                    if let before=store.project,let after=proposal.proposedProject { SurveyChangeDetails(before:before,after:after) }
                    Section("Apply") {
                        ForEach(proposal.issues,id:\.self) { Text($0).foregroundStyle(.red) }
                        Button("Apply measured correction") { if store.applySurveyCorrection(proposal) { dismiss() } }.disabled(!proposal.canApply)
                    }
                }
            }.navigationTitle("Measured correction")
            .onChange(of:anchor) { _,_ in proposal=nil }
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
#endif
