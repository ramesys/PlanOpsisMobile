import Foundation
public struct SurveyDeliveryReader {
    public init() {}
    public func read(root:URL) throws -> PlanOpsisProject {
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        func data(_ path:String) throws -> Data {
            guard !path.hasPrefix("/"),!path.split(separator:"/").contains("..") else { throw SurveyError.invalid("Invalid delivery path.") }
            let file=base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(base.path+"/") else { throw SurveyError.invalid("Delivery file escapes package.") }
            return try Data(contentsOf:file)
        }
        let manifest=try JSONDecoder().decode(SurveyDeliveryManifest.self,from:data("Delivery.json"))
        // Survey.pdf is a print artefact, not project state. It is hash-verified when listed but not
        // required, so packages written where CoreText is unavailable (Linux CI) remain readable.
        guard manifest.schemaVersion==1,Set(manifest.files.map(\.path)).count==manifest.files.count,Set(["Project.planopsis.json","Survey.exchange.json","Survey.dxf","Survey.ifc","Evidence.json","Survey-QA.json"]).isSubset(of:Set(manifest.files.map(\.path))) else { throw SurveyError.invalid("Incomplete or unsupported delivery manifest.") }
        for entry in manifest.files { guard try SurveyHash.data(data(entry.path))==entry.sha256 else { throw SurveyError.invalid("Delivery hash mismatch: "+entry.path) } }
        let project=try ProjectMigrator().decode(data("Project.planopsis.json"))
        guard project.id==manifest.projectID else { throw SurveyError.invalid("Delivery project identity mismatch.") }
        for ref in project.survey.evidence {
            guard manifest.files.contains(where:{$0.path==ref.relativePath && $0.sha256==ref.sha256}) else { throw SurveyError.invalid("Evidence missing from delivery manifest.") }
            _ = try SurveyAttachmentStore(root:base).readVerified(ref,projectID:project.id)
        }
        return project
    }
}
