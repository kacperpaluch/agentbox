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
    @Published var backupStatus = ""
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
    @Published var detectedFolders: [DetectedProjectFolder] = []
    /// Set when the library folder cannot be opened at all (missing disk, no permissions).
    /// The UI then explains the situation instead of showing an empty library that looks like
    /// lost data.
    @Published var serviceError: String?
    private var automaticBackupTask: Task<Void, Never>?
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
    func reload() async { do { skills = try await service?.listSkills() ?? []; projects = try await service?.listProjects() ?? []; storedProjects = try await service?.storedProjects() ?? []; projectRoots = try await service?.projectRoots() ?? []; mcp = try await service?.mcpConfiguration() ?? MCPConfiguration(); docs = try await service?.docsConfiguration() ?? DocsConfiguration(); if selection == nil { selection = skills.first?.id }; await loadMarkdown() } catch { message = error.localizedDescription }; await scanRoots(); await loadStatuses() }

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
                _ = try await self.service?.addProjectRoot(root, folders: request.folders, serverIDs: request.serverIDs, serverTags: request.serverTags, docIDs: request.docIDs, docTags: request.docTags, treatingExistingAsKnown: request.treatingExistingAsKnown)
                self.message = "Dodano folder \(root.name) i \(request.folders.count) projektów"
            } else {
                for project in request.projects { _ = try await self.service?.addProject(project, serverIDs: request.serverIDs, serverTags: request.serverTags, docIDs: request.docIDs, docTags: request.docTags) }
                self.message = "Dodano \(request.projects.count) projektów"
            }
        }
    }
    func adoptGroupIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], serverIDs: [UUID], serverTags: [String], docIDs: [String], docTags: [String], treatingExistingAsKnown: Bool) {
        Task { await perform { _ = try await self.service?.adoptProjectsIntoRoot(root, following: following, keepingOwnSettings: keepingOwnSettings, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags, treatingExistingAsKnown: treatingExistingAsKnown); self.message = "Utworzono folder \(root.name); wspólnych ustawień używa \(following.count) projektów" } }
    }
    func saveRoot(_ root: ProjectRoot, serverIDs: [UUID], serverTags: [String], docIDs: [String], docTags: [String]) async { await perform { try await self.service?.updateProjectRoot(root, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags); self.message = "Zapisano ustawienia folderu \(root.name)" } }
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
    func addProject(_ project: Project, serverIDs: [UUID], serverTags: [String], docIDs: [String], docTags: [String]) async { await perform { _ = try await self.service?.addProject(project, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags); self.message = "Dodano projekt" } }
    func updateProject(_ project: Project, serverIDs: [UUID], serverTags: [String], docIDs: [String], docTags: [String]) async { await perform { try await self.service?.updateProject(project, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags); self.message = "Zapisano projekt" } }
    func selectedMCPServerIDs(for project: Project) -> [UUID] { selectedMCPServerIDs(selectionID: (inheritsRoot(project) ? project.rootID : nil) ?? project.id) }
    func selectedMCPServerIDs(selectionID: UUID) -> [UUID] { mcp.projectServerIDs?[selectionID.uuidString] ?? [] }
    func selectedMCPServerTags(for project: Project) -> [String] { mcp.projectServerTags?[((inheritsRoot(project) ? project.rootID : nil) ?? project.id).uuidString] ?? [] }
    func selectedDocIDs(for project: Project) -> [String] { selectedDocIDs(selectionID: (inheritsRoot(project) ? project.rootID : nil) ?? project.id) }
    func selectedDocIDs(selectionID: UUID) -> [String] { docs.projectDocIDs?[selectionID.uuidString] ?? [] }
    func selectedDocTags(for project: Project) -> [String] { docs.projectDocTags?[((inheritsRoot(project) ? project.rootID : nil) ?? project.id).uuidString] ?? [] }
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
    func loadBackupStatus() async { backupStatus = (try? await service?.backupStatus()) ?? "Nie można odczytać statusu." }
    func backup(remote: String) async { await perform { self.message = try await self.service?.backup(remote: remote.isEmpty ? nil : remote) ?? "Gotowe" }; await loadBackupStatus() }
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
    /// MCP servers Codex (`~/.codex/config.toml`, shared with the ChatGPT desktop app) or Claude
    /// Code's user scope already declare globally for the given tools — read-only. `selectionID` is
    /// a project's own id, or its parent folder's when the project follows the folder's settings —
    /// the same id `selectedMCPServerIDs(selectionID:)` already uses for regular MCP assignment.
    func globalMCPServers(selectionID: UUID, tools: [Tool]) async -> [GlobalMCPServerRef] { (try? await service?.globalMCPServers(selectionID: selectionID, tools: tools)) ?? [] }
    /// That selection's current opt-outs from those global servers, by tool.
    func disabledGlobalServers(selectionID: UUID) async -> [Tool: [String]] { (try? await service?.disabledGlobalServers(selectionID: selectionID)) ?? [:] }
    /// Saves the full opt-out selection for every tool at once. Actually writing it into
    /// `.codex/config.toml` / `.claude/settings.local.json` still needs a regular project sync,
    /// exactly like assigning a server does — this only updates the library's own record of the choice.
    func setDisabledGlobalServers(selectionID: UUID, name: String, disabled: [Tool: [String]]) async {
        await perform {
            for tool in Tool.allCases { try await self.service?.setDisabledGlobalServers(selectionID: selectionID, tool: tool, names: disabled[tool] ?? []) }
            self.message = "Zapisano wybór globalnych serwerów MCP dla \(name)"
        }
    }
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
    /// Every independent MCP selection that exists: a folder with shared settings, or a project that
    /// does not follow one. The same identity `projectDisabledGlobalServers` keys are stored under —
    /// the "MCP globalne" tab lists these per server, instead of making the user hunt through
    /// Projekty to find where a given global server can be turned off.
    ///
    /// `groupKey`/`groupName`/`isRoot` carry the same grouping Projekty shows (a folder with shared
    /// settings, or projects sharing a parent path), so the two tabs read as one consistent picture
    /// instead of Projekty's structure being invisible here.
    struct MCPSelection: Identifiable, Hashable { let id: UUID; let name: String; let tools: [Tool]; let groupKey: String; let groupName: String; let isRoot: Bool }
    var mcpSelections: [MCPSelection] {
        let fromRoots = projectRoots.map { MCPSelection(id: $0.id, name: $0.name, tools: $0.tools, groupKey: $0.id.uuidString, groupName: $0.name, isRoot: true) }
        let standalone = projects.filter { !inheritsRoot($0) }.map { project -> MCPSelection in
            let path = URL(fileURLWithPath: project.path).deletingLastPathComponent().standardizedFileURL.path
            return MCPSelection(id: project.id, name: project.name, tools: project.tools, groupKey: path, groupName: URL(fileURLWithPath: path).lastPathComponent, isRoot: false)
        }
        return (fromRoots + standalone).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    func previewProjectSync(_ project: Project) async throws -> ProjectSyncPreview { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewProjectSync(projectID: project.id) }
    func syncEverything(_ project: Project) async { await perform { _ = try await self.service?.syncProjectTransaction(projectID: project.id); self.message = "Zsynchronizowano skille, MCP i dokumenty dla \(project.name)" } }
    /// Syncs every project belonging to one shared folder — for the "MCP globalne" tab, where a
    /// toggle is scoped to the whole folder (one selection, one `.codex`/`.claude` override choice)
    /// but only the individual projects inside it have files on disk to actually write.
    func syncRoot(_ root: ProjectRoot) async {
        let affected = projects.filter { self.root(for: $0)?.id == root.id }
        await perform {
            for project in affected { _ = try await self.service?.syncProjectTransaction(projectID: project.id) }
            self.message = "Zsynchronizowano \(affected.count) projektów folderu \(root.name)"
        }
    }
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
    func syncGlobal() async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let previews = try await service.syncGlobalSelection()
            message = "Zsynchronizowano skille globalne: \(previews.count) narzędzi"
            record(.success, message); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func globalSelection() async -> GlobalSkillSelection { (try? await service?.globalSelection()) ?? GlobalSkillSelection() }
    func previewGlobalSync() async throws -> [SkillSyncPreview] { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewGlobalSync() }
    func saveGlobalSelection(_ selection: GlobalSkillSelection) async { await perform { try await self.service?.setGlobalSelection(selection); self.message = "Zapisano wybór globalny" } }
    func restoreLibraryFromRemote(_ remote: String) async {
        await perform { self.message = try await self.service?.restoreLibraryFromRemote(remote, applicationVersion: AppVersion.short) ?? "Gotowe" }
        selection = nil
        await reload(); await loadBackupStatus(); await loadFullBackups()
    }
    func analyzeMCP(_ text: String) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.analyzeMCPJSON(text) }
    func importMCP(_ text: String, serverNames: Set<String>, classifications: [String: MCPValueClassification]) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text, serverNames: serverNames, classifications: classifications); await reload(); scheduleAutomaticBackup(); message = "Zaimportowano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
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
        guard UserDefaults.standard.object(forKey: "AgentboxAutoBackup") == nil || UserDefaults.standard.bool(forKey: "AgentboxAutoBackup") else { return }
        automaticBackupTask?.cancel()
        automaticBackupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let service = self.service else { return }
            do { if let result = try await service.automaticBackup(push: UserDefaults.standard.bool(forKey: "AgentboxAutoPush")) { self.backupStatus = "Automatyczny backup: \(result)" } }
            catch { self.message = "Automatyczny backup: \(error.localizedDescription)" }
        }
    }
    static func csv(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
