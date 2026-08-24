import Foundation

private struct SyncBackupMetadata: Codable {
    var createdAt: Date
    var entries: [SyncBackupEntry]
}

private struct SyncBackupEntry: Codable {
    var targetRelativePath: String
    var savedName: String?
    var existed: Bool
}

extension SkillboxService {
    public func previewProjectSync(projectID: UUID) async throws -> ProjectSyncPreview {
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let catalog = try await store.catalog()
        let selected = catalog.skills.filter { project.skillIDs.contains($0.id) || !$0.tags.filter(project.tags.contains).isEmpty }
        let current = Set(selected.map(\.id))
        let fm = FileManager.default
        let skills = project.tools.map { tool -> SkillSyncPreview in
            let target = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath)
            let manifest = target.appending(path: ".skillbox.json")
            let previous = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? [])
            return SkillSyncPreview(
                tool: tool,
                target: target.path,
                added: Array(current.subtracting(previous)).sorted(),
                updated: Array(current.intersection(previous)).filter { fm.fileExists(atPath: target.appending(path: $0).path) }.sorted(),
                removed: Array(previous.subtracting(current)).sorted()
            )
        }
        return ProjectSyncPreview(skills: skills, mcp: try await previewMCP(projectID: projectID))
    }

    @discardableResult
    public func syncProjectTransaction(projectID: UUID) async throws -> ProjectSyncPreview {
        let preview = try await previewProjectSync(projectID: projectID)
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        var targets = preview.skills.map { URL(fileURLWithPath: $0.target) }
        targets += preview.mcp.map { URL(fileURLWithPath: $0.file) }
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique)

        do {
            _ = try await syncProject(id: projectID)
            _ = try await syncMCP(projectID: projectID)
            try Self.pruneSyncBackups(projectURL, keeping: 10)
            return preview
        } catch {
            try? Self.applySyncBackup(project: projectURL, backup: backup, metadata: metadata)
            try? Self.pruneSyncBackups(projectURL, keeping: 10)
            throw error
        }
    }

    public func projectSyncBackups() async throws -> [ProjectSyncBackup] {
        let projects = try await store.configuration().projects
        let fm = FileManager.default
        var result: [ProjectSyncBackup] = []
        for project in projects {
            let root = URL(fileURLWithPath: project.path).appending(path: ".skillbox/sync-backups")
            guard fm.fileExists(atPath: root.path) else { continue }
            for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                guard let metadata = try? Self.readMetadata(directory) else { continue }
                let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? metadata.createdAt
                result.append(ProjectSyncBackup(projectID: project.id, projectName: project.name, name: directory.lastPathComponent, date: date, targets: metadata.entries.map(\.targetRelativePath).sorted()))
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    @discardableResult
    public func restoreProjectSyncBackup(projectID: UUID, named name: String) async throws -> [String] {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw SkillboxError.unsafePath(name) }
        let projects = try await store.configuration().projects
        guard let project = projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path).standardizedFileURL
        let backup = projectURL.appending(path: ".skillbox/sync-backups/\(name)").standardizedFileURL
        let expectedRoot = projectURL.appending(path: ".skillbox/sync-backups").standardizedFileURL
        guard backup.deletingLastPathComponent().path == expectedRoot.path else { throw SkillboxError.unsafePath(backup.path) }
        let metadata = try Self.readMetadata(backup)
        let targets = try metadata.entries.map { try Self.targetURL(project: projectURL, relativePath: $0.targetRelativePath) }
        let (safetyBackup, safetyMetadata) = try Self.makeSyncBackup(project: projectURL, targets: targets)
        do { try Self.applySyncBackup(project: projectURL, backup: backup, metadata: metadata) }
        catch {
            try? Self.applySyncBackup(project: projectURL, backup: safetyBackup, metadata: safetyMetadata)
            throw error
        }
        try Self.pruneSyncBackups(projectURL, keeping: 10)
        return metadata.entries.map(\.targetRelativePath).sorted()
    }

    private static func makeSyncBackup(project: URL, targets: [URL]) throws -> (URL, SyncBackupMetadata) {
        let fm = FileManager.default
        let backup = project.appending(path: ".skillbox/sync-backups/\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var entries: [SyncBackupEntry] = []
        for (index, target) in targets.enumerated() {
            let standardized = target.standardizedFileURL
            let projectPath = project.standardizedFileURL.path
            guard standardized.path.hasPrefix(projectPath + "/") else { throw SkillboxError.unsafePath(standardized.path) }
            let relative = String(standardized.path.dropFirst(projectPath.count + 1))
            let existed = fm.fileExists(atPath: standardized.path)
            let savedName = existed ? "item-\(index)" : nil
            if let savedName { try fm.copyItem(at: standardized, to: backup.appending(path: savedName)) }
            entries.append(SyncBackupEntry(targetRelativePath: relative, savedName: savedName, existed: existed))
        }
        let metadata = SyncBackupMetadata(createdAt: .now, entries: entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: backup.appending(path: "metadata.json"), options: .atomic)
        return (backup, metadata)
    }

    private static func readMetadata(_ backup: URL) throws -> SyncBackupMetadata {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncBackupMetadata.self, from: Data(contentsOf: backup.appending(path: "metadata.json")))
    }

    private static func applySyncBackup(project: URL, backup: URL, metadata: SyncBackupMetadata) throws {
        let fm = FileManager.default
        for entry in metadata.entries.reversed() {
            let target = try targetURL(project: project, relativePath: entry.targetRelativePath)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if entry.existed, let savedName = entry.savedName {
                let saved = backup.appending(path: savedName)
                guard fm.fileExists(atPath: saved.path) else { throw SkillboxError.invalidSkill("backup nie zawiera \(savedName)") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: saved, to: target)
            }
        }
    }

    private static func targetURL(project: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { throw SkillboxError.unsafePath(relativePath) }
        let target = project.appending(path: relativePath).standardizedFileURL
        guard target.path.hasPrefix(project.standardizedFileURL.path + "/") else { throw SkillboxError.unsafePath(target.path) }
        return target
    }

    private static func pruneSyncBackups(_ project: URL, keeping limit: Int) throws {
        let root = project.appending(path: ".skillbox/sync-backups")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let items = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for item in sorted.dropFirst(limit) { try fm.removeItem(at: item) }
    }
}
