import Foundation

/// v12.2 on-device project library: one validated JSON file per project, named by project UUID.
///
/// Replaces the single `project-v2.json` slot, where saving overwrote the previous project and a new scan
/// replaced the open one. Survey attachments stay in the shared attachment store, keyed by project ID.
public struct ProjectLibrary: Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var modified: Date
        public var roomCount: Int
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/PlanOpsisMobile/Projects`.
    public static func defaultLibrary(fileManager: FileManager = .default) throws -> ProjectLibrary {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ProjectLibrary(directory: base.appendingPathComponent("PlanOpsisMobile", isDirectory: true).appendingPathComponent("Projects", isDirectory: true))
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).planopsis.json")
    }

    /// Validates and atomically writes the project (see `ProjectStore.save`).
    public func save(_ project: PlanOpsisProject) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectStore(url: url(for: project.id)).save(project)
    }

    public func load(_ id: UUID) throws -> PlanOpsisProject {
        let project = try ProjectStore(url: url(for: id)).load()
        guard project.id == id else { throw SurveyError.invalid("Project file does not match its library entry.") }
        return project
    }

    public func delete(_ id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public func contains(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Most recently modified first. Unreadable files are skipped, never deleted.
    public func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(".planopsis.json") }
            .compactMap { file -> Entry? in
                guard let project = try? ProjectMigrator().decode(Data(contentsOf: file)),
                      file.lastPathComponent == "\(project.id.uuidString).planopsis.json" else { return nil }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Entry(id: project.id, name: project.displayName, modified: modified, roomCount: project.rooms.count)
            }
            .sorted { $0.modified == $1.modified ? $0.id.uuidString < $1.id.uuidString : $0.modified > $1.modified }
    }

    /// Copies a pre-v12.2 single-slot project into the library once. The legacy file is left in place.
    @discardableResult
    public func importLegacy(from store: ProjectStore) throws -> UUID? {
        let legacyExists = FileManager.default.fileExists(atPath: store.url.path)
            || store.legacyURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        guard legacyExists else { return nil }
        let project = try store.load()
        guard !contains(project.id) else { return nil }
        try save(project)
        return project.id
    }
}
