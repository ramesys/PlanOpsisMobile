import Foundation

public struct SurveyQAReport:Codable,Sendable {
    public struct Check:Codable,Sendable { public var id:UUID;public var observedMM:Double;public var currentMM:Double?;public var residualMM:Double?;public var toleranceMM:Double?;public var method:String;public var note:String;public var status:String }
    public var projectID:UUID
    public var fieldStatus:String
    public var documentationStatus:String
    public var geometryErrors:[String]
    public var checks:[Check]
    public init(project:PlanOpsisProject) {
        projectID=project.id;geometryErrors=ExchangeGeometryValidation.errors(in:project)
        checks=project.survey.observations.map { o in
            let result=SurveyMeasurementEngine().evaluate(o,in:project)
            return Check(id:o.id,observedMM:o.observedMM,currentMM:result.currentMM,residualMM:result.residualMM,toleranceMM:o.toleranceMM,method:o.method,note:o.note,status:result.status.rawValue)
        }
        fieldStatus = !checks.isEmpty && checks.allSatisfy{$0.status=="withinTolerance"} ? "Recorded checks within declared tolerances":"Field checks incomplete"
        documentationStatus=project.rooms.allSatisfy{!(project.survey.roomNames[$0.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty} && project.survey.settings.showDimensions ? "Room names and dimensions supplied":"Documentation incomplete"
    }
}
public struct SurveyDeliveryManifest:Codable,Sendable {
    public struct Entry:Codable,Sendable { public var path:String;public var sha256:String }
    public var schemaVersion=1
    public var projectID:UUID
    public var revisionID:UUID
    public var files:[Entry]
}
public struct SurveyDeliveryWriter {
    public init() {}
    public func write(project:PlanOpsisProject,attachmentStore:SurveyAttachmentStore,destination:URL) throws -> SurveyDeliveryManifest {
        try SurveyValidation.validate(project)
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw SurveyError.invalid("Delivery destination already exists; choose a new name.") }
        let dimensions=SurveyDimensionBuilder().build(project:project),revision=UUID()
        let dxf=EditableDXFWriter().export(project:project,dimensions:dimensions,revisionID:revision)
        let ifc=IFC4ExchangeEngine().exportValidated(project:project)
        guard dxf.canWrite,ifc.canWrite else { throw SurveyError.invalid("Delivery blocked: "+(dxf.issues+ifc.issues.map(\.message)).joined(separator:"\n")) }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        var files:[String:Data]=[
            "Project.planopsis.json":try encoder.encode(project),
            "Survey.dxf":Data(dxf.text.utf8),"Survey.ifc":Data(ifc.text.utf8),
            "Survey.exchange.json":try encoder.encode(dxf.manifest),
            "Evidence.json":try encoder.encode(project.survey.evidence),
            "Survey-QA.json":try encoder.encode(SurveyQAReport(project:project)),
            "Survey.pdf":try SurveySheetRenderer().render(project:project,dimensions:dimensions,revisionID:revision),
            "README.txt":Data("Print Survey.pdf at 100% with no fit-to-page scaling. The sheet scale applies to each numbered tile. Project.planopsis.json owns architecture; DXF and IFC are sibling outputs. Load Survey.exchange.json before reviewing a Rhino return on another device. Field-check status describes only recorded checks; it is not survey accuracy certification.\n".utf8)
        ]
        for ref in project.survey.evidence { files[ref.relativePath]=try attachmentStore.readVerified(ref,projectID:project.id) }
        let manifest=SurveyDeliveryManifest(projectID:project.id,revisionID:revision,files:files.keys.sorted().map{.init(path:$0,sha256:SurveyHash.data(files[$0]!))})
        files["Delivery.json"]=try encoder.encode(manifest)
        let staging=destination.deletingLastPathComponent().appendingPathComponent(".survey-staging-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:staging) }
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        for (path,data) in files {
            let file=staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:file,options:.atomic)
        }
        try FileManager.default.moveItem(at:staging,to:destination)
        return manifest
    }
}
