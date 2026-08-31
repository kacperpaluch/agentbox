import SwiftUI
import AppKit
import Combine
import SkillboxCore

@MainActor final class AppModel: ObservableObject {
    @Published var skills: [Skill] = []
    @Published var projects: [Project] = []
    @Published var selection: String?
    @Published var markdown = ""
    @Published var message = ""
    @Published var isWorking = false
    @Published var updateAvailable = Set<String>()
    @Published var hasCheckedUpdates = false
    @Published var rootPath: String
    @Published var mcp = MCPConfiguration()
    @Published var docs = DocsConfiguration()
    @Published var operationLog: [OperationLogEntry] = []
    @Published var librarySnapshots: [LibrarySnapshot] = []
    @Published var fullBackups: [FullBackupInfo] = []
    @Published var statuses: [UUID: ProjectStatus] = [:]
    @Published var isCheckingStatuses = false
    /// Projects exactly as they are stored. `projects` carries the settings synchronization uses,
    /// which for a project following a parent folder are the folder's — saving those back would
    /// freeze a copy into the project and break the inheritance the user asked for.
    @Published var storedProjects: [Project] = []
    @Published var projectRoots: [ProjectRoot] = []
    /// Every place's attachments, exactly as `selections.json` holds them. One map for projects,
    /// parent folders and this Mac alike — the Mac under the key `"global"`.
    @Published var selections: [String: AttachmentSelection] = [:]
    /// A local template used only to prefill the editor for a newly added project.
    @Published var projectDefaults = AttachmentSelection(tools: Tool.allCases)
    @Published var claudePluginLibrary: [ClaudePluginDefinition] = []
    /// What this Mac itself gets. A view onto `selections`, so `Projekty` can list it as a row.
    var global: AttachmentSelection { selections[SelectionTarget.global.storageKey] ?? AttachmentSelection() }
    @Published var detectedFolders: [DetectedProjectFolder] = []
    /// Set when the library folder cannot be opened at all (missing disk, no permissions).
    /// The UI then explains the situation instead of showing an empty library that looks like
    /// lost data.
    @Published var serviceError: String?
    private var lastActivationScan = Date.distantPast
    private var lastFullBackupCheck = Date.distantPast
    var service: SkillboxService?
    init() {
        let saved = UserDefaults.standard.string(forKey: "SkillboxLibraryRoot")
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Skillbox").path
        let shared = AgentboxRootPreference.load()?.path
        rootPath = saved ?? shared ?? defaultPath
        do { service = try SkillboxService(root: URL(fileURLWithPath: rootPath)) }
        catch { serviceError = "Nie można otworzyć biblioteki w \(rootPath): \(error.localizedDescription)" }
        Task { await reload(); await createFullBackupIfDue() }
    }
    // Statuses depend on the exact things reload() refreshes (skills, tags, MCP servers and their
    // tags), so it recomputes them here too. That is the only place callers need to remember to
    // call — a skill tag edit or a new tagged MCP server no longer leaves the Projects tab showing
    // a stale "synced" badge until someone happens to touch a project directly.
    func reload() async { do { skills = try await service?.listSkills() ?? []; projects = try await service?.listProjects() ?? []; storedProjects = try await service?.storedProjects() ?? []; projectRoots = try await service?.projectRoots() ?? []; mcp = try await service?.mcpConfiguration() ?? MCPConfiguration(); docs = try await service?.docsConfiguration() ?? DocsConfiguration(); claudePluginLibrary = try await service?.libraryClaudePlugins() ?? []; selections = try await service?.allSelections() ?? [:]; projectDefaults = try await service?.projectDefaults() ?? AttachmentSelection(tools: Tool.allCases); if selection == nil { selection = skills.first?.id }; await loadMarkdown() } catch { message = error.localizedDescription }; await scanRoots(); await loadStatuses() }

    // MARK: Parent folders

