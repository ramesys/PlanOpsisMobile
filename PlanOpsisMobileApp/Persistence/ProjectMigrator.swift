import Foundation

public struct ProjectMigrator {
    public init() {}
    public func decode(_ data: Data) throws -> PlanOpsisProject {
        struct Version: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        guard version == 1 || version == 2 else { throw ProjectStore.StoreError.unsupportedSchema(version) }
        var project = try JSONDecoder().decode(PlanOpsisProject.self, from: data)
        project.schemaVersion = 2
        try SurveyValidation.validate(project)
        return project
    }
}
