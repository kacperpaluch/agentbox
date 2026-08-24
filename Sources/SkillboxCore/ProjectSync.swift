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
    public func previewAllProjectsSync() async throws -> [ProjectSyncPlan] {
        let projects = try await listProjects()
        var plans: [ProjectSyncPlan] = []
        for project in projects {
            plans.append(ProjectSyncPlan(project: project, preview: try await previewProjectSync(projectID: project.id)))
        }
        return plans
    }

    /// Validates every project and computes every preview before the first write. Each project is
    /// then synchronized transactionally; a failed project is rolled back on its own and stops the
    /// run, so the caller always learns exactly which projects were written, which was rolled back,
    /// and which were never attempted.
    @discardableResult
    public func syncAllProjectsTransactions() async throws -> [ProjectSyncOutcome] {
        let plans = try await previewAllProjectsSync()
        var outcomes: [ProjectSyncOutcome] = []
        var failed = false
        for plan in plans {
            guard !failed else { outcomes.append(ProjectSyncOutcome(plan: plan, state: .skipped)); continue }
            do {
                _ = try await syncProjectTransaction(projectID: plan.project.id)
                outcomes.append(ProjectSyncOutcome(plan: plan, state: .synced))
            } catch {
                outcomes.append(ProjectSyncOutcome(plan: plan, state: .failed(error.localizedDescription)))
                failed = true
            }
        }
        return outcomes
    }

    /// One row per project answering "does this project still match the library?" without making
    /// the user open every preview. A blocked project is reported, not thrown, so one bad project
    /// never hides the state of the others.
    public func projectStatuses() async throws -> [ProjectStatus] {
        var statuses: [ProjectStatus] = []
        for project in try await listProjects() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                statuses.append(ProjectStatus(projectID: project.id, state: .missing)); continue
            }
            do {
                let preview = try await previewProjectSync(projectID: project.id)
                let added = preview.skills.reduce(0) { $0 + $1.added.count } + preview.mcp.reduce(0) { $0 + $1.added.count }
                let outdated = preview.skills.reduce(0) { $0 + $1.updated.count }
                let removed = preview.skills.reduce(0) { $0 + $1.removed.count } + preview.mcp.reduce(0) { $0 + $1.removed.count }
                let stale = preview.mcp.contains { $0.staleFile != nil } ? 1 : 0
                statuses.append(ProjectStatus(
                    projectID: project.id,
                    state: added + outdated + removed + stale == 0 ? .synced : .pending(added: added, outdated: outdated, removed: removed + stale)
                ))
            } catch {
                statuses.append(ProjectStatus(projectID: project.id, state: .blocked(error.localizedDescription)))
            }
        }
        return statuses
    }

    /// Removes everything Agentbox wrote into a project, using its manifests as the only source of
    /// truth, and leaves the project folder otherwise untouched.
    @discardableResult
    public func unsyncProject(id: UUID) async throws -> [String] {
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        let fm = FileManager.default
        var targets = project.tools.map { projectURL.appending(path: $0.projectSkillsPath) }
        let mcpPreviews = try await previewMCPRemovingEverything(project: project)
        targets += mcpPreviews.map { URL(fileURLWithPath: $0.file) }
        // Only the manifest — backing up the whole .skillbox directory would copy the backup
        // directory into itself.
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique)
        var removed: [String] = []
        do {
            for tool in project.tools {
                let target = projectURL.appending(path: tool.projectSkillsPath)
                for skillID in SkillboxService.managedSkillIDs(at: target).sorted() {
                    let directory = target.appending(path: skillID)
                    if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
                    removed.append("\(tool.projectSkillsPath)/\(skillID)")
                }
                let manifest = target.appending(path: ".skillbox.json")
                if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
            }
            if !mcpPreviews.isEmpty {
                try MCPRenderer.apply(previews: mcpPreviews, project: projectURL)
                removed += mcpPreviews.flatMap { preview in preview.removed.map { "\(URL(fileURLWithPath: preview.file).lastPathComponent): \($0)" } }
            }
            let skillboxDirectory = projectURL.appending(path: ".skillbox/mcp-manifest.json")
            if fm.fileExists(atPath: skillboxDirectory.path) { try fm.removeItem(at: skillboxDirectory) }
            try Self.pruneSyncBackups(projectURL, keeping: 10)
        } catch {
            try? Self.applySyncBackup(project: projectURL, backup: backup, metadata: metadata)
            throw error
        }
        return removed
    }

    /// `.git/info/exclude` protects only the clone it lives in. A teammate who clones the
    /// repository gets no protection at all, so a project can opt into the tracked `.gitignore`.
    /// Entries go in a marked block and are never removed from lines the user wrote.
    static func updateProjectGitignore(_ project: URL, files: [URL]) throws {
        let marker = "# Agentbox: wygenerowane konfiguracje MCP (mogą zawierać lokalne sekrety)"
        let url = project.appending(path: ".gitignore")
        var entries = files.map { file -> String in
            let path = file.standardizedFileURL.path, root = project.standardizedFileURL.path
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : file.lastPathComponent
        }
        entries.append(".skillbox/")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let present = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = entries.filter { !present.contains($0) }.sorted()
        guard !missing.isEmpty else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.contains(marker) { text += (text.isEmpty ? "" : "\n") + marker + "\n" }
        text += missing.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func previewMCPRemovingEverything(project: Project) async throws -> [MCPPreview] {
        let secrets = try await store.secrets()
        return try project.tools.map { try MCPRenderer.preview(tool: $0, project: URL(fileURLWithPath: project.path), servers: [], secrets: secrets) }
    }

    public func previewProjectSync(projectID: UUID) async throws -> ProjectSyncPreview {
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let catalog = try await store.catalog()
        let selected = SkillboxService.selectedSkills(in: catalog, for: project)
        let skills = try project.tools.map { tool in
            try SkillboxService.skillPreview(tool: tool, target: URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath), current: selected)
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
        targets += preview.mcp.compactMap { $0.staleFile.map(URL.init(fileURLWithPath:)) }
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique)

        do {
            _ = try await syncProject(id: projectID)
            _ = try await syncMCP(projectID: projectID)
            if project.manageGitignore == true { try Self.updateProjectGitignore(projectURL, files: preview.mcp.map { URL(fileURLWithPath: $0.file) }) }
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

    /// Each backup is a full copy of the managed skill trees, so ten of them across three tools can
    /// reach hundreds of megabytes inside a repository. Keep the newest ones within both a count
    /// and a size budget, always retaining at least the most recent one.
    static func pruneSyncBackups(_ project: URL, keeping limit: Int, maximumBytes: Int = 200 * 1024 * 1024) throws {
        let root = project.appending(path: ".skillbox/sync-backups")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let items = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for item in sorted.dropFirst(limit) { try fm.removeItem(at: item) }
        var kept = Array(sorted.prefix(limit))
        var total = kept.reduce(0) { $0 + directorySize(of: $1) }
        while total > maximumBytes, kept.count > 1, let oldest = kept.last {
            total -= directorySize(of: oldest)
            try fm.removeItem(at: oldest)
            kept.removeLast()
        }
    }

    private static func directorySize(of url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += values?.totalFileAllocatedSize ?? 0
        }
        return total
    }
}
