import Foundation

/// Immutable baselines are kept separately from the current editable project.
public struct SurveyExchangeStore {
    public let root:URL
    public init(root:URL) { self.root=root }
    private func url(projectID:UUID,revisionID:UUID) throws -> URL {
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        let file=base.appendingPathComponent("exchanges/\(projectID)/\(revisionID).json").resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path+"/") else { throw SurveyError.invalid("Exchange path escapes project storage.") }
        return file
    }
    public func save(_ manifest:SurveyExchangeManifest) throws {
        guard manifest.profileVersion==1,manifest.projectID==manifest.baseline.id,manifest.units=="mm",!manifest.originalDXF.isEmpty else { throw SurveyError.invalid("Invalid exchange baseline.") }
        try SurveyValidation.validate(manifest.baseline)
        let file=try url(projectID:manifest.projectID,revisionID:manifest.revisionID)
        if FileManager.default.fileExists(atPath:file.path) {
            guard try load(projectID:manifest.projectID,revisionID:manifest.revisionID)==manifest else { throw SurveyError.invalid("An export revision cannot be replaced.") }
            return
        }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        try encoder.encode(manifest).write(to:file,options:.atomic)
    }
    public func load(projectID:UUID,revisionID:UUID) throws -> SurveyExchangeManifest {
        let manifest=try JSONDecoder().decode(SurveyExchangeManifest.self,from:Data(contentsOf:url(projectID:projectID,revisionID:revisionID)))
        guard manifest.projectID==projectID,manifest.revisionID==revisionID,manifest.baseline.id==projectID,manifest.profileVersion==1 else { throw SurveyError.invalid("Exchange baseline identity mismatch.") }
        return manifest
    }
}
