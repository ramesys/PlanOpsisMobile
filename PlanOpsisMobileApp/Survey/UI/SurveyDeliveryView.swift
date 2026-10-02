#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct SurveyPackageDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.folder] }
    var wrapper:FileWrapper
    init(url:URL) throws {
        let prepared=try FileWrapper(url:url,options:.immediate)
        guard let entries=prepared.fileWrappers else { throw SurveyError.invalid("Survey delivery must be a folder.") }
        // SwiftUI stages exports in tmp. Do not carry the prepared source folder's
        // filename into that staging location, where the source already exists.
        wrapper=FileWrapper(directoryWithFileWrappers:entries)
    }
    init(configuration:ReadConfiguration) throws { wrapper=configuration.file }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { wrapper }
}
struct SurveyDeliveryView:View {
    @ObservedObject var store:PlanOpsisMobileStore
    @State private var document:SurveyPackageDocument?
    @State private var exporting=false
    @State private var importing=false
    @State private var working=false
    var body:some View {
        Form {
            if let p=store.project {
                let report=SurveyQAReport(project:p)
                Text(report.documentationStatus);Text(report.fieldStatus)
                Text("Includes project, editable DXF, IFC, scaled PDF, field-check report, exchange baseline and verified evidence.")
                Button(working ? "Preparing…":"Export survey folder") {
                    working=true
                    Task {
                        if let url=await store.prepareSurveyDelivery() {
                            do { document=try SurveyPackageDocument(url:url);exporting=true }
                            catch { store.statusMessage=error.localizedDescription }
                        }
                        working=false
                    }
                }.disabled(working)
            }
            Button("Open survey folder") { importing=true }.disabled(working)
            if let status=store.statusMessage { Text(status).font(.caption) }
        }.navigationTitle("Survey delivery")
        .fileExporter(isPresented:$exporting,document:document,contentType:.folder,defaultFilename:"PlanOpsis-Survey") { result in
            switch result { case .success:store.statusMessage="Survey folder exported. Print PDF sheets at 100%.";case .failure(let error):store.statusMessage=error.localizedDescription }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.folder]) { result in
            switch result { case .success(let url):Task { await store.openSurveyDelivery(url) };case .failure(let error):store.statusMessage=error.localizedDescription }
        }
    }
}
#endif
