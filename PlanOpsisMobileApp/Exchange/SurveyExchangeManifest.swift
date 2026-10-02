import Foundation
public enum DXFExportProfile:String,CaseIterable,Sendable { case compatible, rhinoEditable }
public struct SurveyExchangeManifest:Codable,Hashable,Sendable {
    public var profileVersion=1
    public var projectID:UUID
    public var revisionID:UUID
    public var units="mm"
    public var baseline:PlanOpsisProject
    public var originalDXF:String
}
public struct SurveyDXFExport:Sendable {
    public var text:String
    public var manifest:SurveyExchangeManifest
    public var issues:[String]
    public var canWrite:Bool { !text.isEmpty && issues.isEmpty }
}
