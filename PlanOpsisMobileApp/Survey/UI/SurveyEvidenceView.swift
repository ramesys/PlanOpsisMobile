#if os(iOS)
import SwiftUI
import PhotosUI

struct SurveyEvidenceView:View {
    @ObservedObject var store:PlanOpsisMobileStore
    @State private var selectedPhoto:PhotosPickerItem?
    @State private var linkedID:UUID?
    @State private var working=false
    var body:some View {
        Form {
            if let project=store.project {
                Section("Link a photo") {
                    Picker("Linked room or element",selection:$linkedID) {
                        Text("Whole project").tag(Optional<UUID>.none)
                        ForEach(Array(project.rooms.enumerated()),id:\.element.id) { ri,room in
                            Text(project.survey.roomNames[room.id] ?? "Room \(ri+1)").tag(Optional(room.id))
                            ForEach(Array(room.walls.enumerated()),id:\.element.id) { wi,w in Text("Room \(ri+1) · wall \(wi+1)").tag(Optional(w.id)) }
                            ForEach(room.openings) { o in Text("\(o.kind.rawValue) \(o.id.uuidString.prefix(8))").tag(Optional(o.id)) }
                            ForEach(room.components) { c in Text("\(c.kind.rawValue) \(c.id.uuidString.prefix(8))").tag(Optional(c.id)) }
                        }
                    }
                    PhotosPicker(selection:$selectedPhoto,matching:.images) { Label(working ? "Attaching…":"Choose photo",systemImage:"photo") }.disabled(working)
                }
                Section("Project evidence") {
                    ForEach(project.survey.evidence) { ref in
                        VStack(alignment:.leading) {
                            Text(ref.sourceName)
                            Text("\(ref.kind.rawValue) · \(ref.entityID?.uuidString.prefix(8) ?? "Project")").font(.caption)
                            Text("SHA-256 \(ref.sha256.prefix(12))…").font(.caption2)
                        }
                    }
                }
                if let status=store.statusMessage { Text(status).font(.caption) }
            }
        }.navigationTitle("Survey evidence")
        .onChange(of:selectedPhoto) { _,item in
            guard let item,let projectID=store.project?.id else { return }
            let link=linkedID;working=true
            Task {
                do {
                    guard let data=try await item.loadTransferable(type:Data.self) else { throw SurveyError.invalid("Photo could not be loaded.") }
                    await store.attachSurveyPhoto(data,projectID:projectID,entityID:link)
                } catch { store.statusMessage=error.localizedDescription }
                working=false;selectedPhoto=nil
            }
        }
    }
}
#endif
