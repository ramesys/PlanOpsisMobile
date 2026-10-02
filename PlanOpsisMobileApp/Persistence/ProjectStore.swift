import Foundation

public struct ProjectStore {
    public enum StoreError: Error {
        case unsupportedSchema(Int)
    }

    public let url: URL
    public var legacyURL: URL? = nil

    public init(url: URL) {
        self.url = url
    }

    public static func defaultStore(fileManager: FileManager = .default) throws -> ProjectStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("PlanOpsisMobile", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var store = ProjectStore(url: directory.appendingPathComponent("project-v2.json"))
        store.legacyURL = directory.appendingPathComponent("project-v1.json")
        return store
    }

    public func save(_ project: PlanOpsisProject) throws {
        guard project.schemaVersion == 2 else { throw StoreError.unsupportedSchema(project.schemaVersion) }
        try SurveyValidation.validate(project)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            _ = try ProjectMigrator().decode(previous)
            if let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any], object["schemaVersion"] as? Int == 1 {
                let backup = url.appendingPathExtension("v1-backup-" + UUID().uuidString)
                try previous.write(to: backup, options: .withoutOverwriting)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }

    public func load() throws -> PlanOpsisProject {
        let source = !FileManager.default.fileExists(atPath: url.path) ? (legacyURL ?? url) : url
        return try ProjectMigrator().decode(Data(contentsOf: source))
    }
}