    /// Looks for subfolders that appeared in a watched parent folder since it was added. It runs on
    /// every reload, so a project cloned into the folder outside Agentbox shows up on its own
    /// instead of waiting for the user to remember to add it.
    func scanRoots() async { detectedFolders = (try? await service?.scanProjectRoots()) ?? [] }
    /// What `Sprawdź stan` does: look at the world again. Statuses alone answered "czy projekty
    /// odpowiadają bibliotece" but never noticed a folder cloned in while Agentbox was open.
    func refreshProjects() async { await scanRoots(); await loadStatuses() }
    /// Repositories are cloned in a terminal, not in Agentbox, so the moment the user comes back to
    /// the app is exactly when a new subfolder should be waiting for them. The scan is a directory
    /// listing per watched folder; the interval only keeps window switching from repeating it.
    func scanRootsOnActivation() async {
        if !projectRoots.isEmpty, Date.now.timeIntervalSince(lastActivationScan) > 5 {
            lastActivationScan = .now
            await scanRoots()
        }
        await createFullBackupIfDue()
    }

    /// The full local backup used to be something the user had to remember to click — the one
    /// mechanism protecting projects and secrets, easy to forget precisely because it never
    /// complains. Coming back to the app is checked at most every few minutes, and a new backup is
    /// made at most once a day; `createFullBackup` prunes old ones, so this never grows unbounded.
    private func createFullBackupIfDue() async {
        guard Date.now.timeIntervalSince(lastFullBackupCheck) > 300 else { return }
        lastFullBackupCheck = .now
        guard UserDefaults.standard.object(forKey: "AgentboxAutoBackup") == nil || UserDefaults.standard.bool(forKey: "AgentboxAutoBackup") else { return }
        guard let service else { return }
        do {
            let existing = try await service.fullBackups()
            guard (existing.first?.createdAt ?? .distantPast) < Date.now.addingTimeInterval(-86400) else { return }
            let backup = try await service.createFullBackup(applicationVersion: AppVersion.short)
            fullBackups = try await service.fullBackups()
            record(.success, "Automatyczny pełny backup: \(backup.name)")
        } catch { /* best-effort safety net — a failure here should not interrupt the session */ }
    }
    func root(for project: Project) -> ProjectRoot? { project.rootID.flatMap { id in projectRoots.first { $0.id == id } } }
    func inheritsRoot(_ project: Project) -> Bool { project.overridesRoot != true && root(for: project) != nil }
    func storedProject(id: UUID) -> Project? { storedProjects.first { $0.id == id } }
    func addBatch(_ request: BatchProjectRequest) async {
        await perform {
            if let root = request.root {
                _ = try await self.service?.addProjectRoot(root, folders: request.folders, selection: request.selection, treatingExistingAsKnown: request.treatingExistingAsKnown)
                self.message = "Dodano folder \(root.name) i \(request.folders.count) projektów"
            } else {
                for project in request.projects { _ = try await self.service?.addProject(project, selection: request.selection) }
                self.message = "Dodano \(request.projects.count) projektów"
            }
        }
    }
    func adoptGroupIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], selection: AttachmentSelection, treatingExistingAsKnown: Bool) {
        Task { await perform { _ = try await self.service?.adoptProjectsIntoRoot(root, following: following, keepingOwnSettings: keepingOwnSettings, selection: selection, treatingExistingAsKnown: treatingExistingAsKnown); self.message = "Utworzono folder \(root.name); wspólnych ustawień używa \(following.count) projektów" } }
    }
    func saveRoot(_ root: ProjectRoot, selection: AttachmentSelection) async { await perform { try await self.service?.updateProjectRoot(root, selection: selection); self.message = "Zapisano ustawienia folderu \(root.name)" } }
    func deleteRoot(_ root: ProjectRoot) async { await perform { try await self.service?.deleteProjectRoot(id: root.id); self.message = "Usunięto ustawienia folderu \(root.name); projekty zachowały to, co dziedziczyły" } }
    func clearIgnoredFolders(_ root: ProjectRoot) async { await perform { try await self.service?.clearIgnoredFolders(rootID: root.id); self.message = "Wyczyszczono pominięte podfoldery w \(root.name)" } }
    func ignoreDetected(_ folders: [DetectedProjectFolder]) async { await perform { try await self.service?.ignoreDetectedFolders(folders); self.message = "Pominięto \(folders.count) podfolderów" } }
    /// Adds the detected subfolders and — when asked — synchronizes them right away, which is the
    /// point of the question: a new project in a known folder should end up ready to use.
    func addDetected(_ folders: [DetectedProjectFolder], synchronizing: Bool) async {
        await perform {
            let added = try await self.service?.addDetectedFolders(folders) ?? []
            guard synchronizing else { self.message = "Dodano \(added.count) projektów"; return }
            var synced = 0
            var failures: [String] = []
            for project in added {
                do { _ = try await self.service?.syncProjectTransaction(projectID: project.id); synced += 1 }
                catch { failures.append("\(project.name): \(error.localizedDescription)") }
            }
            self.message = failures.isEmpty
                ? "Dodano i zsynchronizowano \(synced) projektów"
                : "Dodano \(added.count) projektów, zsynchronizowano \(synced). Nie udało się: \(failures.joined(separator: "; "))"
        }
    }
    func loadMarkdown() async { guard let selection else { markdown = ""; return }; markdown = (try? await service?.skillMarkdown(skillID: selection)) ?? "" }
    func addLocal(_ url: URL) async { await perform(autoBackup: true) { _ = try await self.service?.addLocal(path: url.path); self.message = "Dodano skill z dysku" } }
    func createSkill(_ draft: NewSkillDraft) async {
        await perform(autoBackup: true) {
            let skill = try await self.service?.createSkill(id: draft.id, name: draft.name, description: draft.description, content: draft.content, tags: draft.tags)
            if let skill { self.selection = skill.id }
            self.message = "Utworzono skill \(draft.id)"
        }
    }
    func addGit(_ url: String, subpath: String) async { await perform(autoBackup: true) {
        let urls = url.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var count = 0; var skipped: [SkippedSkill] = []
        for item in urls { if let result = try await self.service?.addGitCollection(url: item, subpath: subpath.isEmpty ? nil : subpath) { count += result.imported.count; skipped += result.skipped } }
        self.message = skipped.isEmpty ? "Zaimportowano \(count) skilli" : "Zaimportowano \(count) skilli, pominięto \(skipped.count): " + skipped.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ")
    } }
    func checkUpdates() async { isWorking = true; defer { isWorking = false }; do { updateAvailable = try await service?.checkUpdates() ?? []; hasCheckedUpdates = true; message = updateAvailable.isEmpty ? "Wszystkie skille są aktualne" : "Dostępne aktualizacje: \(updateAvailable.count)" } catch { message = error.localizedDescription } }
    func update(_ id: String) async { await perform(autoBackup: true) { _ = try await self.service?.update(skillID: id); self.updateAvailable.remove(id); self.message = "Zaktualizowano \(id)" } }
    /// Mirrors `agentbox update --all` in the GUI. Updating one skill is intentionally independent
    /// of the next: a temporary problem with one repository must not prevent the remaining skills
    /// from receiving their available revisions.
    func updateAllAvailable() async {
        let ids = updateAvailable.sorted()
        guard !ids.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }
        var updated: [String] = []
        var failures: [String] = []
        for id in ids {
            do {
                _ = try await service?.update(skillID: id)
                updated.append(id)
                updateAvailable.remove(id)
            } catch {
                failures.append("\(id): \(error.localizedDescription)")
            }
        }
        await reload()
        message = failures.isEmpty
            ? "Zaktualizowano \(updated.count) skilli"
            : "Zaktualizowano \(updated.count) z \(ids.count) skilli. Nie udało się: \(failures.joined(separator: "; "))"
        record(failures.isEmpty ? .success : .error, message)
        if !updated.isEmpty { scheduleAutomaticBackup() }
    }
    func saveSkillMarkdown(_ id: String, content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            try await service?.saveSkillMarkdown(skillID: id, content: content)
            message = "Zapisano \(id)"; record(.success, message)
            await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveTags(_ id: String, text: String) async { await perform(autoBackup: true) { try await self.service?.setTags(skillID: id, tags: Self.csv(text)); self.message = "Zapisano tagi" } }
    func addTags(_ ids: Set<String>, text: String) async { await perform(autoBackup: true) { try await self.service?.addTags(skillIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) skilli" } }
    func deleteSkill(_ id: String) async { await perform(autoBackup: true) { try await self.service?.deleteSkill(skillID: id); if self.selection == id { self.selection = nil; self.markdown = "" }; self.updateAvailable.remove(id); self.message = "Usunięto skill \(id)" } }
    func deleteSkills(_ ids: Set<String>) async {
        await perform(autoBackup: true) {
            try await self.service?.deleteSkills(skillIDs: Array(ids))
            if let selection = self.selection, ids.contains(selection) { self.selection = nil; self.markdown = "" }
            self.updateAvailable.subtract(ids)
            self.message = "Usunięto \(ids.count) skilli"
        }
    }
    func claudePlugins(for project: Project) async throws -> [ClaudePlugin] {
        guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
        return try await service.claudePlugins(projectPath: project.path)
    }
    func addLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async { await perform(autoBackup: true) { try await self.service?.addLibraryClaudePlugin(plugin); self.message = "Dodano plugin Claude do biblioteki" } }
    func selectedClaudePluginIDs(for project: Project) async throws -> [UUID] { try await service?.selectedClaudePluginIDs(projectID: project.id) ?? [] }
    func saveClaudePluginSelection(project: Project, ids: [UUID]) async { await perform { try await self.service?.setClaudePluginSelection(projectID: project.id, ids: ids); self.message = "Zapisano pluginy Claude dla \(project.name)" } }
    func installClaudePlugin(project: Project, marketplace: String?, plugin: String, scope: ClaudePluginScope) async {
        await perform {
            try await self.service?.installClaudePlugin(projectPath: project.path, marketplace: marketplace, plugin: plugin, scope: scope)
            self.message = "Zainstalowano plugin Claude w projekcie \(project.name)"
        }
    }
    func uninstallClaudePlugin(project: Project, plugin: ClaudePlugin) async {
        await perform {
            try await self.service?.uninstallClaudePlugin(projectPath: project.path, plugin: plugin)
            self.message = "Usunięto plugin \(plugin.id)"
        }
    }
    func addProject(_ project: Project, selection: AttachmentSelection) async { await perform { _ = try await self.service?.addProject(project, selection: selection); self.message = "Dodano projekt" } }
    func updateProject(_ project: Project, selection: AttachmentSelection) async { await perform { try await self.service?.updateProject(project, selection: selection); self.message = "Zapisano projekt" } }
    /// The state already loaded here, in the shape the core expects. Rebuilding it costs nothing and
    /// lets the whole app answer "what is attached to this place" through the very same code a sync
    /// runs, instead of six accessors that each reimplemented the inheritance rule.
    private var localConfiguration: LocalConfiguration {
        var config = LocalConfiguration()
        config.projects = storedProjects
        config.projectRoots = projectRoots
        config.selections = selections
        return config
    }

    /// What is attached to a place. `resolvingInheritance` picks between the two questions the UI
    /// actually asks: what a project *uses* (the folder's settings, when it follows one) and what is
    /// *written down* for it (its own record, which an editor must show so saving cannot silently
    /// freeze a copy of the folder onto the project).
    func selection(for target: SelectionTarget, resolvingInheritance: Bool = false) -> AttachmentSelection {
        SkillboxService.selection(for: target, config: localConfiguration, resolvingInheritance: resolvingInheritance)
    }

    func saveSelection(_ selection: AttachmentSelection, for target: SelectionTarget, named name: String) async {
        await perform { try await self.service?.setSelection(selection, for: target); self.message = "Zapisano ustawienia: \(name)" }
    }
    func saveProjectDefaults(_ selection: AttachmentSelection) async {
        await perform { try await self.service?.setProjectDefaults(selection); self.message = "Zapisano domyślne ustawienia nowych projektów" }
    }
    func deleteProject(_ project: Project, removingFiles: Bool) async {
        await perform {
            if removingFiles {
                let removed = try await self.service?.unsyncProject(id: project.id) ?? []
                try await self.service?.deleteProject(id: project.id)
                self.message = "Usunięto projekt \(project.name) i \(removed.count) elementów z jego folderu"
            } else {
                try await self.service?.deleteProject(id: project.id)
                self.message = "Usunięto projekt \(project.name) z Agentbox; pliki w jego folderze zostały bez zmian"
            }
        }
    }
    func loadStatuses() async {
        isCheckingStatuses = true; defer { isCheckingStatuses = false }
        guard let service else { return }
        do { statuses = Dictionary(uniqueKeysWithValues: try await service.projectStatuses().map { ($0.projectID, $0) }) }
        catch { reportError(error) }
    }
    func unsyncProject(_ project: Project) async {
        await perform { let removed = try await self.service?.unsyncProject(id: project.id) ?? []; self.message = "Usunięto \(removed.count) elementów z \(project.name)" }
    }
    func adoptableSkills(_ project: Project) async throws -> [AdoptableSkill] {
        guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
        return try await service.adoptableSkills(projectID: project.id)
    }
    func adoptSkills(_ items: [AdoptableSkill]) async {
        await perform { let adopted = try await self.service?.adoptSkills(items) ?? []; self.message = "Przejęto \(adopted.count) skilli do biblioteki" }
    }
    func loadFullBackups() async { do { fullBackups = try await service?.fullBackups() ?? [] } catch { reportError(error) } }
    func createFullBackup() async { await perform { guard let service = self.service else { throw SkillboxError.commandFailed("Brak usługi") }; let backup = try await service.createFullBackup(applicationVersion: AppVersion.short); self.message = "Utworzono pełny backup: \(backup.name)" }; await loadFullBackups() }
    func restoreFullBackup(_ backup: FullBackupInfo) async { await perform { try await self.service?.restoreFullBackup(named: backup.name); self.message = "Przywrócono pełny backup: \(backup.name)" }; await loadFullBackups() }
    func deleteFullBackup(_ backup: FullBackupInfo) async { await perform { try await self.service?.deleteFullBackup(named: backup.name); self.message = "Usunięto pełny backup: \(backup.name)" }; await loadFullBackups() }
    func loadRecovery() async { do { librarySnapshots = try await service?.librarySnapshots() ?? [] } catch { reportError(error) } }
    func restoreLibrary(_ snapshot: LibrarySnapshot) async { await perform { let files = try await self.service?.restoreLibrarySnapshot(named: snapshot.name) ?? []; self.message = "Przywrócono snapshot biblioteki: \(files.joined(separator: ", "))" }; await loadRecovery() }
    func managedFields(for server: MCPServer) async -> [MCPManagedField] { (try? await service?.managedFields(serverID: server.id)) ?? [] }
    func saveMCPServer(_ server: MCPServer, fields: [MCPManagedField]) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            try await service?.saveMCPServer(server, managedFields: fields)
            message = "Zapisano serwer MCP"; record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func duplicateMCPServer(_ server: MCPServer, name: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await service?.duplicateMCPServer(id: server.id, name: name)
            message = "Utworzono kopię serwera MCP"; record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func deleteMCPServer(_ id: UUID) async { await perform(autoBackup: true) { try await self.service?.deleteMCPServer(id: id); self.message = "Usunięto serwer MCP" } }
    func addMCPServerTags(_ ids: Set<UUID>, text: String) async { await perform(autoBackup: true) { try await self.service?.addMCPServerTags(serverIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) serwerów MCP" } }
    func exportMCPServerJSON(_ id: UUID) async -> String { (try? await service?.exportMCPServerJSON(id)) ?? "" }
    func exportMCPConfigurationJSON() async -> String { (try? await service?.exportMCPConfigurationJSON(mcp.servers)) ?? "" }
    func updateMCPServerJSON(_ id: UUID, name: String, json: String, enabled: Bool, tags: [String]) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await service?.updateMCPServerJSON(id, name: name, json: json, enabled: enabled, tags: tags)
            message = "Zapisano serwer MCP"; record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func createDoc(id: String, name: String, tags: [String], content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            let doc = try await service?.createDoc(id: id, name: name, tags: tags, content: content)
            if let doc { selection = nil; message = "Utworzono dokument \(doc.id)" } else { message = "Utworzono dokument" }
            record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveDocContent(_ id: String, name: String, content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            try await service?.saveDocContent(docID: id, name: name, content: content)
            message = "Zapisano \(id)"; record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveDocTags(_ id: String, text: String) async { await perform(autoBackup: true) { try await self.service?.setDocTags(docID: id, tags: Self.csv(text)); self.message = "Zapisano tagi" } }
    func addDocTags(_ ids: Set<String>, text: String) async { await perform(autoBackup: true) { try await self.service?.addDocTags(docIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) dokumentów" } }
    func deleteDoc(_ id: String) async { await perform(autoBackup: true) { try await self.service?.deleteDoc(id: id); self.message = "Usunięto dokument \(id)" } }
    func previewMCP(_ project: Project) async throws -> [MCPPreview] { try await service?.previewMCP(projectID: project.id) ?? [] }
    /// Server names Codex/Claude Code declare globally, straight from disk — the same source
    /// `GlobalMCPServersView` reads, but unfiltered by any one project's assignments, for the
    /// "MCP globalne" tab's server-by-server overview.
    func globalMCPServerNames(tool: Tool) -> [String] {
        switch tool {
        case .codex: GlobalMCPDiscovery.codexGlobalServerNames()
        case .claude: GlobalMCPDiscovery.claudeGlobalServerNames()
        case .opencode: []
        }
    }
    /// One row in the "MCP globalne" tab: a single real project that can see the tool's global
    /// servers, together with the selection whose opt-out actually governs it — its own id, or its
    /// parent folder's while it still follows the folder. Rows are built from projects rather than
    /// from selections so no project can be missing from the list, and none can show up under a tool
    /// it does not use.
    struct GlobalMCPRow: Identifiable, Hashable {
        let project: Project
        /// Where the opt-out is stored: `project.id`, or the folder's id while `inherits` is true.
        let selectionID: UUID
        /// Still sharing the folder's settings, so its checkbox reflects a decision made for the
        /// whole folder until the project is given settings of its own.
        let inherits: Bool
        var id: UUID { project.id }
    }
    struct GlobalMCPGroup: Identifiable, Hashable {
        let key: String
        let name: String
        let rows: [GlobalMCPRow]
        var id: String { key }
    }

    /// Every project that uses `tool`, grouped the way Projekty groups them: by parent folder, with
    /// a folder that has shared settings named after the folder. Projects inheriting one folder all
    /// point at the same `selectionID`, so their checkboxes stay in sync until one is split off.
    func globalMCPGroups(tool: Tool) -> [GlobalMCPGroup] {
        var order: [String] = []
        var buckets: [String: (name: String, rows: [GlobalMCPRow])] = [:]
        for project in projects.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            guard project.tools.contains(tool) else { continue }
            let folder = root(for: project)
            let inherits = inheritsRoot(project)
            let key: String
            let name: String
            if let folder {
                key = URL(fileURLWithPath: folder.path).standardizedFileURL.path
                name = folder.name
            } else {
                let parent = URL(fileURLWithPath: project.path).deletingLastPathComponent().standardizedFileURL
                key = parent.path
                name = parent.lastPathComponent
            }
            if buckets[key] == nil { order.append(key); buckets[key] = (name, []) }
            buckets[key]?.rows.append(GlobalMCPRow(project: project, selectionID: inherits ? (folder?.id ?? project.id) : project.id, inherits: inherits))
        }
        return order.compactMap { key in buckets[key].map { GlobalMCPGroup(key: key, name: $0.name, rows: $0.rows) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Splits a shared folder off for one project, the same "Własne ustawienia" switch the project
    /// editor offers — done here so a single global-MCP checkbox can use it without a trip there. The
    /// project keeps exactly what it has today (tools, skills, tags, MCP assignment, doc, and any
    /// global-server opt-out already in effect through the folder); it just stops following future
    /// changes to the folder.
    @discardableResult
    func promoteToOwnSettings(_ project: Project) async -> Bool {
        guard let folder = root(for: project) else { return true }
        isWorking = true; defer { isWorking = false }
        do {
            var updated = project
            updated.overridesRoot = true
            let inherited = selection(for: .project(project.id), resolvingInheritance: true)
            try await service?.updateProject(updated, selection: inherited)
            // Carry over whatever the folder currently opts out of, so the split does not silently
            // re-enable something the folder had turned off.
            for (toolRaw, names) in mcp.projectDisabledGlobalServers?[folder.id.uuidString] ?? [:] {
                if let tool = Tool(rawValue: toolRaw) { try await service?.setDisabledGlobalServers(selectionID: project.id, tool: tool, names: names) }
            }
            await reload()
            message = "\(project.name) ma teraz własne ustawienia (zaczyna od tego, co miał w folderze \(folder.name))"
            record(.success, message)
            return true
        } catch { reportError(error); await reload(); return false }
    }
    /// The row-aware counterpart of `setGlobalServerDisabled(selectionID:...)`: a project still
    /// following its folder gets promoted to its own settings first, so the toggle lands on it alone
    /// instead of on every project in the folder.
    func setGlobalServerDisabled(row: GlobalMCPRow, tool: Tool, name: String, disabled: Bool) async {
        if row.inherits { guard await promoteToOwnSettings(row.project) else { return } }
        await setGlobalServerDisabled(selectionID: row.inherits ? row.project.id : row.selectionID, tool: tool, name: name, disabled: disabled)
    }
    /// Whether a global server is on the list every newly added project starts out opted out of.
    func isGlobalServerDisabledByDefault(tool: Tool, name: String) -> Bool {
        mcp.defaultDisabledGlobalServers?[tool.rawValue]?.contains(name) == true
    }
    /// Changes that list. Existing projects are untouched by design — this only decides where the
    /// next one starts, which is what makes it safe to flip at any time.
    func setGlobalServerDisabledByDefault(tool: Tool, name: String, disabled: Bool) async {
        isWorking = true; defer { isWorking = false }
        do {
            var names = Set(mcp.defaultDisabledGlobalServers?[tool.rawValue] ?? [])
            if disabled { names.insert(name) } else { names.remove(name) }
            try await service?.setDefaultDisabledGlobalServers(tool: tool, names: Array(names))
            mcp = try await service?.mcpConfiguration() ?? mcp
        } catch { reportError(error) }
    }
    /// Whether one selection currently opts a named global server out, straight from the already
    /// loaded configuration — so every toggle in the "MCP globalne" table can bind to this directly
    /// without a per-row network round trip.
    func isGlobalServerDisabled(selectionID: UUID, tool: Tool, name: String) -> Bool {
        mcp.projectDisabledGlobalServers?[selectionID.uuidString]?[tool.rawValue]?.contains(name) == true
    }
    /// Flips one selection's opt-out for one global server. Lighter than `perform`: it only refreshes
    /// `mcp` instead of the whole library, since that is all a checkbox in this table can affect, and
    /// it does not surface a toast for every click — the table itself is the confirmation.
    func setGlobalServerDisabled(selectionID: UUID, tool: Tool, name: String, disabled: Bool) async {
        isWorking = true; defer { isWorking = false }
        do {
            var names = Set(mcp.projectDisabledGlobalServers?[selectionID.uuidString]?[tool.rawValue] ?? [])
            if disabled { names.insert(name) } else { names.remove(name) }
            try await service?.setDisabledGlobalServers(selectionID: selectionID, tool: tool, names: Array(names))
            mcp = try await service?.mcpConfiguration() ?? mcp
        } catch { reportError(error) }
    }
    /// The "Wyłącz wszędzie" / "Włącz wszędzie" action next to each server: applies the same choice
    /// to every selection at once instead of clicking through each checkbox in turn. One refresh at
    /// the end, not one per selection.
    func setGlobalServerDisabledEverywhere(tool: Tool, name: String, disabled: Bool, selectionIDs: [UUID]) async {
        isWorking = true; defer { isWorking = false }
        do {
            for selectionID in Set(selectionIDs) {
                var names = Set(mcp.projectDisabledGlobalServers?[selectionID.uuidString]?[tool.rawValue] ?? [])
                if disabled { names.insert(name) } else { names.remove(name) }
                try await service?.setDisabledGlobalServers(selectionID: selectionID, tool: tool, names: Array(names))
            }
            mcp = try await service?.mcpConfiguration() ?? mcp
            message = disabled ? "Wyłączono \(name) wszędzie" : "Włączono z powrotem \(name) wszędzie"
        } catch { reportError(error) }
    }
    func previewProjectSync(_ project: Project) async throws -> ProjectSyncPreview { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewProjectSync(projectID: project.id) }
    func syncEverything(_ project: Project) async { await perform { _ = try await self.service?.syncProjectTransaction(projectID: project.id); self.message = "Zsynchronizowano skille, MCP, dokumenty i pluginy dla \(project.name)" } }
    func previewAllProjectsSync() async throws -> [ProjectSyncPlan] { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewAllProjectsSync() }
    func syncAllProjects() async -> [ProjectSyncOutcome] {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let outcomes = try await service.syncAllProjectsTransactions()
            let synced = outcomes.filter { $0.state == .synced }.count
            let upToDate = outcomes.filter { $0.state == .upToDate }.count
            if synced + upToDate == outcomes.count {
                message = upToDate == 0 ? "Zsynchronizowano wszystkie projekty: \(synced)" : "Zsynchronizowano \(synced), bez zmian \(upToDate)"
                record(.success, message)
            }
            else {
                message = "Zsynchronizowano \(synced) z \(outcomes.count) projektów"
                record(.error, message)
                for outcome in outcomes { if case .failed(let reason) = outcome.state { record(.error, "\(outcome.plan.project.name): \(reason)") } }
            }
            await reload()
            return outcomes
        } catch {
            await reload()
            message = error.localizedDescription
            record(.error, message)
            return []
        }
    }
    /// The GUI counterpart of `agentbox refresh`: update skills, make a local backup, then apply
    /// the already transactional all-project synchronization.
    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let updates = try await service.checkUpdates().sorted()
            for id in updates { _ = try await service.update(skillID: id) }
            updateAvailable.subtract(updates)

            let localBackup = try await service.createFullBackup(applicationVersion: AppVersion.short)
            let outcomes = try await service.syncAllProjectsTransactions()

            let synced = outcomes.filter { $0.state == .synced }.count
            let unchanged = outcomes.filter { $0.state == .upToDate }.count
            let failed = outcomes.filter { outcome in
                if case .failed = outcome.state { return true }
                return false
            }
            let skipped = outcomes.filter { $0.state == .skipped }.count
            message = "Odświeżono \(updates.count) skilli, utworzono backup \(localBackup.name), zsynchronizowano \(synced) projektów"
            if unchanged > 0 { message += ", bez zmian \(unchanged)" }
            if !failed.isEmpty || skipped > 0 { message += ", wymaga uwagi: \(failed.count) błędów, \(skipped) pominiętych" }
            record(failed.isEmpty && skipped == 0 ? .success : .error, message)
            for outcome in failed {
                if case .failed(let reason) = outcome.state { record(.error, "\(outcome.plan.project.name): \(reason)") }
            }
            await reload()
            await loadFullBackups()
        } catch {
            await reload()
            message = "Nie ukończono odświeżania: \(error.localizedDescription)"
            record(.error, message)
        }
    }
    func syncGlobal() async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let previews = try await service.syncGlobalSelection()
            message = "Zsynchronizowano skille globalne: \(previews.count) narzędzi"
            record(.success, message); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    // The global selection is read into `global` by `reload()` and written through `saveSelection`,
    // like every other place — only the preview stays a call of its own, because it inspects the
    // user's skill directories rather than the library.
    func previewGlobalSync() async throws -> [SkillSyncPreview] { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewGlobalSync() }
    func analyzeMCP(_ text: String, singleServerName: String? = nil) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.analyzeMCPJSON(text, singleServerName: singleServerName) }
    func generateMCP(_ instructions: String, apiKey: String, model: String) async throws -> String { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.generateMCPConfiguration(instructions: instructions, apiKey: apiKey, model: model) }
    func importMCP(_ text: String, serverNames: Set<String>, classifications: [String: MCPValueClassification], singleServerName: String? = nil) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text, serverNames: serverNames, classifications: classifications, singleServerName: singleServerName); await reload(); scheduleAutomaticBackup(); message = "Zaimportowano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
    /// Applies every server the JSON describes — no selection step, because this text is a re-edit
    /// of the library's own configuration rather than something pasted in from elsewhere.
    func importMCPJSONAll(_ text: String) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text); await reload(); scheduleAutomaticBackup(); message = "Zapisano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
    func moveLibrary(to url: URL) async {
        isWorking = true; defer { isWorking = false }
        do {
            let existing = SkillboxService.isExistingLibrary(at: url)
            if existing {
                let candidate = try SkillboxService(root: url)
                try await candidate.validateLibrary()
                service = candidate
            } else {
                try await service?.copyLibrary(to: url)
                service = try SkillboxService(root: url)
            }
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "SkillboxLibraryRoot")
            try AgentboxRootPreference.save(url)
            rootPath = url.standardizedFileURL.path
            serviceError = nil
            selection = nil
            await reload()
            message = existing ? "Podłączono istniejącą bibliotekę" : "Biblioteka skopiowana do nowego folderu"
        }
        catch { message = error.localizedDescription }
    }
    private func perform(autoBackup: Bool = false, _ action: @escaping @MainActor () async throws -> Void) async { isWorking = true; defer { isWorking = false }; do { try await action(); await reload(); if !message.isEmpty { record(.success, message) }; if autoBackup { scheduleAutomaticBackup() } } catch { await reload(); message = error.localizedDescription; record(.error, message) } }
    private func record(_ kind: OperationLogEntry.Kind, _ text: String) { operationLog.insert(OperationLogEntry(kind: kind, text: text), at: 0); if operationLog.count > 100 { operationLog.removeLast(operationLog.count - 100) } }
    func reportError(_ error: Error) { message = error.localizedDescription; record(.error, message) }
    private func scheduleAutomaticBackup() {
        // Full local backups are created at most once a day when the app becomes active.
        // Per-edit Git commits are intentionally gone.
    }
    static func csv(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
