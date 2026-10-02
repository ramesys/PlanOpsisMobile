import Foundation
public struct PLYSurveyEvidence: Codable, Hashable, Sendable {
    public var schemaVersion=1
    public var sourceSHA256:String? = nil
    public var sourceUnit:PLYLengthUnit? = nil
    public var reconstruction:PLYReconstructionResult
    public func validated() throws -> PLYReconstructionResult {
        guard schemaVersion==1 else { throw SurveyError.invalid("Unsupported PLY evidence schema.") }
        return reconstruction
    }
}
