import Foundation
import CryptoKit

public enum SurveyHash {
    public static func data(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func value<T: Encodable>(_ value:T) throws -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return data(try encoder.encode(value))
    }
}
public struct SurveyAttachmentStore:Sendable {
    public let root: URL
    public init(root:URL) { self.root=root }
    private func safeURL(_ relative:String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { throw SurveyError.invalid("Invalid attachment path.") }
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        let url=base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path+"/") else { throw SurveyError.invalid("Attachment escapes project storage.") }
        return url
    }
    public func importAsset(data:Data,projectID:UUID,kind:SurveyEvidenceKind,sourceName:String) throws -> SurveyEvidenceReference {
        let hash=SurveyHash.data(data), relative="assets/\(projectID.uuidString)/\(hash).asset"
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=try safeURL(relative)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        _ = try safeURL(relative)
        if FileManager.default.fileExists(atPath:url.path) {
            guard try Data(contentsOf:url)==data else { throw SurveyError.invalid("Existing attachment hash mismatch.") }
        } else {
            let staging=url.deletingLastPathComponent().appendingPathComponent(".staging-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:staging) }
            try data.write(to:staging,options:.atomic)
            try FileManager.default.moveItem(at:staging,to:url)
        }
        return SurveyEvidenceReference(id:UUID(),projectID:projectID,relativePath:relative,sha256:hash,sourceName:sourceName,kind:kind)
    }
    public func readVerified(_ reference:SurveyEvidenceReference,projectID:UUID) throws -> Data {
        guard reference.projectID==projectID else { throw SurveyError.invalid("Evidence belongs to another project.") }
        let data=try Data(contentsOf:safeURL(reference.relativePath))
        guard SurveyHash.data(data)==reference.sha256 else { throw SurveyError.invalid("Evidence file failed its integrity check.") }
        return data
    }
}
