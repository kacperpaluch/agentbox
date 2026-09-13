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
    /// Set while a run that walks project by project is going, so the overlay can say "3/30
    /// Synchronizuję agentbox" instead of spinning anonymously. `nil` means "no countable work".
    @Published var progress: SyncProgress?
    /// Handed to the service so each project it finishes moves the bar. Every hop lands on the main
    /// actor in order, so the label can never show a step the run has already passed.
    private var progressHandler: SyncProgressHandler { { value in await MainActor.run { self.progress = value } } }
    @Published var updateAvailable = Set<String>()
    @Published var hasCheckedUpdates = false
    @Published var updateReview: SkillUpdatePlan?
    @Published var reviewIncludesSync = false
    @Published var automaticBackupError: String?
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
    /// Notices changes made to the library outside Agentbox — a skill edited in an editor, the CLI
    /// writing `catalog.json`, a restored backup — so the window stops showing what the library
    /// looked like when it was opened.
    private let watcher = LibraryWatcher()
    private var reloadingFromDisk = false
    var service: SkillboxService?
    /// `root` is only passed by tests and previews, which must never touch the real library. The
    /// app itself takes the folder the user chose, so the argument stays at its default.
    init(root: URL? = nil, startsAutomatically: Bool = true) {
        let saved = root?.path ?? UserDefaults.standard.string(forKey: "SkillboxLibraryRoot")
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Skillbox").path
        let shared = root == nil ? AgentboxRootPreference.load()?.path : nil
        rootPath = saved ?? shared ?? defaultPath
        do { service = try SkillboxService(root: URL(fileURLWithPath: rootPath)) }
        catch { serviceError = "Nie można otworzyć biblioteki w \(rootPath): \(error.localizedDescription)" }
        // Off in tests: a live FSEvents stream on the temporary library answers the test's own
        // writes, and its reload lands mid-assertion. `libraryChangedOnDisk` is tested directly.
        if startsAutomatically { startWatchingLibrary(); Task { await reload(); await createFullBackupIfDue() } }
    }

    private func startWatchingLibrary() {
        guard serviceError == nil else { return }
        watcher.start(root: URL(fileURLWithPath: rootPath)) { [weak self] in self?.libraryChangedOnDisk() }
    }

    /// Something in the library folder changed. `isWorking` means Agentbox is the one writing, and
    /// that path reloads by itself when it finishes, so answering here would only repeat the work.
    ///
    /// A write of our own whose events arrive after the action already finished still costs one
    /// extra reload. That reload only reads, so the cheap guard is preferred over a timing window
    /// that could swallow a real edit made a moment after the app's own.
    /// Returns whether it started a reload, so the rule can be checked without racing the real
    /// stream — a watch on a live folder answers a test's own writes too.
    @discardableResult
    func libraryChangedOnDisk() -> Bool {
        guard !isWorking, !reloadingFromDisk else { return false }
        reloadingFromDisk = true
        Task { await reload(); reloadingFromDisk = false }
        return true
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
    func createFullBackupIfDue(now: Date = .now, enabled: Bool? = nil) async {
        guard now.timeIntervalSince(lastFullBackupCheck) > 300, !isWorking else { return }
        lastFullBackupCheck = now
        guard enabled ?? (UserDefaults.standard.object(forKey: "AgentboxAutoBackup") == nil || UserDefaults.standard.bool(forKey: "AgentboxAutoBackup")) else { return }
        guard let service else { return }
        do {
            fullBackups = try await service.fullBackups()
            guard (fullBackups.first?.createdAt ?? .distantPast) < now.addingTimeInterval(-86400) else { return }
            let backup = try await service.createFullBackup(applicationVersion: AppVersion.short)
            fullBackups = try await service.fullBackups()
            automaticBackupError = nil
            record(.success, "Automatyczny pełny backup: \(backup.name)")
        } catch {
            automaticBackupError = "Automatyczny backup nie powiódł się: \(error.localizedDescription)"
            record(.error, "Automatyczny backup nie powiódł się: \(error.localizedDescription)")
        }
    }
    func root(for project: Project) -> ProjectRoot? { project.rootID.flatMap { id in projectRoots.first { $0.id == id } } }
    func inheritsRoot(_ project: Project) -> Bool { project.overridesRoot != true && root(for: project) != nil }
    func storedProject(id: UUID) -> Project? { storedProjects.first { $0.id == id } }
    @discardableResult
    func addBatch(_ request: BatchProjectRequest) async -> Bool {
        await performing {
            if let root = request.root {
                _ = try await self.service?.addProjectRoot(root, folders: request.folders, selection: request.selection, treatingExistingAsKnown: request.treatingExistingAsKnown)
                self.message = "Dodano folder \(root.name) i \(request.folders.count) projektów"
            } else {
                for project in request.projects { _ = try await self.service?.addProject(project, selection: request.selection) }
                self.message = "Dodano \(request.projects.count) projektów"
            }
        }
    }
    @discardableResult
    func adoptGroupIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], selection: AttachmentSelection, treatingExistingAsKnown: Bool) async -> Bool {
        await performing { _ = try await self.service?.adoptProjectsIntoRoot(root, following: following, keepingOwnSettings: keepingOwnSettings, selection: selection, treatingExistingAsKnown: treatingExistingAsKnown); self.message = "Utworzono folder \(root.name); wspólnych ustawień używa \(following.count) projektów" }
    }

    @discardableResult
    func saveRoot(_ root: ProjectRoot, selection: AttachmentSelection) async -> Bool { await performing { try await self.service?.updateProjectRoot(root, selection: selection); self.message = "Zapisano ustawienia folderu \(root.name)" } }
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
    func addLocal(_ url: URL) async { await perform { _ = try await self.service?.addLocal(path: url.path); self.message = "Dodano skill z dysku" } }
    @discardableResult
    func createSkill(_ draft: NewSkillDraft) async -> Bool {
        await performing {
            let skill = try await self.service?.createSkill(id: draft.id, name: draft.name, description: draft.description, content: draft.content, tags: draft.tags)
            if let skill { self.selection = skill.id }
            self.message = "Utworzono skill \(draft.id)"
        }
    }
    @discardableResult
    func addGit(_ url: String, subpath: String) async -> Bool { await performing {
        let urls = url.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var count = 0; var skipped: [SkippedSkill] = []
        for item in urls { if let result = try await self.service?.addGitCollection(url: item, subpath: subpath.isEmpty ? nil : subpath) { count += result.imported.count; skipped += result.skipped } }
        self.message = skipped.isEmpty ? "Zaimportowano \(count) skilli" : "Zaimportowano \(count) skilli, pominięto \(skipped.count): " + skipped.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ")
    } }
    func checkUpdates() async { await prepareUpdateReview() }
    func update(_ id: String) async { await prepareUpdateReview(ids: [id]) }
    func updateAllAvailable() async { await prepareUpdateReview(ids: updateAvailable.sorted()) }

    func prepareUpdateReview(ids: [String]? = nil, synchronizing: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let plan = try await service.previewSkillUpdates(ids: ids)
            if ids == nil { updateAvailable = Set(plan.updates.map(\.id)) }
            else { updateAvailable.subtract(plan.unchanged); updateAvailable.formUnion(plan.updates.map(\.id)) }
            hasCheckedUpdates = true
            reviewIncludesSync = synchronizing
            updateReview = plan
            if !plan.failed.isEmpty {
                message = "Nie udało się sprawdzić: " + plan.failed.map { "\($0.id): \($0.reason)" }.joined(separator: "; ")
                record(.error, message)
            }
        } catch { reportError(error) }
    }

    func acceptSkillUpdates(_ plan: SkillUpdatePlan, selected: Set<String>, synchronizing: Bool) async -> Bool {
        isWorking = true
        defer { isWorking = false; progress = nil }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            guard selected.isSubset(of: Set(plan.updates.map(\.id))) else { throw SkillboxError.invalidSkill("wybór nie należy do podglądu") }
            let accepted = plan.updates.filter { selected.contains($0.id) }
            let updated = try await service.applySkillUpdates(accepted, applicationVersion: AppVersion.short)
            updateAvailable.subtract(updated.map(\.id))
            updateAvailable.subtract(plan.unchanged)
            let postponed = plan.updates.count - updated.count
            let summary = "Zaktualizowano \(updated.count) skilli" + (postponed > 0 ? ", odłożono \(postponed)" : "")
            if synchronizing {
                // Its own entry only here, before a step that can still fail: a failed
                // synchronization must not hide that the library has already changed.
                record(.success, summary)
                if accepted.isEmpty { _ = try await service.createFullBackup(applicationVersion: AppVersion.short) }
                let outcomes = try await service.syncAllProjectsTransactions(progress: progressHandler)
                for outcome in outcomes {
                    if case .failed(let reason) = outcome.state { throw SkillboxError.commandFailed("\(outcome.plan.project.name): \(reason)") }
                }
                message = summary + " i zsynchronizowano projekty"
            } else { message = summary + ". Projekty można teraz zsynchronizować." }
            record(.success, message)
            await reload(); await loadFullBackups()
            updateReview = nil
            return true
        } catch {
            await reload(); await loadFullBackups()
            reportError(error)
            return false
        }
    }
    func saveSkillMarkdown(_ id: String, content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            try await service?.saveSkillMarkdown(skillID: id, content: content)
            message = "Zapisano \(id)"; record(.success, message)
            await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveTags(_ id: String, text: String) async { await perform { try await self.service?.setTags(skillID: id, tags: Self.csv(text)); self.message = "Zapisano tagi" } }
    @discardableResult
    func addTags(_ ids: Set<String>, text: String) async -> Bool { await performing { try await self.service?.addTags(skillIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) skilli" } }
    func deleteSkill(_ id: String) async { await perform { try await self.service?.deleteSkill(skillID: id); if self.selection == id { self.selection = nil; self.markdown = "" }; self.updateAvailable.remove(id); self.message = "Usunięto skill \(id)" } }
    func deleteSkills(_ ids: Set<String>) async {
        await perform {
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
    func addLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async -> Bool { await performing { try await self.service?.addLibraryClaudePlugin(plugin); self.message = "Dodano plugin Claude do biblioteki" } }
    func updateLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async -> Bool { await performing { try await self.service?.updateLibraryClaudePlugin(plugin); self.message = "Zapisano plugin \(plugin.name)" } }
    func deleteLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async { await perform { try await self.service?.deleteLibraryClaudePlugin(id: plugin.id); self.message = "Usunięto plugin \(plugin.name) z biblioteki" } }
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
            let deselected = try await self.service?.uninstallClaudePlugin(projectPath: project.path, plugin: plugin) ?? false
            self.message = deselected
                ? "Usunięto plugin \(plugin.id) i wybór z biblioteki, więc synchronizacja go nie przywróci"
                : "Usunięto plugin \(plugin.id)"
        }
    }
    @discardableResult
    func addProject(_ project: Project, selection: AttachmentSelection) async -> Bool { await performing { _ = try await self.service?.addProject(project, selection: selection); self.message = "Dodano projekt" } }
    @discardableResult
    func updateProject(_ project: Project, selection: AttachmentSelection) async -> Bool { await performing { try await self.service?.updateProject(project, selection: selection); self.message = "Zapisano projekt" } }
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
        isCheckingStatuses = true; defer { isCheckingStatuses = false; progress = nil }
        guard let service else { return }
        do { statuses = Dictionary(uniqueKeysWithValues: try await service.projectStatuses(progress: progressHandler).map { ($0.projectID, $0) }) }
        catch { reportError(error) }
    }
    func unsyncProject(_ project: Project) async {
        await perform { let removed = try await self.service?.unsyncProject(id: project.id) ?? []; self.message = "Usunięto \(removed.count) elementów z \(project.name)" }
    }
    func adoptableSkills(_ project: Project) async throws -> [AdoptableSkill] {
        guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
        return try await service.adoptableSkills(projectID: project.id)
    }
    /// Skills this project changed since its last synchronization — the ones it has to offer back.
    func driftedSkills(_ project: Project) async throws -> [DriftedSkill] {
        guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
        return try await service.driftedSkills(projectID: project.id)
    }

    /// Both halves of "przejmij z projektu" as one action, so the sheet reports one result and the
    /// library takes one recovery snapshot for what the user thinks of as a single decision.
    func adoptFromProject(newSkills: [AdoptableSkill], changes: [DriftedSkill]) async {
        await perform {
            var parts: [String] = []
            if !newSkills.isEmpty {
                let adopted = try await self.service?.adoptSkills(newSkills) ?? []
                parts.append("przejęto \(adopted.count) nowych skilli")
            }
            if !changes.isEmpty {
                let updated = try await self.service?.adoptSkillChanges(changes) ?? []
                parts.append("zaktualizowano z projektu \(updated.count)")
            }
            self.message = parts.isEmpty ? "Nic nie wybrano" : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        }
    }

    func adoptSkills(_ items: [AdoptableSkill]) async {
        await perform { let adopted = try await self.service?.adoptSkills(items) ?? []; self.message = "Przejęto \(adopted.count) skilli do biblioteki" }
    }
    /// Where a library item actually lands. Read on demand — a confirmation dialog asking "usunąć?"
    /// without saying what it will reach is a question asked in the dark.
    func usage(ofSkill id: String) async -> UsageReport { (try? await service?.usage(ofSkill: id)) ?? UsageReport() }
    func usage(ofServer id: UUID) async -> UsageReport { (try? await service?.usage(ofServer: id)) ?? UsageReport() }
    func usage(ofDoc id: String) async -> UsageReport { (try? await service?.usage(ofDoc: id)) ?? UsageReport() }
    func usage(ofPlugin id: UUID) async -> UsageReport { (try? await service?.usage(ofPlugin: id)) ?? UsageReport() }

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
            message = "Zapisano serwer MCP"; record(.success, message); await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func duplicateMCPServer(_ server: MCPServer, name: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await service?.duplicateMCPServer(id: server.id, name: name)
            message = "Utworzono kopię serwera MCP"; record(.success, message); await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func deleteMCPServer(_ id: UUID) async { await perform { try await self.service?.deleteMCPServer(id: id); self.message = "Usunięto serwer MCP" } }
    @discardableResult
    func addMCPServerTags(_ ids: Set<UUID>, text: String) async -> Bool { await performing { try await self.service?.addMCPServerTags(serverIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) serwerów MCP" } }
    func exportMCPServerJSON(_ id: UUID) async -> String { (try? await service?.exportMCPServerJSON(id)) ?? "" }
    func exportMCPConfigurationJSON() async -> String { (try? await service?.exportMCPConfigurationJSON(mcp.servers)) ?? "" }
    func updateMCPServerJSON(_ id: UUID, name: String, json: String, enabled: Bool, tags: [String]) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await service?.updateMCPServerJSON(id, name: name, json: json, enabled: enabled, tags: tags)
            message = "Zapisano serwer MCP"; record(.success, message); await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func createDoc(id: String, name: String, tags: [String], content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            let doc = try await service?.createDoc(id: id, name: name, tags: tags, content: content)
            if let doc { selection = nil; message = "Utworzono dokument \(doc.id)" } else { message = "Utworzono dokument" }
            record(.success, message); await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveDocContent(_ id: String, name: String, content: String) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            try await service?.saveDocContent(docID: id, name: name, content: content)
            message = "Zapisano \(id)"; record(.success, message); await reload(); return true
        } catch { message = error.localizedDescription; record(.error, message); return false }
    }
    func saveDocTags(_ id: String, text: String) async { await perform { try await self.service?.setDocTags(docID: id, tags: Self.csv(text)); self.message = "Zapisano tagi" } }
    @discardableResult
    func addDocTags(_ ids: Set<String>, text: String) async -> Bool { await performing { try await self.service?.addDocTags(docIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) dokumentów" } }
    func deleteDoc(_ id: String) async { await perform { try await self.service?.deleteDoc(id: id); self.message = "Usunięto dokument \(id)" } }
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
    @discardableResult
    func syncEverything(_ project: Project) async -> Bool { await performing { _ = try await self.service?.syncProjectTransaction(projectID: project.id); self.message = "Zsynchronizowano skille, MCP, dokumenty i pluginy dla \(project.name)" } }
    func previewAllProjectsSync() async throws -> [ProjectSyncPlan] { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewAllProjectsSync() }
    func syncAllProjects() async -> [ProjectSyncOutcome] {
        isWorking = true
        defer { isWorking = false; progress = nil }
        do {
            guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
            let outcomes = try await service.syncAllProjectsTransactions(progress: progressHandler)
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
    /// Review exact updates before running the full workflow.
    func refresh() async { await prepareUpdateReview(synchronizing: true) }
    func projectConfiguration(_ project: Project) async throws -> ProjectConfigurationReport {
        guard let service else { throw SkillboxError.commandFailed("Brak usługi") }
        return try await service.projectConfiguration(projectID: project.id)
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
    /// `classifications` is what the import sheet shows the user; the store keeps a `${VAR}`
    /// reference as a reference and everything else as a local value, which is the same decision,
    /// so it is not passed on rather than being accepted and ignored.
    func importMCP(_ text: String, serverNames: Set<String>, classifications _: [String: MCPValueClassification], singleServerName: String? = nil) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text, serverNames: serverNames, singleServerName: singleServerName); await reload(); message = "Zaimportowano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
    /// Applies every server the JSON describes — no selection step, because this text is a re-edit
    /// of the library's own configuration rather than something pasted in from elsewhere.
    func importMCPJSONAll(_ text: String) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text); await reload(); message = "Zapisano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
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
            // The watch belongs to a folder, so switching libraries moves it.
            startWatchingLibrary()
            await reload()
            message = existing ? "Podłączono istniejącą bibliotekę" : "Biblioteka skopiowana do nowego folderu"
        }
        catch { message = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) async { isWorking = true; defer { isWorking = false }; do { try await action(); await reload(); if !message.isEmpty { record(.success, message) } } catch { await reload(); message = error.localizedDescription; record(.error, message) } }
    /// `perform` for an action a sheet stays open for. The result says whether it succeeded, so a
    /// form can show the reason next to the field that caused it instead of dismissing and leaving
    /// the message to the status bar.
    @discardableResult
    private func performing(_ action: @escaping @MainActor () async throws -> Void) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do { try await action(); await reload(); if !message.isEmpty { record(.success, message) }; return true }
        catch { await reload(); message = error.localizedDescription; record(.error, message); return false }
    }
    private func record(_ kind: OperationLogEntry.Kind, _ text: String) { operationLog.insert(OperationLogEntry(kind: kind, text: text), at: 0); if operationLog.count > 100 { operationLog.removeLast(operationLog.count - 100) } }
    func reportError(_ error: Error) { message = error.localizedDescription; record(.error, message) }
    static func csv(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
