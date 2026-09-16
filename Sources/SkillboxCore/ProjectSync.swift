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
    public func previewAllProjectsSync(progress: SyncProgressHandler? = nil) async throws -> [ProjectSyncPlan] {
        let projects = try await listProjects()
        var plans: [ProjectSyncPlan] = []
        for project in projects {
            await progress?(SyncProgress(done: plans.count, total: projects.count, label: "Sprawdzam \(project.name)"))
            plans.append(ProjectSyncPlan(project: project, preview: try await previewProjectSync(projectID: project.id)))
        }
        return plans
    }

    /// Validates every project and computes every preview before the first write. Each project is
    /// then synchronized transactionally; a failed project is rolled back on its own and stops the
    /// run, so the caller always learns exactly which projects were written, which was rolled back,
    /// and which were never attempted.
    @discardableResult
    public func syncAllProjectsTransactions(progress: SyncProgressHandler? = nil) async throws -> [ProjectSyncOutcome] {
        let plans = try await previewAllProjectsSync(progress: progress)
        var outcomes: [ProjectSyncOutcome] = []
        var failed = false
        for plan in plans {
            guard !failed else { outcomes.append(ProjectSyncOutcome(plan: plan, state: .skipped)); continue }
            await progress?(SyncProgress(done: outcomes.count, total: plans.count, label: "Synchronizuję \(plan.project.name)"))
            do {
                // The plan's preview is handed straight to the write, instead of every project being
                // previewed a second time here and a third time inside the transaction.
                let result = try await applySync(projectID: plan.project.id, preview: plan.preview)
                // `wasUpToDate` answers about files only, because that is what decides whether a
                // backup is worth taking. A missing plugin is still work done, so the reported
                // outcome asks about it separately instead of claiming the project was untouched.
                let upToDate = result.wasUpToDate && plan.preview.missingPlugins.isEmpty
                outcomes.append(ProjectSyncOutcome(plan: plan, state: upToDate ? .upToDate : .synced))
            } catch {
                outcomes.append(ProjectSyncOutcome(plan: plan, state: .failed(error.localizedDescription)))
                failed = true
            }
        }
        await progress?(SyncProgress(done: outcomes.count, total: plans.count, label: "Gotowe"))
        return outcomes
    }

    /// One row per project answering "does this project still match the library?" without making
    /// the user open every preview. A blocked project is reported, not thrown, so one bad project
    /// never hides the state of the others.
    public func projectStatuses(progress: SyncProgressHandler? = nil) async throws -> [ProjectStatus] {
        var statuses: [ProjectStatus] = []
        let projects = try await listProjects()
        let catalog = try await store.catalog()
        for project in projects {
            await progress?(SyncProgress(done: statuses.count, total: projects.count, label: "Sprawdzam \(project.name)"))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                statuses.append(ProjectStatus(projectID: project.id, state: .missing)); continue
            }
            do {
                let preview = try await previewProjectSync(projectID: project.id)
                // A plugin Claude Code has not been asked for yet is as pending as a missing skill:
                // without it here a project stayed `synchronized` while its selection was not applied.
                let added = preview.skills.reduce(0) { $0 + $1.added.count } + preview.mcp.reduce(0) { $0 + $1.added.count + $1.disabledGlobalAdded.count } + (preview.docs.first?.added.count ?? 0) + preview.missingPlugins.count
                // Everything above counts *names*: a skill id, a server name, a document id. A
                // server whose command was corrected, a document rewritten in place or a skill
                // edited straight in the library folder all keep their name, so the project kept
                // reporting itself as synchronized while its files no longer matched the library.
                let selected = SkillboxService.selectedSkills(in: catalog, for: project)
                let drifted = await driftedTargets(preview, skills: selected)
                let outdated = preview.skills.reduce(0) { $0 + $1.updated.count } + drifted
                let removed = preview.skills.reduce(0) { $0 + $1.removed.count } + preview.mcp.reduce(0) { $0 + $1.removed.count + $1.disabledGlobalRemoved.count } + (preview.docs.first?.removed.count ?? 0)
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
        let fm = FileManager.default
        // Including tools the project no longer lists, so their manifests are cleaned up too.
        let tools = project.tools + Self.abandonedTools(project: project)
        var targets = try tools.map { try SkillboxService.managedTarget(project: projectURL, tool: $0) }
        let mcpPreviews = try await previewMCPRemovingEverything(project: project)
        targets += mcpPreviews.map { URL(fileURLWithPath: $0.file) }
        // `apply` rewrites Claude Code's opt-out file too, so cleaning up must be able to put it
        // back — same reason as in `syncProjectTransaction`.
        targets += mcpPreviews.compactMap { $0.disabledGlobalFile.map(URL.init(fileURLWithPath:)) }
        let docPreviews = try DocsRenderer.preview(project: projectURL, doc: nil)
        targets += docPreviews.map { URL(fileURLWithPath: $0.file) }
        // Only the manifests — backing up the whole .skillbox directory would copy the backup
        // directory into itself.
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        targets.append(projectURL.appending(path: ".skillbox/docs-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        // Every manifest is read before the first removal, so a damaged one stops the run up front.
        let managed = try tools.map { tool in
            let target = try SkillboxService.managedTarget(project: projectURL, tool: tool)
            return (tool, target, try SkillboxService.managedSkillIDs(at: target))
        }
        let scratch = Self.scratchDirectory()
        defer { if !Self.shouldKeepScratch(scratch) { try? FileManager.default.removeItem(at: scratch) } }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique, in: scratch)
        var removed: [String] = []
        do {
            for (tool, target, ids) in managed {
                for skillID in ids.sorted() {
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
            try DocsRenderer.apply(previews: docPreviews, project: projectURL)
            removed += docPreviews.flatMap { preview in preview.removed.map { "\(URL(fileURLWithPath: preview.file).lastPathComponent): \($0)" } }
            let docsManifest = projectURL.appending(path: ".skillbox/docs-manifest.json")
            if fm.fileExists(atPath: docsManifest.path) { try fm.removeItem(at: docsManifest) }
            // The manifest was the last thing Agentbox kept there; an emptied .skillbox is ours to
            // take away too instead of leaving clutter in the user's repository.
            Self.removeLegacyBackupDirectories(projectURL)
            let skillboxDirectory = projectURL.appending(path: ".skillbox")
            if let leftovers = try? fm.contentsOfDirectory(atPath: skillboxDirectory.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: skillboxDirectory)
            }
        } catch {
            throw Self.rollingBack(error, project: projectURL, backup: backup, metadata: metadata, scratch: scratch)
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
        var text = try SkillboxService.existingText(at: url)
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
    /// nothing that the library plus `unsyncProject` cannot reproduce, so they are removed after
    /// the next successful sync rather than left behind as clutter in the user's repositories.
    ///
    /// Only when `.skillbox` really is a folder of this project: a symbolic link there points
    /// somewhere else, and a directory that merely carries the historical name is not ours to
    /// delete. Failing to remove clutter is not a reason to report a finished sync as failed.
    static func removeLegacyBackupDirectories(_ project: URL) {
        let fm = FileManager.default
        let container = project.appending(path: ".skillbox")
        guard (try? fm.attributesOfItem(atPath: container.path)[.type] as? FileAttributeType) == .typeDirectory,
              container.resolvingSymlinksInPath().standardizedFileURL.path == project.resolvingSymlinksInPath().standardizedFileURL.path + "/.skillbox" else { return }
        for name in ["sync-backups", "mcp-backups"] {
            let directory = project.appending(path: ".skillbox/\(name)")
            if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
        }
    }

    private func previewMCPRemovingEverything(project: Project) async throws -> [MCPPreview] {
        let secrets = try await store.secrets()
        let tools = project.tools + Self.abandonedTools(project: project)
        return try tools.map { try MCPRenderer.preview(tool: $0, project: URL(fileURLWithPath: project.path), servers: [], secrets: secrets) }
    }

    /// Tools the project no longer lists but whose targets still hold Agentbox manifests.
    /// They stay part of every preview and sync until nothing managed remains, so unticking a
    /// tool removes its files instead of orphaning them in the repository forever.
    static func abandonedTools(project: Project) -> [Tool] {
        let url = URL(fileURLWithPath: project.path)
        let mcpManaged = MCPRenderer.managedTools(url)
        return Tool.allCases.filter { tool in
            guard !project.tools.contains(tool) else { return false }
            if FileManager.default.fileExists(atPath: url.appending(path: tool.projectSkillsPath).appending(path: ".skillbox.json").path) { return true }
            return mcpManaged.contains(tool)
        }
    }

    public func previewProjectSync(projectID: UUID) async throws -> ProjectSyncPreview {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let catalog = try await store.catalog()
        let selected = SkillboxService.selectedSkills(in: catalog, for: project)
        let library = await store.skillsDirectory
        let perTool: [(Tool, [Skill])] = project.tools.map { ($0, selected) } + Self.abandonedTools(project: project).map { ($0, []) }
        let skills = try perTool.map { tool, current in
            try SkillboxService.skillPreview(tool: tool, target: try SkillboxService.managedTarget(project: URL(fileURLWithPath: project.path), tool: tool), current: current, library: library)
        }
        let ids = config.selections[config.selectionID(for: project).uuidString]?.claudePluginIDs ?? []
        let plugins = try await previewClaudePlugins(projectPath: project.path, ids: ids)
        return ProjectSyncPreview(skills: skills, mcp: try await previewMCP(projectID: projectID), docs: try await previewDocs(projectID: projectID), plugins: plugins)
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
        guard preview.mcp.allSatisfy({ $0.staleFile == nil }) else { return false }
        // A change of ownership is a change even when the bytes already match: an `AGENTS.md`
        // identical to the assigned document still needs its manifest, or the project stays
        // "pending" forever and the next edit of that document is refused as a conflict.
        guard preview.docs.allSatisfy({ $0.leaveAsIs || ($0.added.isEmpty && $0.removed.isEmpty) }) else { return false }
        guard preview.mcp.allSatisfy({ $0.added.isEmpty && $0.removed.isEmpty && $0.disabledGlobalAdded.isEmpty && $0.disabledGlobalRemoved.isEmpty }) else { return false }
        return await driftedTargets(preview, skills: skills, includingRenamed: true) == 0
    }

    /// How many managed targets hold bytes other than the ones a synchronization would write.
    ///
    /// This is the question the project status has to ask. Its own `added`/`removed` lists only say
    /// which *names* appeared or disappeared, and a corrected MCP command, an edited document or a
    /// skill changed straight in the library folder keeps every name exactly as it was.
    ///
    /// By default a target whose name lists already report the change is not counted again, so the
    /// status does not show the same server as both added and outdated. `isUpToDate` passes
    /// `includingRenamed` because it needs one plain yes-or-no about the files.
    func driftedTargets(_ preview: ProjectSyncPreview, skills: [Skill], includingRenamed: Bool = false) async -> Int {
        let library = await store.skillsDirectory
        var count = 0
        // `updated` counts too: a skill the manifest already reports as outdated must not be
        // counted a second time here as drift.
        for item in preview.skills where includingRenamed || (item.added.isEmpty && item.removed.isEmpty && item.updated.isEmpty) {
            let target = URL(fileURLWithPath: item.target)
            if skills.contains(where: { !Self.directoryMatches(library.appending(path: $0.id), target.appending(path: $0.id)) }) { count += 1 }
        }
        count += preview.mcp.filter { (includingRenamed || ($0.added.isEmpty && $0.removed.isEmpty)) && !Self.fileMatches($0.file, content: $0.content) }.count
        // Claude Code's opt-out lives in its own file, outside `content`. Leaving it out of the
        // comparison meant a project whose only pending change was "przestań widzieć ten globalny
        // serwer" counted as up to date: the synchronization skipped every write and reported
        // success, and the status agreed with it.
        count += preview.mcp.filter { item in
            guard let file = item.disabledGlobalFile, let content = item.disabledGlobalContent else { return false }
            guard includingRenamed || (item.disabledGlobalAdded.isEmpty && item.disabledGlobalRemoved.isEmpty) else { return false }
            return !Self.fileMatches(file, content: content)
        }.count
        count += preview.docs.filter { !$0.leaveAsIs && (includingRenamed || ($0.added.isEmpty && $0.removed.isEmpty)) && !Self.fileMatches($0.file, content: $0.content) }.count
        return count
    }

    /// True when the file already holds exactly `content`. Empty content means "this file should not
    /// exist", so a missing file matches it.
    static func fileMatches(_ path: String, content: String) -> Bool {
        let existing = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        return content.isEmpty ? existing == nil : existing == content
    }

    /// The same resource comparison as update previews: bytes, directories, links and permissions.
    /// A chmod-only update must reach the project too, rather than being skipped as identical text.
    static func directoryMatches(_ source: URL, _ copy: URL) -> Bool {
        do { return try SkillTree.read(source) == SkillTree.read(copy) }
        catch { return false }
    }

    @discardableResult
    public func syncProjectTransaction(projectID: UUID) async throws -> ProjectSyncPreview {
        try await applySync(projectID: projectID, preview: nil).preview
    }

    /// The body of `syncProjectTransaction`, plus the one extra answer the all-projects run needs:
    /// were the files already current? Working that out means comparing every managed skill
    /// directory byte for byte, and the caller used to do it a second time on its own.
    ///
    /// `preview` is the plan already computed for this project. Passing it keeps the invariant —
    /// the preview is still made before anything is written — without previewing the project again.
    private func applySync(projectID: UUID, preview suppliedPreview: ProjectSyncPreview?) async throws -> (preview: ProjectSyncPreview, wasUpToDate: Bool) {
        let preview: ProjectSyncPreview
        if let suppliedPreview { preview = suppliedPreview } else { preview = try await previewProjectSync(projectID: projectID) }
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        let pluginIDs = config.selections[config.selectionID(for: project).uuidString]?.claudePluginIDs ?? []
        // Independent of the sync content and idempotent, so it also runs for an unchanged project
        // whose owner has just switched the option on.
        if project.manageGitignore == true { try Self.updateProjectGitignore(projectURL, files: preview.mcp.map { URL(fileURLWithPath: $0.file) }) }
        // Same reasoning: whether the generated files are excluded from Git does not depend on
        // whether their content changed.
        try MCPRenderer.protectGeneratedFiles(projectURL, previews: preview.mcp)
        // A plugin is installed by Claude Code, outside Agentbox's managed file manifests, so this
        // runs even when skills, MCP and docs are already current. It goes first because the CLI
        // reaches the network: installing last meant a flaky install rolled back skills, MCP and
        // docs that had just been written correctly, instead of leaving the project unsynchronized
        // with its files untouched.
        try await installLibraryClaudePlugins(projectPath: project.path, ids: pluginIDs)
        // Writing identical bytes would still produce a full backup of every managed directory.
        // One "synchronize everything" run then buried the recovery list under a dozen useless
        // snapshots taken in the same second.
        let selected = SkillboxService.selectedSkills(in: try await store.catalog(), for: project)
        if await isUpToDate(preview, skills: selected) {
            // The files already match, but the manifest still records the timestamps from the last
            // write. Restamping it — Agentbox's own bookkeeping, no backup needed — keeps the
            // project's status honest instead of reporting drift that does not exist. An empty
            // selection has no manifest to restamp; writing one would recreate the clutter the
            // sync path just learned not to leave behind.
            if !selected.isEmpty {
                for tool in project.tools {
                    try SkillboxService.writeSkillManifest(selected, to: projectURL.appending(path: tool.projectSkillsPath))
                }
            }
            Self.removeLegacyBackupDirectories(projectURL)
            return (preview, true)
        }
        var targets = preview.skills.map { URL(fileURLWithPath: $0.target) }
        targets += preview.mcp.map { URL(fileURLWithPath: $0.file) }
        targets += preview.mcp.compactMap { $0.staleFile.map(URL.init(fileURLWithPath:)) }
        // Claude Code's opt-out is a second managed file, not part of `content`. Without it here a
        // failure in docs or plugins rolled `mcp-manifest.json` back but left the opt-out written in
        // the project, so the next sync no longer recognised that name as ours and never cleaned it.
        targets += preview.mcp.compactMap { $0.disabledGlobalFile.map(URL.init(fileURLWithPath:)) }
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        targets += preview.docs.map { URL(fileURLWithPath: $0.file) }
        targets.append(projectURL.appending(path: ".skillbox/docs-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        // The rollback copy exists only for the duration of this write. Once the sync succeeds it
        // protects nothing: the library is the source of truth, the manifests say what Agentbox
        // owns, and `unsyncProject` removes it all cleanly. Keeping it around only produced
        // directories of stale copies.
        let scratch = Self.scratchDirectory()
        defer { if !Self.shouldKeepScratch(scratch) { try? FileManager.default.removeItem(at: scratch) } }
        let (backup, metadata) = try Self.makeSyncBackup(project: projectURL, targets: unique, in: scratch)

        do {
            _ = try await syncProject(id: projectID)
            // The MCP and document previews were computed above; re-deriving them here read the
            // whole library and every managed project file a second time for nothing.
            _ = try await syncMCP(projectID: projectID, previews: preview.mcp)
            _ = try await syncDocs(projectID: projectID, previews: preview.docs)
            Self.removeLegacyBackupDirectories(projectURL)
            return (preview, false)
        } catch {
            throw Self.rollingBack(error, project: projectURL, backup: backup, metadata: metadata, scratch: scratch)
        }
    }

    /// Puts the project back and returns the error to report.
    ///
    /// A rollback that itself fails used to be swallowed by `try?`, after which `defer` deleted the
    /// only copy of the original files: the user was told the operation had been undone while the
    /// project sat half-written and the rescue copy was gone. Now both failures are named, and the
    /// backup directory is deliberately leaked so its path in the message points at something that
    /// still exists.
    private static func rollingBack(_ error: Error, project: URL, backup: URL, metadata: SyncBackupMetadata, scratch: URL) -> Error {
        var report = RollbackReport()
        report.attempt("projekt \(project.lastPathComponent)") {
            try applySyncBackup(project: project, backup: backup, metadata: metadata)
        }
        if !report.succeeded { keptBackups.insert(scratch) }
        return report.error(after: error, keeping: report.succeeded ? nil : backup.path)
    }

    /// The rollback rule, reachable from a test: a backup that cannot be applied must surface both
    /// failures and keep its directory.
    static func rollingBackForTests(_ error: Error, project: URL, backup: URL, relativePath: String, scratch: URL) -> Error {
        rollingBack(error, project: project, backup: backup,
                    metadata: SyncBackupMetadata(createdAt: .now, entries: [SyncBackupEntry(targetRelativePath: relativePath, savedName: "item-0", existed: true)]),
                    scratch: scratch)
    }

    /// Scratch directories a failed rollback left behind on purpose. `scratchDirectory` names each
    /// one uniquely, so nothing else ever looks here; the set exists only so the `defer` that
    /// normally cleans up can tell those apart.
    nonisolated(unsafe) private static var keptBackups = Set<URL>()
    static func shouldKeepScratch(_ url: URL) -> Bool { keptBackups.contains(url) }

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
