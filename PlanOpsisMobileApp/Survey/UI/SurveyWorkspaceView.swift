#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct SurveyWorkspaceView: View {
    @ObservedObject var store:PlanOpsisMobileStore
    @State private var target:SurveyMeasurementTarget?
    @State private var value=""
    @State private var tolerance=""
    @State private var unit=SurveyUnit.mm
    @State private var method="Laser / tape"
    @State private var errorMessage:String?
    @State private var correctionID:UUID?
    @State private var showCorrection=false
    @State private var checkDistance=false
    @State private var from:SurveyPoint?
    @State private var to:SurveyPoint?
    @State private var importReturn=false
    @State private var importManifest=false
    var body:some View {
        Form {
            if let project=store.project {
                Section("Rooms") {
                    ForEach(project.rooms) { room in
                        TextField("Room name",text:Binding(get:{store.project?.survey.roomNames[room.id] ?? ""},set:{store.renameRoom(room.id,name:$0)}))
                    }
                }
                Section("Field measurement") {
                    Toggle("Face distance / diagonal check",isOn:$checkDistance)
                    if checkDistance {
                        SurveyPointPicker(title:"From",project:project,point:$from)
                        SurveyPointPicker(title:"To",project:project,point:$to)
                    } else {
                    Picker("Parameter",selection:$target) {
                        Text("Choose a parameter").tag(Optional<SurveyMeasurementTarget>.none)
                        ForEach(project.rooms) { room in
                            ForEach(Array(room.walls.enumerated()),id:\.element.id) { index,wall in
                                Text("Wall \(index+1) · axis length").tag(Optional(SurveyMeasurementTarget.wallLength(roomID:room.id,wallID:wall.id)))
                                Text("Wall \(index+1) · thickness").tag(Optional(SurveyMeasurementTarget.wallThickness(roomID:room.id,wallID:wall.id)))
                            }
                            ForEach(Array(room.openings.enumerated()),id:\.element.id) { index,opening in
                                Text("Opening \(index+1) · width").tag(Optional(SurveyMeasurementTarget.openingWidth(roomID:room.id,openingID:opening.id)))
                            }
                        }
                    }
                    }
                    Picker("Units",selection:$unit) { ForEach(SurveyUnit.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    TextField("Observed value",text:$value).keyboardType(.decimalPad)
                    TextField("Tolerance (optional, same units)",text:$tolerance).keyboardType(.decimalPad)
                    TextField("Method",text:$method)
                    Button("Record measurement") { record() }.disabled(checkDistance ? (from==nil || to==nil):target==nil)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Text("Axis length and clear face distance are different measurements. No tolerance means no accuracy pass/fail.").font(.caption)
                }
                Section("Measured checks") {
                    ForEach(project.survey.observations) { o in
                        let evaluation=SurveyMeasurementEngine().evaluate(o,in:project)
                        VStack(alignment:.leading,spacing:6) {
                            Text(String(format:"Observed %.3f mm",o.observedMM))
                            Text(evaluation.currentMM.map { String(format:"Model %.3f mm · residual %+.3f mm",$0,evaluation.residualMM ?? 0) } ?? "Invalid reference").font(.caption)
                            Text(evaluation.status.displayName).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Verify") { store.verifyObservation(o.id) }
                                Button("Correct") { correctionID=o.id;showCorrection=true }
                                Button("Remove",role:.destructive) { store.removeObservation(o.id) }
                            }.buttonStyle(.borderless)
                            Toggle("Lock within tolerance",isOn:Binding(get:{o.locked},set:{store.setSurveyLock(o.id,locked:$0)}))
                        }
                    }
                }
                Section("Evidence and delivery") {
                    NavigationLink("Photos and evidence") { SurveyEvidenceView(store:store) }
                    NavigationLink("Export / open survey folder") { SurveyDeliveryView(store:store) }
                }
                Section("Drawing") {
                    Picker("Scale",selection:Binding(get:{project.survey.settings.scale},set:{store.setSurveyScale($0)})) {
                        ForEach([20,50,100],id:\.self) { Text("1:\($0)").tag($0) }
                    }
                    Toggle("Opening chains",isOn:Binding(get:{project.survey.settings.showChains},set:{ var settings=project.survey.settings;settings.showChains=$0;store.setSurveySettings(settings) }))
                    Toggle("Overall dimensions",isOn:Binding(get:{project.survey.settings.showOverall},set:{ var settings=project.survey.settings;settings.showOverall=$0;store.setSurveySettings(settings) }))
                    Picker("Precision",selection:Binding(get:{project.survey.settings.precision},set:{ var settings=project.survey.settings;settings.precision=$0;store.setSurveySettings(settings) })) { ForEach(0...3,id:\.self) { Text("\($0) decimal places").tag($0) } }
                    NavigationLink("Dimension placement") { SurveyDimensionPlacementView(store:store) }
                    Picker("DXF profile",selection:$store.dxfExportProfile) {
                        Text("Compatible drawing").tag(DXFExportProfile.compatible)
                        Text("Editable Rhino drawing").tag(DXFExportProfile.rhinoEditable)
                    }
                    Text("Use Export DXF from the app menu after selecting the profile. Rhino edits require the originating project and export baseline.").font(.caption)
                    Button("Review returned Rhino DXF") { importReturn=true }
                    Button("Load exchange manifest") { importManifest=true }
                    Button("Save survey") { store.save() }
                    Text(store.statusMessage ?? "Survey values and evidence references are saved with the project.").font(.caption)
                }
            } else { Text("Scan, import, or open a project to start a survey.");NavigationLink("Open survey folder") { SurveyDeliveryView(store:store) } }
        }
        .sheet(isPresented:$showCorrection) {
            if let correctionID { SurveyCorrectionReviewView(store:store,observationID:correctionID) }
        }
        .fileImporter(isPresented:$importReturn,allowedContentTypes:[.planOpsisDXF,.plainText]) { result in
            do {
                let url=try result.get(),access=url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                store.previewSurveyReturn(try String(contentsOf:url,encoding:.utf8))
            } catch { store.statusMessage=error.localizedDescription }
        }
        .fileImporter(isPresented:$importManifest,allowedContentTypes:[.json]) { result in
            do {
                let url=try result.get(),access=url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                store.retainSurveyManifest(try Data(contentsOf:url))
            } catch { store.statusMessage=error.localizedDescription }
        }
    }
    private func record() {
        let selected:SurveyMeasurementTarget? = checkDistance ? from.flatMap { a in to.map{.distance(from:a,to:$0)} } : target
        guard let target=selected,let entered=Double(value.replacingOccurrences(of:",",with:".")),entered>0,entered.isFinite else { errorMessage="Enter a positive measured value.";return }
        let tol=tolerance.isEmpty ? nil : Double(tolerance.replacingOccurrences(of:",",with:"."))
        guard tolerance.isEmpty || (tol.map{$0.isFinite && $0>=0} ?? false) else { errorMessage="Enter a nonnegative tolerance.";return }
        store.recordObservation(SurveyObservation(target:target,observedMM:entered*unit.factor,unit:unit,method:method,toleranceMM:tol.map{$0*unit.factor}))
        value="";errorMessage=nil
    }
}
#endif
