#if os(iOS)
import SwiftUI
struct SurveyDimensionPlacementView:View {
    @ObservedObject var store:PlanOpsisMobileStore
    @State private var selected:UUID?
    @State private var offset=350.0
    @State private var textX=0.0
    @State private var textY=0.0
    @State private var customText=false
    var body:some View {
        Form {
            if let project=store.project {
                let definitions=SurveyDimensionBuilder().definitions(project:project)
                Picker("Dimension",selection:$selected) {
                    Text("Choose dimension").tag(Optional<UUID>.none)
                    ForEach(SurveyDimensionBuilder().build(project:project).dimensions) { d in
                        Text("\(d.kind) · \(d.valueMM, specifier:"%.1f") mm · \(d.id.uuidString.prefix(8))").tag(Optional(d.id))
                    }
                }
                TextField("Offset (mm)",value:$offset,format:.number).keyboardType(.numbersAndPunctuation)
                Toggle("Custom text position",isOn:$customText)
                if customText {
                    TextField("Text X (mm)",value:$textX,format:.number).keyboardType(.numbersAndPunctuation)
                    TextField("Text Y (mm)",value:$textY,format:.number).keyboardType(.numbersAndPunctuation)
                }
                Button("Apply placement") {
                    guard var definition=definitions.first(where:{$0.id==selected}) else { return }
                    definition.offsetMM=offset;definition.textPosition=customText ? Point2D(x:textX,y:textY):nil
                    store.setSurveyDimension(definition)
                }.disabled(selected==nil)
                .onChange(of:selected) { _,id in
                    if let d=definitions.first(where:{$0.id==id}) { offset=d.offsetMM;customText=d.textPosition != nil;textX=d.textPosition?.x ?? 0;textY=d.textPosition?.y ?? 0 }
                }
                Text("Annotation placement changes the drawing, while the measured value remains derived from its references.").font(.caption)
            }
        }.navigationTitle("Dimension placement")
    }
}
#endif
