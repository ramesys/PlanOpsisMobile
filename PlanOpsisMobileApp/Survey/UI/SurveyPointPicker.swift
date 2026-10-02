#if os(iOS)
import SwiftUI
struct SurveyPointPicker:View {
    let title:String
    let project:PlanOpsisProject
    @Binding var point:SurveyPoint?
    @State private var wallID:UUID?
    @State private var location="start"
    @State private var station=0.0
    @State private var side=1
    var body:some View {
        VStack(alignment:.leading) {
            Text(title).font(.headline)
            Picker("Wall",selection:$wallID) {
                Text("Choose wall").tag(Optional<UUID>.none)
                ForEach(Array(project.rooms.enumerated()),id:\.element.id) { ri,room in
                    ForEach(Array(room.walls.enumerated()),id:\.element.id) { wi,wall in
                        Text("\(project.survey.roomNames[room.id] ?? "Room \(ri+1)") · wall \(wi+1)").tag(Optional(wall.id))
                    }
                }
            }
            Picker("Reference",selection:$location) { Text("Start").tag("start");Text("End").tag("end");Text("Face").tag("face") }
            if location=="face" {
                TextField("Station along wall (mm)",value:$station,format:.number).keyboardType(.decimalPad)
                Picker("Face side",selection:$side) { Text("Left (+)").tag(1);Text("Right (−)").tag(-1) }
                Text("Station is measured from the wall start. Face sides follow its start-to-end direction.").font(.caption)
            }
        }
        .onChange(of:wallID) { _,_ in update() }
        .onChange(of:location) { _,_ in update() }
        .onChange(of:station) { _,_ in update() }
        .onChange(of:side) { _,_ in update() }
    }
    private func update() {
        guard let wallID,let room=project.rooms.first(where:{$0.walls.contains(where:{$0.id==wallID})}) else { point=nil;return }
        point=SurveyPoint(roomID:room.id,wallID:wallID,location:location=="face" ? .face(stationMM:station,side:side):(location=="end" ? .end:.start))
    }
}
#endif
