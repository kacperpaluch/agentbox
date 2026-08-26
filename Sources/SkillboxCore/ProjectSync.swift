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
                let selected = SkillboxService.selectedSkills(in: try await store.catalog(), for: plan.project)
                let upToDate = await isUpToDate(plan.preview, skills: selected)
                _ = try await syncProjectTransaction(projectID: plan.project.id)
                outcomes.append(ProjectSyncOutcome(plan: plan, state: upToDate ? .upToDate : .synced))
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
        guard let project = config.resolvedProjects.first(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        Self.removeLegacyBackupDirectories(projectURL)
        let fm = FileManager.default
        var targets = project.tools.map { projectURL.appending(path: $0.projectSkillsPath) }
        let mcpPreviews = try await previewMCPRemovingEverything(project: project)
        targets += mcpPreviews.map { URL(fileURLWithPath: $0.file) }
        // Only the manifest — backing up the whole .skillbox directory would copy the backup
        // directory into itself.
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        let scratch = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique, in: scratch)
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
            let manifest = projectURL.appending(path: ".skillbox/mcp-manifest.json")
            if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
            // The manifest was the last thing Agentbox kept there; an emptied .skillbox is ours to
            // take away too instead of leaving clutter in the user's repository.
            let skillboxDirectory = projectURL.appending(path: ".skillbox")
            if let leftovers = try? fm.contentsOfDirectory(atPath: skillboxDirectory.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: skillboxDirectory)
            }
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

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agentbox-sync-\(UUID().uuidString)")
    }

    /// Versions up to 0.7.0 kept a history of sync backups inside each project. They protected
    /// nothing that the library plus `unsyncProject` cannot reproduce, so they are removed on the
    /// next sync rather than left behind as clutter in the user's repositories.
    static func removeLegacyBackupDirectories(_ project: URL) {
        let fm = FileManager.default
        for name in ["sync-backups", "mcp-backups"] {
            let directory = project.appending(path: ".skillbox/\(name)")
            if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
        }
    }

    private func previewMCPRemovingEverything(project: Project) async throws -> [MCPPreview] {
        let secrets = try await store.secrets()
        return try project.tools.map { try MCPRenderer.preview(tool: $0, project: URL(fileURLWithPath: project.path), servers: [], secrets: secrets) }
    }

    public func previewProjectSync(projectID: UUID) async throws -> ProjectSyncPreview {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let catalog = try await store.catalog()
        let selected = SkillboxService.selectedSkills(in: catalog, for: project)
        let skills = try project.tools.map { tool in
            try SkillboxService.skillPreview(tool: tool, target: URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath), current: selected)
        }
        return ProjectSyncPreview(skills: skills, mcp: try await previewMCP(projectID: projectID))
    }

    /// True when synchronizing would write exactly what is already on disk.
    ///
    /// The skill timestamps in the manifest are only good to the second, because `catalog.json`
    /// stores `updatedAt` that way. That precision is fine for showing drift, but not for deciding
    /// to skip a write: a skill edited in the same second as the last sync would never be copied.
    /// The decision therefore compares the managed directories byte for byte. It costs about as
    /// much as the copy it avoids, and saves a full backup on top of that.
    func isUpToDate(_ preview: ProjectSyncPreview, skills: [Skill]) async -> Bool {
        guard preview.skills.allSatisfy({ $0.added.isEmpty && $0.removed.isEmpty }) else { return false }
        let library = await store.skillsDirectory
        for item in preview.skills {
            let target = URL(fileURLWithPath: item.target)
            for skill in skills where !Self.directoryMatches(library.appending(path: skill.id), target.appending(path: skill.id)) { return false }
        }
        return preview.mcp.allSatisfy { item in
            item.staleFile == nil && (try? String(contentsOf: URL(fileURLWithPath: item.file), encoding: .utf8)) == item.content
        }
    }

    /// Recursive byte comparison of two skill directories.
    static func directoryMatches(_ source: URL, _ copy: URL) -> Bool {
        let fm = FileManager.default
        func files(_ root: URL) -> [String: URL] {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
            var result: [String: URL] = [:]
            for case let item as URL in enumerator {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = item.standardizedFileURL.path, base = root.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                result[String(path.dropFirst(base.count + 1))] = item
            }
            return result
        }
        guard fm.fileExists(atPath: source.path), fm.fileExists(atPath: copy.path) else { return false }
        let left = files(source), right = files(copy)
        guard Set(left.keys) == Set(right.keys) else { return false }
        for (relative, url) in left {
            guard let other = right[relative],
                  let a = try? Data(contentsOf: url), let b = try? Data(contentsOf: other), a == b else { return false }
        }
        return true
    }

    @discardableResult
    public func syncProjectTransaction(projectID: UUID) async throws -> ProjectSyncPreview {
        let preview = try await previewProjectSync(projectID: projectID)
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        Self.removeLegacyBackupDirectories(projectURL)
        // Independent of the sync content and idempotent, so it also runs for an unchanged project
        // whose owner has just switched the option on.
        if project.manageGitignore == true { try Self.updateProjectGitignore(projectURL, files: preview.mcp.map { URL(fileURLWithPath: $0.file) }) }
        // Writing identical bytes would still produce a full backup of every managed directory.
        // One "synchronize everything" run then buried the recovery list under a dozen useless
        // snapshots taken in the same second.
        let selected = SkillboxService.selectedSkills(in: try await store.catalog(), for: project)
        if await isUpToDate(preview, skills: selected) {
            // The files already match, but the manifest still records the timestamps from the last
            // write. Restamping it — Agentbox's own bookkeeping, no backup needed — keeps the
            // project's status honest instead of reporting drift that does not exist.
            for item in preview.skills {
                try SkillboxService.writeSkillManifest(selected, to: URL(fileURLWithPath: item.target))
            }
            return preview
        }
        var targets = preview.skills.map { URL(fileURLWithPath: $0.target) }
        targets += preview.mcp.map { URL(fileURLWithPath: $0.file) }
        targets += preview.mcp.compactMap { $0.staleFile.map(URL.init(fileURLWithPath:)) }
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        // The rollback copy exists only for the duration of this write. Once the sync succeeds it
        // protects nothing: the library is the source of truth, the manifests say what Agentbox
        // owns, and `unsyncProject` removes it all cleanly. Keeping it around only produced
        // directories of stale copies.
        let scratch = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique, in: scratch)

        do {
            _ = try await syncProject(id: projectID)
            _ = try await syncMCP(projectID: projectID)
            return preview
        } catch {
            try? Self.applySyncBackup(project: projectURL, backup: backup, metadata: metadata)
            throw error
        }
    }

    private static func makeSyncBackup(project: URL, targets: [URL], in backupRoot: URL) throws -> (URL, SyncBackupMetadata) {
        let fm = FileManager.default
        let backup = backupRoot.appending(path: UUID().uuidString)
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

}
