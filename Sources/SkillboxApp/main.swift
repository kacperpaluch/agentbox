import SwiftUI
import AppKit
import Combine
import Sparkle
import SkillboxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); DispatchQueue.main.async { NSApp.windows.first?.makeKeyAndOrderFront(nil) } }
}

@MainActor final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "cacheBust" }
        items.append(URLQueryItem(name: "cacheBust", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url?.absoluteString
    }
}

enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var display: String {
        let version = short
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Wersja \(version) (\(build))"
    }
}

@main struct AgentboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateFeedDelegate: UpdateFeedDelegate
    private let updaterController: SPUStandardUpdaterController
    init() { let delegate = UpdateFeedDelegate(); updateFeedDelegate = delegate; updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) }
    var body: some Scene {
        WindowGroup { ContentView(updater: updaterController.updater) }.defaultSize(width: 1100, height: 720)
            .commands { CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: updaterController.updater) } }
    }
}

enum SectionKind: String, CaseIterable, Identifiable {
    case library = "Biblioteka", projects = "Projekty", global = "Globalne", mcp = "MCP", backup = "Backup", recovery = "Odzyskiwanie", settings = "Ustawienia"
    var id: String { rawValue }
    var icon: String { switch self { case .library: "square.grid.2x2"; case .projects: "folder"; case .global: "person.crop.circle"; case .mcp: "network"; case .backup: "externaldrive.badge.timemachine"; case .recovery: "clock.arrow.circlepath"; case .settings: "gearshape" } }
}

struct OperationLogEntry: Identifiable {
    enum Kind { case success, error }
    let id = UUID(); let date = Date(); let kind: Kind; let text: String
}

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
    @Published var hasOpenAIKey = false
    @Published var hasAnthropicKey = false
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
    var service: SkillboxService?
    init() {
        let saved = UserDefaults.standard.string(forKey: "SkillboxLibraryRoot")
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Skillbox").path
        let shared = AgentboxRootPreference.load()?.path
        rootPath = saved ?? shared ?? defaultPath
        do { service = try SkillboxService(root: URL(fileURLWithPath: rootPath)) }
        catch { serviceError = "Nie można otworzyć biblioteki w \(rootPath): \(error.localizedDescription)" }
        Task { await reload() }
    }
    // Statuses depend on the exact things reload() refreshes (skills, tags, MCP servers and their
    // tags), so it recomputes them here too. That is the only place callers need to remember to
    // call — a skill tag edit or a new tagged MCP server no longer leaves the Projects tab showing
    // a stale "synced" badge until someone happens to touch a project directly.
    func reload() async { do { skills = try await service?.listSkills() ?? []; projects = try await service?.listProjects() ?? []; storedProjects = try await service?.storedProjects() ?? []; projectRoots = try await service?.projectRoots() ?? []; mcp = try await service?.mcpConfiguration() ?? MCPConfiguration(); if let service { hasOpenAIKey = try await service.hasMCPAIKey(.openAI); hasAnthropicKey = try await service.hasMCPAIKey(.claude) }; if selection == nil { selection = skills.first?.id }; await loadMarkdown() } catch { message = error.localizedDescription }; await scanRoots(); await loadStatuses() }

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
        guard !projectRoots.isEmpty, Date.now.timeIntervalSince(lastActivationScan) > 5 else { return }
        lastActivationScan = .now
        await scanRoots()
    }
    func root(for project: Project) -> ProjectRoot? { project.rootID.flatMap { id in projectRoots.first { $0.id == id } } }
    func inheritsRoot(_ project: Project) -> Bool { project.overridesRoot != true && root(for: project) != nil }
    func storedProject(id: UUID) -> Project? { storedProjects.first { $0.id == id } }
    func addBatch(_ request: BatchProjectRequest) async {
        await perform {
            if let root = request.root {
                _ = try await self.service?.addProjectRoot(root, folders: request.folders, serverIDs: request.serverIDs, serverTags: request.serverTags, treatingExistingAsKnown: request.treatingExistingAsKnown)
                self.message = "Dodano folder \(root.name) i \(request.folders.count) projektów"
            } else {
                for project in request.projects { _ = try await self.service?.addProject(project, serverIDs: request.serverIDs, serverTags: request.serverTags) }
                self.message = "Dodano \(request.projects.count) projektów"
            }
        }
    }
    func adoptGroupIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], serverIDs: [UUID], serverTags: [String], treatingExistingAsKnown: Bool) {
        Task { await perform { _ = try await self.service?.adoptProjectsIntoRoot(root, following: following, keepingOwnSettings: keepingOwnSettings, serverIDs: serverIDs, serverTags: serverTags, treatingExistingAsKnown: treatingExistingAsKnown); self.message = "Utworzono folder \(root.name); wspólnych ustawień używa \(following.count) projektów" } }
    }
    func saveRoot(_ root: ProjectRoot, serverIDs: [UUID], serverTags: [String]) async { await perform { try await self.service?.updateProjectRoot(root, serverIDs: serverIDs, serverTags: serverTags); self.message = "Zapisano ustawienia folderu \(root.name)" } }
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
    func addProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async { await perform { _ = try await self.service?.addProject(project, serverIDs: serverIDs, serverTags: serverTags); self.message = "Dodano projekt" } }
    func updateProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async { await perform { try await self.service?.updateProject(project, serverIDs: serverIDs, serverTags: serverTags); self.message = "Zapisano projekt" } }
    func selectedMCPServerIDs(for project: Project) -> [UUID] { selectedMCPServerIDs(selectionID: (inheritsRoot(project) ? project.rootID : nil) ?? project.id) }
    func selectedMCPServerIDs(selectionID: UUID) -> [UUID] { let key = selectionID.uuidString; let direct = mcp.projectServerIDs?[key] ?? []; let legacyPresetIDs = Set(mcp.projectPresetIDs[key] ?? []); let legacy = mcp.presets.filter { legacyPresetIDs.contains($0.id) }.flatMap(\.serverIDs); return Array(Set(direct + legacy)) }
    func selectedMCPServerTags(for project: Project) -> [String] { mcp.projectServerTags?[((inheritsRoot(project) ? project.rootID : nil) ?? project.id).uuidString] ?? [] }
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
    func exportMCPServerJSON(_ id: UUID) async -> String { (try? await service?.exportMCPServerJSON(id)) ?? "" }
    func exportMCPConfigurationJSON() async -> String { (try? await service?.exportMCPConfigurationJSON(mcp.servers)) ?? "" }
    func updateMCPServerJSON(_ id: UUID, name: String, json: String, enabled: Bool, tags: [String]) async -> Bool {
        isWorking = true; defer { isWorking = false }
        do {
            _ = try await service?.updateMCPServerJSON(id, name: name, json: json, enabled: enabled, tags: tags)
            message = "Zapisano serwer MCP"; record(.success, message); await reload(); scheduleAutomaticBackup(); return true
        } catch { message = error.localizedDescription; record(.error, message); await reload(); return false }
    }
    func previewMCP(_ project: Project) async throws -> [MCPPreview] { try await service?.previewMCP(projectID: project.id) ?? [] }
    func previewProjectSync(_ project: Project) async throws -> ProjectSyncPreview { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewProjectSync(projectID: project.id) }
    func syncEverything(_ project: Project) async { await perform { _ = try await self.service?.syncProjectTransaction(projectID: project.id); self.message = "Zsynchronizowano skille i MCP dla \(project.name)" } }
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
    func generateMCP(_ instructions: String, settings: MCPAISettings, key: String?) async throws -> String { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; try await service.saveMCPAISettings(settings, apiKey: key); return try await service.generateMCPConfiguration(instructions: instructions, settings: settings) }
    func saveAIProvider(_ provider: MCPAIProvider, model: String, key: String?) async { await perform { try await self.service?.saveMCPAIProvider(provider, model: model, apiKey: key); self.message = "Zapisano ustawienia \(provider == .openAI ? "OpenAI" : "Anthropic")" } }
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

struct ContentView: View {
    @StateObject private var model: AppModel
    let updater: SPUUpdater
    @State private var section: SectionKind? = .library
    @State private var showGit = false
    @State private var showProject = false
    @State private var showHistory = false
    init(updater: SPUUpdater) { self.updater = updater; _model = StateObject(wrappedValue: AppModel()) }
    var body: some View {
        NavigationSplitView { VStack(spacing: 0) { List(SectionKind.allCases, selection: $section) { item in
            // The detected-folders banner lives in the Projects tab, so without this the question
            // would wait unseen for whoever happens to open that tab.
            HStack {
                Label(item.rawValue, systemImage: item.icon)
                Spacer()
                if item == .projects, !model.detectedFolders.isEmpty {
                    Text(model.detectedFolders.count, format: .number)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .tag(item)
        }.navigationTitle("Agentbox"); Divider(); Text(AppVersion.display).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.navigationSplitViewColumnWidth(min: 180, ideal: 210) } detail: {
            Group {
                if let serviceError = model.serviceError, section != .settings {
                    ContentUnavailableView {
                        Label("Biblioteka niedostępna", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("\(serviceError)\nDane nie zostały zmienione. Podłącz dysk z biblioteką albo wskaż jej folder w Ustawieniach.")
                    } actions: {
                        Button("Otwórz Ustawienia") { section = .settings }.buttonStyle(.borderedProminent)
                    }
                } else {
                    switch section ?? .library { case .library: LibraryView(model: model, showGit: $showGit); case .projects: ProjectsView(model: model, showProject: $showProject); case .global: GlobalSyncView(model: model); case .mcp: MCPView(model: model); case .backup: BackupView(model: model); case .recovery: RecoveryView(model: model); case .settings: SettingsView(model: model, updater: updater) }
                }
            }
        }
        .overlay(alignment: .bottom) { if !model.message.isEmpty { StatusToast(text: model.message) { model.message = "" } } }
        .task(id: model.message) { let current = model.message; guard !current.isEmpty else { return }; try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, model.message == current else { return }; withAnimation { model.message = "" } }
        .overlay { if model.isWorking { ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .sheet(isPresented: $showGit) { AddGitView { url, path in Task { await model.addGit(url, subpath: path) } } }
        .sheet(isPresented: $showProject) { ProjectEditor(skills: model.skills, servers: model.mcp.servers, project: nil, selectedServerIDs: [], selectedServerTags: []) { project, servers, tags in Task { await model.addProject(project, serverIDs: servers, serverTags: tags) } } }
        .sheet(isPresented: $showHistory) { OperationHistoryView(entries: model.operationLog) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.scanRootsOnActivation() } }
        .toolbar { Button { showHistory = true } label: { Label("Historia operacji", systemImage: "clock.arrow.circlepath") } }
    }
}

struct OperationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [OperationLogEntry]
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .short; value.timeStyle = .medium; return value }()
    var body: some View { VStack(alignment: .leading, spacing: 14) { HStack { Text("Historia operacji").font(.title2.bold()); Spacer(); Button("Zamknij") { dismiss() } }; if entries.isEmpty { ContentUnavailableView("Brak operacji", systemImage: "clock", description: Text("Sukcesy i błędy z tej sesji pojawią się tutaj.")) } else { List(entries) { entry in HStack(alignment: .top) { Image(systemName: entry.kind == .error ? "xmark.octagon.fill" : entry.kind == .success ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(entry.kind == .error ? .red : entry.kind == .success ? .green : .blue); VStack(alignment: .leading) { Text(entry.text).textSelection(.enabled); Text(formatter.string(from: entry.date)).font(.caption).foregroundStyle(.secondary) } } } } }.padding(20).frame(width: 680, height: 520) }
}

enum SkillSort: String, CaseIterable, Identifiable { case name = "Nazwa", newest = "Najnowsze", source = "Źródło"; var id: String { rawValue } }
enum SkillGrouping: String, CaseIterable, Identifiable { case repository = "Repozytorium", tag = "Tag", source = "Źródło", none = "Bez grupowania"; var id: String { rawValue } }

struct LibraryView: View {
    @ObservedObject var model: AppModel; @Binding var showGit: Bool
    @State private var showNewSkill = false
    @State private var search = ""
    @State private var selectedTag = ""
    @State private var sort: SkillSort = .name
    @State private var grouping: SkillGrouping = .repository
    @State private var checked = Set<String>()
    @State private var expanded = Set<String>()
    @State private var showBatchTags = false
    var tags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    var filtered: [Skill] {
        var result = model.skills.filter { (selectedTag.isEmpty || $0.tags.contains(selectedTag)) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }) }
        switch sort { case .name: result.sort { $0.name < $1.name }; case .newest: result.sort { $0.updatedAt > $1.updatedAt }; case .source: result.sort { $0.source.kind.rawValue < $1.source.kind.rawValue } }
        return result
    }
    var groups: [(name: String, skills: [Skill])] {
        switch grouping {
        case .none: return [("Wszystkie skille", filtered)]
        case .source:
            return Dictionary(grouping: filtered) { $0.source.kind == .git ? "Git" : "Lokalne" }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        case .repository:
            return Dictionary(grouping: filtered) { skill in
                guard skill.source.kind == .git else { return "Lokalne" }
                let trimmed = skill.source.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let component = trimmed.split(separator: "/").last.map(String.init) ?? skill.source.location
                return component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            }.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        case .tag:
            var values: [String: [Skill]] = [:]
            for skill in filtered { if skill.tags.isEmpty { values["Bez tagów", default: []].append(skill) } else { for tag in skill.tags { values["#\(tag)", default: []].append(skill) } } }
            return values.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        }
    }
    var body: some View { HSplitView {
        VStack(spacing: 0) {
            ActionBar {
                Button { showGit = true } label: { Label("Z Git", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent)
                Button { chooseSkill() } label: { Label("Z dysku", systemImage: "folder.badge.plus") }.buttonStyle(.bordered)
                Button { showNewSkill = true } label: { Label("Napisz własny", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                if !checked.isEmpty {
                    Button { showBatchTags = true } label: { Label("Dodaj tagi (\(checked.count))", systemImage: "tag") }.buttonStyle(.bordered)
                    Button("Wyczyść") { checked.removeAll() }.buttonStyle(.bordered)
                }
                Spacer()
                Text("\(filtered.count) z \(model.skills.count)").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Picker("Tag", selection: $selectedTag) { Text("Wszystkie tagi").tag(""); ForEach(tags, id: \.self) { Text("#\($0)").tag($0) } }.labelsHidden().frame(maxWidth: 165); Picker("Grupowanie", selection: $grouping) { ForEach(SkillGrouping.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: 145); Picker("Sortowanie", selection: $sort) { ForEach(SkillSort.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: 115); Menu { Button("Rozwiń wszystko") { expanded = Set(groups.map(\.name)) }; Button("Zwiń wszystko") { expanded.removeAll() } } label: { Image(systemName: "rectangle.expand.vertical") }; Button { Task { await model.checkUpdates() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sprawdź aktualizacje"); Spacer(); if !checked.isEmpty { Text("Wybrano: \(checked.count)").font(.caption).foregroundStyle(.secondary) } }.padding(10).background(.bar)
            List { ForEach(groups, id: \.name) { group in DisclosureGroup(isExpanded: groupExpansion(group.name)) { ForEach(group.skills) { skill in HStack(alignment: .top, spacing: 9) { Toggle("", isOn: checkBinding(skill.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5); SkillRow(skill: skill, updateAvailable: model.updateAvailable.contains(skill.id)) }.contentShape(Rectangle()).onTapGesture { model.selection = skill.id; Task { await model.loadMarkdown() } }.listRowBackground(model.selection == skill.id ? Color.accentColor.opacity(0.13) : Color.clear) } } label: { HStack { Toggle("", isOn: groupCheckBinding(group.skills)).labelsHidden().toggleStyle(.checkbox); Image(systemName: grouping == .repository ? "shippingbox" : grouping == .tag ? "tag" : grouping == .source ? "tray.full" : "square.grid.2x2").foregroundStyle(.tint); Text(group.name).fontWeight(.semibold); Text("\(group.skills.count)").font(.caption).foregroundStyle(.secondary); Spacer(); let updates = group.skills.filter { model.updateAvailable.contains($0.id) }.count; if updates > 0 { Label("\(updates)", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.orange) } } } } }.searchable(text: $search, prompt: "Nazwa lub tag")

        }.frame(minWidth: 410, idealWidth: 480)
        if let id = model.selection, let skill = model.skills.first(where: { $0.id == id }) { SkillDetail(model: model, skill: skill) } else { ContentUnavailableView("Wybierz skill", systemImage: "text.book.closed") }
    }.navigationTitle("Biblioteka")
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: tags) { text in Task { await model.addTags(checked, text: text); checked.removeAll() } } }
        .sheet(isPresented: $showNewSkill) { NewSkillView(existingTags: tags, existingIDs: Set(model.skills.map(\.id))) { draft in Task { await model.createSkill(draft) } } } }
    private func checkBinding(_ id: String) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
    private func groupCheckBinding(_ skills: [Skill]) -> Binding<Bool> { let ids = Set(skills.map(\.id)); return Binding(get: { !ids.isEmpty && ids.isSubset(of: checked) }, set: { if $0 { checked.formUnion(ids) } else { checked.subtract(ids) } }) }
    private func groupExpansion(_ name: String) -> Binding<Bool> { Binding(get: { !search.isEmpty || expanded.contains(name) || grouping == .none }, set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } }) }
    private func chooseSkill() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { Task { await model.addLocal(url) } } }
}

/// Shared section header. Every list section puts its actions here, at the top, in the same order:
/// the primary action first and prominent, secondary actions bordered beside it.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
        }
    }
}

struct SkillRow: View { let skill: Skill; let updateAvailable: Bool; var body: some View { VStack(alignment: .leading, spacing: 7) { HStack { Image(systemName: skill.source.kind == .git ? "network" : "internaldrive").foregroundStyle(.tint); Text(skill.name).fontWeight(.medium); Spacer(); if updateAvailable { Label("Aktualizacja", systemImage: "arrow.down.circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(.orange) } }; if skill.tags.isEmpty { Text("bez tagów").font(.caption).foregroundStyle(.tertiary) } else { FlowTags(tags: skill.tags) } }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading) } }

struct FlowTags: View { let tags: [String]; var body: some View { HStack(spacing: 5) { ForEach(tags.prefix(4), id: \.self) { TagPill(tag: $0) }; if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption2).foregroundStyle(.secondary) } } } }
struct TagPill: View { let tag: String; private var color: Color { let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo]; let value = tag.unicodeScalars.reduce(0) { $0 + Int($1.value) }; return colors[value % colors.count] }; var body: some View { Text("#\(tag)").font(.caption2.weight(.medium)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule()) } }

struct SkillDetail: View {
    @ObservedObject var model: AppModel; let skill: Skill; @State private var tags = ""; @State private var confirmDelete = false
    @State private var isEditing = false
    @State private var draft = ""
    private var isEditable: Bool { skill.source.kind == .local }
    var body: some View { VStack(alignment: .leading, spacing: 0) { VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text(skill.name).font(.title2.bold()); Text(skill.source.location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if model.updateAvailable.contains(skill.id) { Button("Aktualizuj") { Task { await model.update(skill.id) } }.buttonStyle(.borderedProminent).tint(.orange) } else if model.hasCheckedUpdates && skill.source.kind == .git { Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }; Button("Usuń", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered) }; HStack { TextField("tagi, oddzielone przecinkami", text: $tags).textFieldStyle(.roundedBorder); ExistingTagMenu(tags: Array(Set(model.skills.flatMap(\.tags))).sorted(), text: $tags); Button("Zapisz tagi") { Task { await model.saveTags(skill.id, text: tags) } }.buttonStyle(.bordered) }.padding(.top, 2) }.padding(); Divider(); editorBar; Divider(); content }.onAppear { tags = skill.tags.joined(separator: ", ") }.onChange(of: skill.id) { tags = skill.tags.joined(separator: ", "); isEditing = false; draft = "" }.confirmationDialog("Usunąć skill \(skill.name)?", isPresented: $confirmDelete) { Button("Usuń skill", role: .destructive) { Task { await model.deleteSkill(skill.id) } }; Button("Anuluj", role: .cancel) {} } message: { Text("Skill zostanie usunięty z biblioteki i przypisań projektów. Zniknie z folderów projektów przy kolejnej synchronizacji.") } }

    @ViewBuilder private var editorBar: some View {
        HStack(spacing: 8) {
            if isEditing {
                Button("Zapisz zmiany") { Task { if await model.saveSkillMarkdown(skill.id, content: draft) { isEditing = false } } }
                    .buttonStyle(.borderedProminent).disabled(model.isWorking)
                Button("Anuluj") { isEditing = false; draft = model.markdown }.buttonStyle(.bordered)
                Spacer()
                Text("Zapis oznacza projekty z tym skillem jako nieaktualne.").font(.caption).foregroundStyle(.secondary)
            } else if isEditable {
                Button { draft = model.markdown; isEditing = true } label: { Label("Edytuj SKILL.md", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                Spacer()
            } else {
                Label("Skill z Git — edycja w aplikacji jest wyłączona, bo aktualizacja zastąpiłaby zmiany.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if isEditing {
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).padding(6)
        } else {
            ScrollView { Text(model.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
        }
    }
}

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Binding var showProject: Bool
    @State private var showBatch = false
    @State private var showAllSync = false
    @State private var editing: Project?
    @State private var previewProject: Project?
    @State private var deleting: Project?
    @State private var adopting: Project?
    @State private var deleteFiles = false
    @State private var collapsedGroups = Set<String>()
    @State private var editingRoot: ProjectRoot?
    @State private var deletingRoot: ProjectRoot?
    @State private var settingUpRoot: ProjectGroup?
    @State private var showDetected = false

    private struct ProjectGroup: Identifiable {
        let path: String
        let root: ProjectRoot?
        let projects: [Project]
        var id: String { root?.id.uuidString ?? path }
        var name: String { root?.name ?? URL(fileURLWithPath: path).lastPathComponent }
    }

    /// Projects of a parent folder stay together even when one of them was moved elsewhere on disk,
    /// so the group header always describes the settings its rows actually use. Projects added on
    /// their own keep the old grouping by the folder they sit in.
    private var groups: [ProjectGroup] {
        var byRoot: [UUID: [Project]] = [:]
        var byPath: [String: [Project]] = [:]
        for project in model.projects {
            if let root = model.root(for: project) { byRoot[root.id, default: []].append(project) }
            else { byPath[URL(fileURLWithPath: project.path).deletingLastPathComponent().standardizedFileURL.path, default: []].append(project) }
        }
        let sorted: ([Project]) -> [Project] = { $0.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        // A folder with no projects left still appears, otherwise its shared settings would become
        // unreachable the moment its last project is removed.
        let rootGroups = model.projectRoots.map { ProjectGroup(path: $0.path, root: $0, projects: sorted(byRoot[$0.id] ?? [])) }
        let pathGroups = byPath.map { ProjectGroup(path: $0.key, root: nil, projects: sorted($0.value)) }
        return (rootGroups + pathGroups).sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if !model.detectedFolders.isEmpty { detectedBanner }
            if model.projects.isEmpty && model.projectRoots.isEmpty {
                ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode."))
            } else {
                projectList
            }
        }
        .navigationTitle("Projekty")
        .sheet(isPresented: $showBatch) { BatchProjectView(skills: model.skills, servers: model.mcp.servers, existingProjects: model.projects, existingRoots: model.projectRoots) { request in Task { await model.addBatch(request) } } }
        .sheet(isPresented: $showDetected) { DetectedFoldersView(model: model) }
        .sheet(item: $settingUpRoot) { group in GroupRootSetupView(model: model, folderPath: group.path, projects: group.projects) }
        .sheet(item: $editingRoot) { root in ProjectRootEditor(skills: model.skills, servers: model.mcp.servers, root: root, followingProjects: model.storedProjects.filter { $0.rootID == root.id && $0.overridesRoot != true }.count, selectedServerIDs: model.selectedMCPServerIDs(selectionID: root.id), selectedServerTags: model.mcp.projectServerTags?[root.id.uuidString] ?? []) { updated, servers, tags in Task { await model.saveRoot(updated, serverIDs: servers, serverTags: tags) } } }
        .sheet(item: $editing) { project in ProjectEditor(skills: model.skills, servers: model.mcp.servers, project: model.storedProject(id: project.id) ?? project, root: model.root(for: project), inheritedFrom: model.inheritsRoot(project) ? model.projects.first { $0.id == project.id } : nil, selectedServerIDs: model.selectedMCPServerIDs(for: project), selectedServerTags: model.selectedMCPServerTags(for: project)) { updated, servers, tags in Task { await model.updateProject(updated, serverIDs: servers, serverTags: tags) } } }
        .sheet(item: $previewProject) { project in MCPPreviewView(model: model, project: project) }
        .sheet(isPresented: $showAllSync) { AllProjectsSyncPreviewView(model: model) }
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Usuń tylko z Agentbox", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: false) } }; deleting = nil }
            Button("Usuń i posprzątaj pliki w projekcie", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: true) } }; deleting = nil }
            Button("Anuluj", role: .cancel) { deleting = nil }
        } message: { Text("Sprzątanie usuwa z folderu projektu wyłącznie katalogi skilli i wpisy MCP wymienione w manifestach Agentbox. Przed zmianą powstaje backup, który można cofnąć w sekcji Odzyskiwanie.") }
        .sheet(item: $adopting) { project in AdoptSkillsView(model: model, project: project) }
        .confirmationDialog("Usunąć wspólne ustawienia folderu \(deletingRoot?.name ?? "")?", isPresented: Binding(get: { deletingRoot != nil }, set: { if !$0 { deletingRoot = nil } })) {
            Button("Usuń ustawienia folderu", role: .destructive) { if let deletingRoot { Task { await model.deleteRoot(deletingRoot) } }; deletingRoot = nil }
            Button("Anuluj", role: .cancel) { deletingRoot = nil }
        } message: { Text("Projekty zostają. Każdy, który korzystał z ustawień folderu, dostaje ich kopię, więc do repozytoriów trafia dokładnie to samo co dziś. Agentbox przestaje tylko pytać o nowe podfoldery.") }
    }

    /// The question the user asked for: a new subfolder in a watched parent folder is offered as a
    /// project instead of being noticed only when something is missing from it.
    private var detectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.detectedFolders.count == 1 ? "Nowy podfolder w obserwowanym folderze" : "Nowe podfoldery w obserwowanych folderach: \(model.detectedFolders.count)").font(.callout.weight(.medium))
                Text(model.detectedFolders.prefix(3).map(\.name).joined(separator: ", ") + (model.detectedFolders.count > 3 ? "…" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Przejrzyj…") { showDetected = true }.buttonStyle(.borderedProminent)
            Button("Dodaj i synchronizuj") { let folders = model.detectedFolders; Task { await model.addDetected(folders, synchronizing: true) } }.buttonStyle(.bordered).disabled(model.isWorking)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    private var projectList: some View {
        List {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: groupExpansion(group.path)) {
                    if group.projects.isEmpty { Text("Folder bez projektów. Dodaj podfoldery przez `Dodaj wiele` albo poczekaj, aż Agentbox je wykryje.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                    ForEach(group.projects) { project in
                        ProjectRow(project: project, status: model.statuses[project.id], inheritsRoot: model.inheritsRoot(project), editing: $editing, previewProject: $previewProject, deleting: $deleting, adopting: $adopting)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: group.root == nil ? "folder" : "folder.badge.gearshape").foregroundStyle(.tint)
                                Text(group.name).font(.subheadline.weight(.semibold))
                                Text("\(group.projects.count)").font(.caption2).foregroundStyle(.secondary)
                                if let root = group.root, root.watchesNewFolders { Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary).help("Agentbox pyta o nowe podfoldery w tym folderze") }
                            }
                            Text(group.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).help(group.path)
                        }
                        Spacer()
                        if let root = group.root {
                            Button { editingRoot = root } label: { Label("Ustawienia folderu", systemImage: "gearshape") }.buttonStyle(.bordered).controlSize(.small)
                            Button { deletingRoot = root } label: { Image(systemName: "trash") }.buttonStyle(.borderless).controlSize(.small).help("Usuń wspólne ustawienia folderu")
                        } else {
                            // Projects added before parent folders existed, or added one by one, have
                            // no folder to inherit from. This is where they get one.
                            Button { settingUpRoot = group } label: { Label("Wspólne ustawienia…", systemImage: "folder.badge.gearshape") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("Ustaw skille i MCP wspólne dla wszystkich projektów w tym folderze")
                        }
                    }
                    .textCase(nil)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var actionBar: some View {
        ActionBar {
            Button { showAllSync = true } label: { Label("Synchronizuj wszystkie", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderedProminent)
                .disabled(model.projects.isEmpty || model.isWorking)
            Button { Task { await model.refreshProjects() } } label: { Label("Sprawdź stan", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .disabled((model.projects.isEmpty && model.projectRoots.isEmpty) || model.isCheckingStatuses)
                .help("Sprawdza, czy projekty odpowiadają bibliotece, i szuka nowych podfolderów w obserwowanych folderach")
            Button { showProject = true } label: { Label("Dodaj projekt", systemImage: "plus") }.buttonStyle(.bordered)
            Button { showBatch = true } label: { Label("Dodaj wiele", systemImage: "folder.badge.plus") }.buttonStyle(.bordered)
            Menu {
                Button("Rozwiń wszystko") { collapsedGroups.removeAll() }
                Button("Zwiń wszystko") { collapsedGroups = Set(groups.map(\.path)) }
            } label: { Image(systemName: "rectangle.expand.vertical") }
            .menuStyle(.borderlessButton).frame(width: 42)
            .help("Rozwiń lub zwiń grupy")
            Spacer()
            if model.isCheckingStatuses { ProgressView().controlSize(.small) }
        }
    }

    private func groupExpansion(_ path: String) -> Binding<Bool> {
        Binding(get: { !collapsedGroups.contains(path) }, set: { if $0 { collapsedGroups.remove(path) } else { collapsedGroups.insert(path) } })
    }
}

struct ProjectStatusBadge: View {
    let status: ProjectStatus?
    var body: some View {
        switch status?.state {
        case .synced:
            Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .pending(let added, let outdated, let removed):
            Label(summary(added, outdated, removed), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
        case .blocked(let reason):
            Label("Zablokowany", systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(.red).help(reason)
        case .missing:
            Label("Brak folderu", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.red)
        case nil:
            Label("Nieznany", systemImage: "clock").font(.caption).foregroundStyle(.tertiary)
        }
    }
    private func summary(_ added: Int, _ outdated: Int, _ removed: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if outdated > 0 { parts.append("~\(outdated)") }
        if removed > 0 { parts.append("-\(removed)") }
        return "Do synchronizacji " + parts.joined(separator: " ")
    }
}

private struct ProjectRow: View {
    let project: Project
    let status: ProjectStatus?
    let inheritsRoot: Bool
    @Binding var editing: Project?
    @Binding var previewProject: Project?
    @Binding var deleting: Project?
    @Binding var adopting: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 8) {
                        Text(project.name).fontWeight(.medium)
                        ProjectStatusBadge(status: status)
                        if inheritsRoot { Label("ustawienia folderu", systemImage: "arrow.turn.up.right").font(.caption2).foregroundStyle(.secondary).help("Skille, tagi i MCP tego projektu pochodzą z folderu nadrzędnego") }
                    }
                    Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(project.path)
                }
                Spacer()
                Menu {
                    Button("Edytuj…") { editing = project }
                    Button("Przejmij skille z projektu…") { adopting = project }
                    Divider()
                    Button("Usuń projekt…", role: .destructive) { deleting = project }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 42)
                Button("Synchronizuj wszystko") { previewProject = project }.buttonStyle(.borderedProminent)
            }
            HStack {
                ForEach(project.tools, id: \.self) { tool in
                    Text(tool.rawValue).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
                ForEach(project.tags, id: \.self) { TagPill(tag: $0) }
            }
        }
        .padding(.vertical, 7)
    }
}

struct AllProjectsSyncPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var plans: [ProjectSyncPlan]?; @State private var error = ""
    @State private var outcomes: [ProjectSyncOutcome] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja wszystkich projektów").font(.title2.bold())
            Text("Agentbox najpierw sprawdza plan dla wszystkich projektów. Każdy projekt jest synchronizowany transakcyjnie ze swoim backupem i rollbackiem. Błąd zatrzymuje serię, a projekt, który go zgłosił, wraca do stanu sprzed zmiany.").font(.caption).foregroundStyle(.secondary)
            Label("Wynikowe pliki MCP mogą zawierać jawne sekrety, dlatego pozostają wykluczone lokalnie z Git.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if plans == nil { ProgressView() }
            else if !outcomes.isEmpty { ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(outcomes) { ProjectSyncOutcomeRow(outcome: $0) } } } }
            else if let plans { ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(plans) { AllProjectsSyncPlanRow(plan: $0) } } } }
            HStack {
                Spacer()
                Button(outcomes.isEmpty ? "Zamknij" : "Gotowe") { dismiss() }
                if outcomes.isEmpty {
                    Button("Synchronizuj \(plans?.count ?? 0) projektów") {
                        Task {
                            let result = await model.syncAllProjects()
                            if result.allSatisfy({ $0.state == .synced || $0.state == .upToDate }) { dismiss() } else { outcomes = result }
                        }
                    }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || plans == nil || model.isWorking)
                }
            }
        }.padding(24).frame(width: 820, height: 700).task { do { plans = try await model.previewAllProjectsSync() } catch { self.error = error.localizedDescription; model.reportError(error) } }
    }
}

private struct ProjectSyncOutcomeRow: View {
    let outcome: ProjectSyncOutcome
    private var icon: (String, Color) {
        switch outcome.state {
        case .synced: ("checkmark.circle.fill", .green)
        case .upToDate: ("equal.circle.fill", .secondary)
        case .failed: ("xmark.octagon.fill", .red)
        case .skipped: ("minus.circle.fill", .secondary)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.plan.project.name).fontWeight(.medium)
                switch outcome.state {
                case .synced: Text("Zsynchronizowano").font(.caption).foregroundStyle(.secondary)
                case .upToDate: Text("Bez zmian — nic nie zapisano i nie utworzono backupu.").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason): Text("Cofnięto do stanu sprzed synchronizacji — \(reason)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                case .skipped: Text("Pominięto po wcześniejszym błędzie; pliki projektu nie zostały zmienione.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AllProjectsSyncPlanRow: View {
    let plan: ProjectSyncPlan
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.preview.skills, id: \.tool) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.target).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                    }
                }
                ForEach(plan.preview.mcp, id: \.tool.rawValue) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.file).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: [], removed: item.removed)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.project.name).font(.headline)
                Text(plan.project.path).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AdoptSkillsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let project: Project
    @State private var candidates: [AdoptableSkill]?
    @State private var selected = Set<String>()
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Przejmij skille z projektu").font(.title2.bold())
            Text("Katalogi ze `SKILL.md`, które leżą w \(project.name), nie są zarządzane przez Agentbox i nie mają jeszcze odpowiednika w bibliotece. Przejęcie kopiuje je do biblioteki jako skille lokalne — nic nie znika z projektu.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if candidates == nil { ProgressView() }
            else if candidates?.isEmpty == true { ContentUnavailableView("Brak kandydatów", systemImage: "checkmark.circle", description: Text("Wszystkie skille w tym projekcie są już zarządzane albo znane bibliotece.")) }
            else if let candidates {
                List {
                    ForEach(candidates) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.suggestedID).fontWeight(.medium)
                                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                if let candidates, !candidates.isEmpty {
                    Button("Zaznacz wszystkie") { selected = Set(candidates.map(\.id)) }
                    Button("Wyczyść") { selected.removeAll() }
                }
                Spacer()
                Button("Zamknij") { dismiss() }
                Button("Przejmij \(selected.count)") {
                    let items = (candidates ?? []).filter { selected.contains($0.id) }
                    Task { await model.adoptSkills(items); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || model.isWorking)
            }
        }
        .padding(24).frame(width: 640, height: 520)
        .task { do { candidates = try await model.adoptableSkills(project) } catch { self.error = error.localizedDescription } }
    }
}

struct GlobalSyncView: View {
    @ObservedObject var model: AppModel
    @State private var tools = Set<Tool>()
    @State private var skillIDs = Set<String>()
    @State private var tags = Set<String>()
    @State private var previews: [SkillSyncPreview] = []
    @State private var error = ""
    @State private var loaded = false
    private var availableTags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    private var selection: GlobalSkillSelection { GlobalSkillSelection(tools: Array(tools), skillIDs: Array(skillIDs), tags: Array(tags)) }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("Skille globalne", systemImage: "person.crop.circle").font(.largeTitle.bold())
            Text("Te skille trafiają do katalogu użytkownika i są widoczne we wszystkich sesjach wybranego klienta, niezależnie od projektu.").foregroundStyle(.secondary)
            GroupBox("Narzędzia") { VStack(alignment: .leading, spacing: 6) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Toggle(isOn: binding(tool, in: $tools)) {
                        HStack { Text(tool.rawValue.capitalized); Text(tool.globalSkillsURL().path).font(.caption).foregroundStyle(.secondary) }
                    }.toggleStyle(.checkbox)
                }
            }.padding(6) }
            GroupBox("Pojedyncze skille") {
                if model.skills.isEmpty { Text("Biblioteka jest pusta.").foregroundStyle(.secondary).padding(6) }
                else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading) { ForEach(model.skills) { skill in Toggle(skill.name, isOn: binding(skill.id, in: $skillIDs)).toggleStyle(.checkbox) } }.padding(6) }
            }
            GroupBox("Tagi dynamiczne") {
                if availableTags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) }
                else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(availableTags, id: \.self) { tag in Toggle("#\(tag)", isOn: binding(tag, in: $tags)).toggleStyle(.checkbox) } }.padding(6) }
            }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
            if !previews.isEmpty {
                GroupBox("Podgląd") { VStack(alignment: .leading, spacing: 10) { ForEach(previews, id: \.tool) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.target).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                    }
                } }.padding(6) }
            }
        }.padding(28) }
        .safeAreaInset(edge: .top, spacing: 0) {
            ActionBar {
                Button { Task { await model.saveGlobalSelection(selection); if await model.syncGlobal() { await refresh() } } } label: { Label("Synchronizuj globalnie", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent).disabled(tools.isEmpty || model.isWorking)
                Button { Task { await model.saveGlobalSelection(selection); await refresh() } } label: { Label("Zapisz wybór", systemImage: "tray.and.arrow.down") }.buttonStyle(.bordered)
                Button { Task { await refresh() } } label: { Label("Odśwież podgląd", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                Spacer()
            }.background(.bar)
        }
        .navigationTitle("Globalne")
        .task { guard !loaded else { return }; loaded = true; let saved = await model.globalSelection(); tools = Set(saved.tools); skillIDs = Set(saved.skillIDs); tags = Set(saved.tags); await refresh() }
    }

    private func refresh() async {
        do { previews = try await model.previewGlobalSync(); error = "" }
        catch { previews = []; self.error = error.localizedDescription }
    }
    private func binding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { if $0 { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
    }
}

struct MCPView: View {
    @ObservedObject var model: AppModel
    @State private var editingServer: MCPServer?
    @State private var serverToDelete: MCPServer?
    @State private var showImport = false
    @State private var bulkJSON: String?
    var body: some View { VStack(spacing: 0) { ActionBar {
        Button { showImport = true } label: { Label("Importuj lub użyj AI", systemImage: "sparkles") }.buttonStyle(.borderedProminent)
        Button { editingServer = MCPServer(name: "", transport: .stdio) } label: { Label("Nowy serwer", systemImage: "plus") }.buttonStyle(.bordered)
        Button { Task { bulkJSON = await model.exportMCPConfigurationJSON() } } label: { Label("Edytuj wszystko jako JSON", systemImage: "curlybraces") }.buttonStyle(.bordered).disabled(model.mcp.servers.isEmpty)
        Spacer()
        Text("\(model.mcp.servers.count) serwerów").font(.caption).foregroundStyle(.secondary)
    }; List {
        Section("Serwery") { ForEach(model.mcp.servers) { server in HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe").foregroundStyle(.tint); VStack(alignment: .leading, spacing: 5) { HStack { Text(server.name).fontWeight(.medium); Text(server.transport == .stdio ? "Lokalny" : "HTTP").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background((server.transport == .stdio ? Color.blue : Color.green).opacity(0.14), in: Capsule()); ForEach(server.tags ?? [], id: \.self) { TagPill(tag: $0) } }; let secretCount = (server.secretEnvironment?.count ?? 0) + (server.secretHeaders?.count ?? 0); Text("\(server.arguments.count) argumentów · \((server.environment.count) + (server.literalEnvironment?.count ?? 0) + (server.secretEnvironment?.count ?? 0)) zmiennych\(secretCount > 0 ? " · \(secretCount) sekretów lokalnych" : "")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Szczegóły") { editingServer = server }; Button(role: .destructive) { serverToDelete = server } label: { Image(systemName: "trash") } } } }
    } }.navigationTitle("MCP")
        .sheet(isPresented: $showImport) { MCPImportView(model: model) }
        .sheet(item: $editingServer) { server in MCPServerEditor(model: model, server: server, existingTags: Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted()) }
        .sheet(item: Binding(get: { bulkJSON.map(IdentifiableString.init) }, set: { bulkJSON = $0?.value })) { text in MCPImportView(model: model, prefill: text.value) }
        .confirmationDialog("Usunąć serwer \(serverToDelete?.name ?? "")?", isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })) { Button("Usuń", role: .destructive) { if let serverToDelete { Task { await model.deleteMCPServer(serverToDelete.id) } }; serverToDelete = nil }; Button("Anuluj", role: .cancel) { serverToDelete = nil } } message: { Text("Serwer zostanie usunięty także z bezpośrednich przypisań projektów.") }
    }
}

/// Wraps a `String` so it can back a `.sheet(item:)` — used to present the bulk JSON editor
/// pre-filled with a freshly generated export instead of an always-empty `.sheet(isPresented:)`.
struct IdentifiableString: Identifiable { let value: String; var id: String { value } }

struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let original: MCPServer; let existingTags: [String]
    @State private var name: String; @State private var transport: MCPTransport; @State private var command: String; @State private var arguments: String; @State private var url: String; @State private var enabled: Bool; @State private var tags: String
    @State private var fields: [MCPManagedField] = []
    @State private var editingJSON = false
    @State private var jsonText = ""
    init(model: AppModel, server: MCPServer, existingTags: [String]) { self.model = model; original = server; self.existingTags = existingTags; _name = State(initialValue: server.name); _transport = State(initialValue: server.transport); _command = State(initialValue: server.command); _arguments = State(initialValue: server.arguments.joined(separator: "\n")); _url = State(initialValue: server.url); _enabled = State(initialValue: server.enabled); _tags = State(initialValue: (server.tags ?? []).joined(separator: ", ")) }
    /// The JSON view only makes sense once the server is actually saved — a brand-new, unsaved one
    /// has nothing in the store yet to export or to match by id.
    private var isExisting: Bool { model.mcp.servers.contains { $0.id == original.id } }
    var body: some View { ScrollView { Form { Text("Serwer MCP").font(.title2.bold()); TextField("Nazwa techniczna", text: $name); HStack { TextField("Tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }; Toggle("Włączony", isOn: $enabled)
        if isExisting { Picker("Widok", selection: $editingJSON) { Text("Formularz").tag(false); Text("JSON").tag(true) }.pickerStyle(.segmented).onChange(of: editingJSON) { if editingJSON { Task { jsonText = await model.exportMCPServerJSON(original.id) } } } }
        if editingJSON && isExisting {
            Text("Pełna konfiguracja tego serwera, wartości wprost — łącznie z sekretami. ${VAR} to odczyt zmiennej systemowej; klucze wyglądające na token/hasło/API key automatycznie zostają tylko na tym Macu, reszta trafia do backupu Git.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $jsonText).font(.system(.body, design: .monospaced)).frame(height: 220).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        } else {
            Picker("Transport", selection: $transport) { Text("Lokalny STDIO").tag(MCPTransport.stdio); Text("Zdalny HTTP").tag(MCPTransport.http) }.pickerStyle(.segmented)
            if transport == .stdio { TextField("Polecenie, np. npx", text: $command); Text("Argumenty — jeden na linię").font(.caption).foregroundStyle(.secondary); TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 75) } else { TextField("URL", text: $url) }
        }
        GroupBox("Zmienne i nagłówki") { VStack(alignment: .leading, spacing: 10) { Text("Wartości widać wprost — to lokalna apka na tym Macu. Typ pola decyduje, czy wartość trafia do backupu Git: „Tylko na tym Macu” nigdy nie wychodzi poza mcp-secrets.json.").font(.caption).foregroundStyle(.secondary); ForEach($fields) { $field in MCPManagedFieldRow(field: $field) { fields.removeAll { $0.id == field.id } } }; HStack { Button("Dodaj zmienną") { fields.append(MCPManagedField(location: .environment, key: "", classification: .environment)) }; Button("Dodaj nagłówek") { fields.append(MCPManagedField(location: .header, key: "", classification: .environment)) } } }.padding(7) }
        HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(name.isEmpty || (editingJSON && isExisting ? jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (transport == .stdio ? command.isEmpty : url.isEmpty)) || model.isWorking) }
    }.padding(24) }.frame(width: 760, height: 760).task { fields = await model.managedFields(for: original) } }
    private func save() async -> Bool {
        if editingJSON && isExisting { return await model.updateMCPServerJSON(original.id, name: name, json: jsonText, enabled: enabled, tags: AppModel.csv(tags)) }
        let server = MCPServer(id: original.id, name: name, transport: transport, command: command, arguments: arguments.split(whereSeparator: \.isNewline).map(String.init), url: url, enabled: enabled, group: original.group, profile: original.profile, tags: AppModel.csv(tags))
        return await model.saveMCPServer(server, fields: fields)
    }
}

struct MCPManagedFieldRow: View {
    @Binding var field: MCPManagedField
    let onDelete: () -> Void
    var body: some View { HStack { Picker("Miejsce", selection: $field.location) { Text("Zmienna").tag(MCPImportField.Location.environment); Text("Nagłówek").tag(MCPImportField.Location.header) }.labelsHidden().frame(width: 105); TextField("Nazwa", text: $field.key).frame(minWidth: 120); Picker("Typ", selection: $field.classification) { ForEach(MCPValueClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 260); TextField(field.classification == .environment ? "Nazwa zmiennej systemowej" : "Wartość", text: $field.value); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }.onChange(of: field.classification) { if field.classification == .environment && field.value.isEmpty { field.value = field.key } } }
}

struct MCPImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    var prefill: String = ""
    @State private var source = ""
    @State private var summary: MCPImportSummary?
    @State private var error = ""
    @State private var useAI = false
    @State private var provider: MCPAIProvider = .openAI
    @State private var openAIModel = MCPAIDefaults.openAIModel
    @State private var claudeModel = MCPAIDefaults.claudeModel
    @State private var apiKey = ""
    @State private var working = false
    @State private var selected = Set<String>()
    @State private var classifications: [String: MCPValueClassification] = [:]
    var body: some View { VStack(alignment: .leading, spacing: 0) { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text(prefill.isEmpty ? "Import konfiguracji MCP" : "Edytuj konfigurację MCP jako JSON").font(.title2.bold())
        if !prefill.isEmpty { Text("Poniżej jest aktualna konfiguracja, wartości wprost — łącznie z sekretami. Popraw co trzeba i kliknij „Analizuj”, potem zaznacz serwery do zapisania — istniejące o tej samej nazwie zostaną nadpisane, reszta zostanie bez zmian. Klucze wyglądające na token/hasło/API key automatycznie zostają tylko na tym Macu.").font(.caption).foregroundStyle(.secondary) }
        Picker("Tryb", selection: $useAI) { Text("Mam JSON").tag(false); Text("Mam instrukcję — przygotuj z AI").tag(true) }.pickerStyle(.segmented)
        if useAI {
            HStack { Picker("Dostawca", selection: $provider) { Text("OpenAI").tag(MCPAIProvider.openAI); Text("Anthropic").tag(MCPAIProvider.claude) }.frame(width: 210); TextField("Model", text: provider == .openAI ? $openAIModel : $claudeModel); SecureField("Klucz API (puste = użyj zapisanego)", text: $apiKey) }
            if provider == .openAI ? model.hasOpenAIKey : model.hasAnthropicKey { Label("Klucz API zapisany: ••••••••", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green) }
            Text("Klucz zostanie zapisany lokalnie w niezaszyfrowanym pliku mcp-secrets.json i nigdy nie trafi do backupu Git. Instrukcja zostanie wysłana do wybranego API; istniejące sekrety MCP nie są dołączane.").font(.caption).foregroundStyle(.orange)
            Text("Wklej README, fragment instrukcji z GitHuba albo opisz serwer").font(.caption).foregroundStyle(.secondary)
        } else { HStack { Text("Wklej konfigurację Claude (`mcpServers` lub sam obiekt serwerów).").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Wybierz plik…") { chooseFile() } } }
        TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        if let summary {
            GroupBox("Rozpoznano") { VStack(alignment: .leading, spacing: 8) {
                HStack { Text("\(summary.servers.count) serwerów · \(summary.stdioCount) lokalnych · \(summary.httpCount) HTTP"); Spacer(); Button("Wszystkie") { selected = Set(summary.servers.map(\.name)) }.buttonStyle(.link); Button("Wyczyść") { selected.removeAll() }.buttonStyle(.link) }
                ForEach(summary.servers) { server in Toggle(isOn: Binding(get: { selected.contains(server.name) }, set: { if $0 { selected.insert(server.name) } else { selected.remove(server.name) } })) { HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe"); Text(server.name); Spacer() } }.toggleStyle(.checkbox) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
            if !summary.fields.isEmpty { GroupBox("Klasyfikacja wartości") { VStack(alignment: .leading, spacing: 8) {
                Text("Agentbox zaproponował typ każdej wartości. Sprawdź go przed importem — zwykłe wartości trafiają do backupu Git, sekrety lokalne nie.").font(.caption).foregroundStyle(.secondary)
                ForEach(summary.fields.filter { selected.contains($0.serverName) }) { field in HStack { VStack(alignment: .leading, spacing: 2) { Text("\(field.serverName) · \(field.key)").font(.callout.weight(.medium)); Text(field.location == .header ? "Nagłówek" : "Zmienna środowiskowa").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text(field.displayValue).font(.system(.caption, design: .monospaced)).lineLimit(1).frame(maxWidth: 170, alignment: .trailing); Picker("Typ", selection: classificationBinding(field)) { ForEach(MCPValueClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 175) }.padding(.vertical, 2) }
            }.padding(6) } }
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }.padding(24) }; Divider(); HStack { if working { ProgressView() }; if summary != nil { Text("Wybrano: \(selected.count)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Anuluj") { dismiss() }; Button(useAI ? "Przygotuj z AI" : "Analizuj") { Task { await prepare() } }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working); Button("Importuj wybrane") { Task { await importNow() } }.buttonStyle(.borderedProminent).disabled(summary == nil || selected.isEmpty || working) }.padding(16).background(.bar)
    }.frame(width: 760, height: 680).onAppear { if source.isEmpty { source = prefill }; if let settings = model.mcp.aiSettings { provider = settings.provider; openAIModel = settings.openAIModel; claudeModel = settings.claudeModel } } }
    private func prepare() async { working = true; error = ""; summary = nil; selected.removeAll(); classifications.removeAll(); defer { working = false }; do { if useAI { let settings = MCPAISettings(provider: provider, openAIModel: openAIModel, claudeModel: claudeModel); source = try await model.generateMCP(source, settings: settings, key: apiKey.isEmpty ? nil : apiKey) }; let analyzed = try await model.analyzeMCP(source); summary = analyzed; selected = Set(analyzed.servers.map(\.name)); classifications = Dictionary(uniqueKeysWithValues: analyzed.fields.map { ($0.id, $0.classification) }) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    private func importNow() async { working = true; error = ""; defer { working = false }; do { _ = try await model.importMCP(source, serverNames: selected, classifications: classifications); dismiss() } catch { self.error = error.localizedDescription; model.reportError(error) } }
    private func classificationBinding(_ field: MCPImportField) -> Binding<MCPValueClassification> { Binding(get: { classifications[field.id] ?? field.classification }, set: { classifications[field.id] = $0 }) }
    private func chooseFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.canChooseFiles = true; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { do { source = try String(contentsOf: url, encoding: .utf8); summary = nil } catch { self.error = error.localizedDescription } } }
}

struct MCPPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel; let project: Project
    @State private var preview: ProjectSyncPreview?; @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja · \(project.name)").font(.title2.bold())
            Text("Poniżej znajduje się pełny plan zmian skilli i konfiguracji MCP. Całość zostanie wycofana, jeśli którykolwiek zapis się nie powiedzie.").font(.caption).foregroundStyle(.secondary)
            Label("Pliki projektu mogą zawierać jawne sekrety. Agentbox doda je do lokalnego .git/info/exclude, ale nie szyfruje ich na dysku.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if preview?.mcp.contains(where: { $0.file.hasSuffix(".jsonc") }) == true { Label("Plik OpenCode JSONC zostanie przepisany jako JSON. Komentarze i dotychczasowe formatowanie zostaną usunięte.", systemImage: "text.badge.xmark").font(.caption).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if preview == nil { ProgressView() }
            else if let preview { ScrollView { VStack(alignment: .leading, spacing: 12) {
                Text("Skille").font(.headline)
                ForEach(preview.skills, id: \.tool) { item in GroupBox { VStack(alignment: .leading, spacing: 6) { Text(item.target).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed) }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "folder") } }
                Text("MCP").font(.headline).padding(.top, 4)
                ForEach(preview.mcp, id: \.tool.rawValue) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); DisclosureGroup("Podgląd pliku") { Text(item.content.isEmpty ? "Plik nie jest potrzebny — nie zostanie utworzony, a istniejący pusty szkielet zostanie usunięty." : item.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) } }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "doc.text") } }
            } } }
            HStack { Spacer(); Button("Zamknij") { dismiss() }; Button("Synchronizuj skille i MCP") { Task { await model.syncEverything(project) } }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || preview == nil || model.isWorking) }
        }.padding(24).frame(width: 820, height: 700).task { do { preview = try await model.previewProjectSync(project) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    }
}

struct SyncChangeRows: View {
    let added: [String], updated: [String], removed: [String]
    var body: some View { VStack(alignment: .leading, spacing: 3) { if added.isEmpty && updated.isEmpty && removed.isEmpty { Text("Brak zmian").font(.caption).foregroundStyle(.secondary) }; ForEach(added, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.green) }; ForEach(updated, id: \.self) { Label($0, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue) }; ForEach(removed, id: \.self) { Label($0, systemImage: "minus.circle.fill").foregroundStyle(.orange) } }.font(.caption) }
}

struct BackupView: View {
    @ObservedObject var model: AppModel
    @State private var remote = ""
    @State private var fullBackupToRestore: FullBackupInfo?
    @State private var fullBackupToDelete: FullBackupInfo?
    @State private var restoreRemote = ""
    @State private var showRestoreConfirmation = false
    @AppStorage("AgentboxAutoBackup") private var autoBackup = true
    @AppStorage("AgentboxAutoPush") private var autoPush = false
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .medium; return value }()
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        Label("Backup Git", systemImage: "externaldrive.badge.timemachine").font(.largeTitle.bold())
        Text("Do Git trafiają skille, tagi i konfiguracja MCP bez sekretów. Lokalne ścieżki projektów pozostają tylko na tym Macu.").foregroundStyle(.secondary)
        GroupBox("Automatyzacja") { VStack(alignment: .leading, spacing: 10) { Toggle("Automatycznie twórz lokalne commity", isOn: $autoBackup); Toggle("Automatycznie wysyłaj do origin", isOn: $autoPush).disabled(!autoBackup); Text("Zmiany skilli, tagów i serwerów są łączone przez 5 sekund w jeden commit. Pierwszy backup i konfigurację origin wykonaj ręcznie.").font(.caption).foregroundStyle(.secondary) }.padding(8) }
        TextField("Git remote, np. git@github.com:user/agentbox-backup.git", text: $remote).textFieldStyle(.roundedBorder)
        HStack { Button("Wykonaj backup teraz") { Task { await model.backup(remote: remote) } }.buttonStyle(.borderedProminent); Button("Odśwież status") { Task { await model.loadBackupStatus() } }.buttonStyle(.bordered); Spacer() }
        GroupBox("Status") { Text(model.backupStatus.isEmpty ? "Kliknij „Odśwież status”." : model.backupStatus).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
        Divider().padding(.vertical, 4)
        Label("Odtworzenie biblioteki ze zdalnego repozytorium", systemImage: "arrow.down.circle").font(.title2.bold())
        Text("Pobiera skille, katalog i konfigurację MCP z repozytorium backupu — na przykład przy konfiguracji nowego Maca. Projekty, lokalne ścieżki i sekrety na tym Macu pozostają bez zmian. Przed zapisem powstaje pełny backup lokalny.").foregroundStyle(.secondary)
        TextField("Adres repozytorium do odtworzenia", text: $restoreRemote).textFieldStyle(.roundedBorder)
        HStack { Button("Odtwórz bibliotekę") { showRestoreConfirmation = true }.buttonStyle(.bordered).disabled(restoreRemote.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking); Spacer() }
        Divider().padding(.vertical, 4)
        Label("Pełny backup lokalny", systemImage: "externaldrive.fill.badge.plus").font(.title2.bold())
        Label("Zawiera również projekty, lokalne ścieżki, wszystkie skille, MCP, sekrety i klucze AI. Pliki są czytelne i niezaszyfrowane — nie udostępniaj folderu backups.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        HStack { Button("Utwórz pełny backup") { Task { await model.createFullBackup() } }.buttonStyle(.borderedProminent); Button("Odśwież listę") { Task { await model.loadFullBackups() } }.buttonStyle(.bordered); Spacer(); Text("\(model.rootPath)/backups/full").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        GroupBox("Dostępne pełne backupy") { VStack(spacing: 8) { if model.fullBackups.isEmpty { Text("Brak pełnych backupów.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }; ForEach(model.fullBackups) { backup in HStack { Image(systemName: "archivebox.fill").foregroundStyle(.blue); VStack(alignment: .leading) { Text(formatter.string(from: backup.createdAt)); Text("Agentbox \(backup.applicationVersion) · \(backup.name)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Przywróć") { fullBackupToRestore = backup }.buttonStyle(.bordered); Button("Usuń", role: .destructive) { fullBackupToDelete = backup }.buttonStyle(.bordered) } } }.padding(8) }
    }.padding(28) }.navigationTitle("Backup").task { await model.loadBackupStatus(); await model.loadFullBackups() }
        .confirmationDialog("Przywrócić pełny backup?", isPresented: Binding(get: { fullBackupToRestore != nil }, set: { if !$0 { fullBackupToRestore = nil } })) { Button("Przywróć wszystkie dane", role: .destructive) { if let backup = fullBackupToRestore { Task { await model.restoreFullBackup(backup) } }; fullBackupToRestore = nil }; Button("Anuluj", role: .cancel) { fullBackupToRestore = nil } } message: { Text("Aktualna biblioteka, projekty, skille, MCP i sekrety zostaną zastąpione. Agentbox najpierw zachowa pełną kopię aktualnego stanu w backups/restore-rollbacks.") }
        .confirmationDialog("Usunąć pełny backup?", isPresented: Binding(get: { fullBackupToDelete != nil }, set: { if !$0 { fullBackupToDelete = nil } })) { Button("Usuń backup", role: .destructive) { if let backup = fullBackupToDelete { Task { await model.deleteFullBackup(backup) } }; fullBackupToDelete = nil }; Button("Anuluj", role: .cancel) { fullBackupToDelete = nil } } message: { Text("Ta kopia zawierająca również sekrety zostanie trwale usunięta z lokalnego folderu backups/full.") }
        .confirmationDialog("Odtworzyć bibliotekę z repozytorium?", isPresented: $showRestoreConfirmation) {
            Button("Odtwórz bibliotekę", role: .destructive) { Task { await model.restoreLibraryFromRemote(restoreRemote.trimmingCharacters(in: .whitespaces)) } }
            Button("Anuluj", role: .cancel) { }
        } message: { Text("Katalog skilli, catalog.json i mcp.json zostaną zastąpione zawartością repozytorium. Projekty, lokalne ścieżki i sekrety pozostaną bez zmian, a aktualny stan zostanie zapisany jako pełny backup lokalny.") }
    }
}

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @State private var snapshotToRestore: LibrarySnapshot?
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .medium; return value }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Odzyskiwanie", systemImage: "clock.arrow.circlepath").font(.largeTitle.bold()); Spacer(); Button("Odśwież") { Task { await model.loadRecovery() } }.buttonStyle(.bordered) }
            Text("Odzyskiwanie dotyczy biblioteki: katalogu skilli, tagów, konfiguracji MCP i projektów. Pliki w folderach projektów odtwarza się przez ponowną synchronizację, a czyści przez „Usuń i posprzątaj pliki” w sekcji Projekty.").foregroundStyle(.secondary)
            List {
                Section("Snapshoty biblioteki") {
                    if model.librarySnapshots.isEmpty { Text("Brak snapshotów biblioteki.").foregroundStyle(.secondary) }
                    ForEach(model.librarySnapshots) { snapshot in HStack { Image(systemName: "externaldrive").foregroundStyle(.blue); VStack(alignment: .leading, spacing: 3) { Text(formatter.string(from: snapshot.date)).fontWeight(.medium); Text(snapshot.files.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Przywróć") { snapshotToRestore = snapshot }.buttonStyle(.bordered) } }
                }
            }
        }
        .padding(24).navigationTitle("Odzyskiwanie").task { await model.loadRecovery() }
        .confirmationDialog("Przywrócić snapshot biblioteki?", isPresented: Binding(get: { snapshotToRestore != nil }, set: { if !$0 { snapshotToRestore = nil } })) {
            Button("Przywróć bibliotekę", role: .destructive) { if let snapshotToRestore { Task { await model.restoreLibrary(snapshotToRestore) } }; snapshotToRestore = nil }
            Button("Anuluj", role: .cancel) { snapshotToRestore = nil }
        } message: { Text("Aktualny stan zostanie zachowany jako nowy snapshot. Sekrety i katalog skills nie zostaną zmienione.") }
    }
}

@MainActor final class UpdateSettingsModel: ObservableObject {
    @Published var canCheckForUpdates: Bool
    @Published var automaticallyChecks: Bool
    @Published var automaticallyDownloads: Bool
    private let updater: SPUUpdater
    private var cancellables = Set<AnyCancellable>()

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyDownloads = $0 }.store(in: &cancellables)
    }

    func setAutomaticallyChecks(_ value: Bool) { updater.automaticallyChecksForUpdates = value }
    func setAutomaticallyDownloads(_ value: Bool) { updater.automaticallyDownloadsUpdates = value }
    func check() { updater.checkForUpdates() }
}

struct CheckForUpdatesView: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { Button("Sprawdź aktualizacje…") { model.check() }.disabled(!model.canCheckForUpdates) }
}

struct UpdateSettingsCard: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { GroupBox("Aktualizacje Agentbox") { VStack(alignment: .leading, spacing: 10) {
        Toggle("Automatycznie sprawdzaj aktualizacje", isOn: Binding(
            get: { model.automaticallyChecks },
            set: { value in model.setAutomaticallyChecks(value) }
        ))
        Toggle("Automatycznie pobieraj i instaluj", isOn: Binding(
            get: { model.automaticallyDownloads },
            set: { value in model.setAutomaticallyDownloads(value) }
        )).disabled(!model.automaticallyChecks)
        HStack { Text(AppVersion.display).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Sprawdź teraz") { model.check() }.disabled(!model.canCheckForUpdates) }
        Text("Aktualizacje są pobierane z GitHub Releases i weryfikowane podpisem EdDSA przed instalacją.").font(.caption).foregroundStyle(.secondary)
    }.padding(8) } }
}

@MainActor final class CLISettingsModel: ObservableObject {
    @Published var status = ""
    @Published var installed = false
    private let destination = URL(fileURLWithPath: "/usr/local/bin/agentbox")

    init() { refresh() }

    func refresh() {
        guard let bundledCLI else { status = "Ta kompilacja aplikacji nie zawiera CLI."; installed = false; return }
        guard let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else {
            if FileManager.default.fileExists(atPath: destination.path) { status = "Ścieżka /usr/local/bin/agentbox jest zajęta przez inny plik. Agentbox go nie nadpisze." }
            else { status = "CLI nie jest zainstalowane w /usr/local/bin." }
            installed = false; return
        }
        installed = URL(fileURLWithPath: linked).standardizedFileURL == bundledCLI.standardizedFileURL
        status = installed ? "CLI jest zainstalowane: /usr/local/bin/agentbox" : "Ścieżka /usr/local/bin/agentbox prowadzi do innego pliku. Agentbox go nie nadpisze."
    }

    func install() {
        guard let bundledCLI else { status = "Ta kompilacja aplikacji nie zawiera CLI."; return }
        guard !Bundle.main.bundleURL.path.hasPrefix("/Volumes/") else { status = "Najpierw przenieś Agentbox do folderu Aplikacje i uruchom go ponownie."; return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            refresh()
            if !installed { status = "Ścieżka /usr/local/bin/agentbox jest zajęta. Usuń istniejący plik ręcznie, jeśli chcesz go zastąpić." }
            return
        }
        do {
            if fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
                try fm.createSymbolicLink(at: destination, withDestinationURL: bundledCLI)
            } else {
                let escaped = bundledCLI.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let source = "do shell script \"/bin/mkdir -p /usr/local/bin && /bin/ln -s \" & quoted form of \"\(escaped)\" & \" /usr/local/bin/agentbox\" with administrator privileges"
                var scriptError: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&scriptError)
                if let scriptError { throw NSError(domain: "AgentboxCLIInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: scriptError[NSAppleScript.errorMessage] as? String ?? "Nie udało się zainstalować CLI."]) }
            }
            refresh()
        } catch { status = "Nie udało się zainstalować CLI: \(error.localizedDescription)"; installed = false }
    }

    private var bundledCLI: URL? {
        let value = Bundle.main.bundleURL.appending(path: "Contents/Helpers/agentbox")
        return FileManager.default.isExecutableFile(atPath: value.path) ? value : nil
    }
}

struct CLISettingsCard: View {
    @StateObject private var model = CLISettingsModel()
    var body: some View { GroupBox("Wiersz poleceń (CLI)") { VStack(alignment: .leading, spacing: 10) {
        Text(model.status).font(.caption).foregroundStyle(model.installed ? .green : .secondary).textSelection(.enabled)
        HStack { Text("Po instalacji użyj np. `agentbox project list` w nowym oknie Terminala.").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.installed ? "Zainstalowano" : "Zainstaluj CLI") { model.install() }.disabled(model.installed) }
    }.padding(8) }.onAppear { model.refresh() } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @State private var openAIModel = MCPAIDefaults.openAIModel
    @State private var anthropicModel = MCPAIDefaults.claudeModel
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Label("Ustawienia", systemImage: "gearshape").font(.largeTitle.bold())
            UpdateSettingsCard(updater: updater)
            CLISettingsCard()
            GroupBox("Folder biblioteki") { VStack(alignment: .leading, spacing: 12) { Text(model.rootPath).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Text("Tutaj Agentbox przechowuje skille, katalog, konfigurację projektów i repozytorium backupu Git.").font(.caption).foregroundStyle(.secondary); Button("Wybierz nowy folder…") { chooseFolder() } }.padding(8) }
            Text("Istniejąca biblioteka Agentbox/Skillbox zostanie podłączona bez kopiowania. Jeśli wskażesz pusty folder, obecna biblioteka zostanie do niego skopiowana.").foregroundStyle(.secondary)
            Text("Asystent AI do konfiguracji MCP").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                AIProviderSettingsCard(title: "OpenAI", icon: "sparkles", modelLabel: "Model OpenAI", modelName: $openAIModel, key: $openAIKey, hasSavedKey: model.hasOpenAIKey) { Task { await model.saveAIProvider(.openAI, model: openAIModel, key: openAIKey.isEmpty ? nil : openAIKey); openAIKey = "" } }
                AIProviderSettingsCard(title: "Anthropic", icon: "brain.head.profile", modelLabel: "Model Anthropic", modelName: $anthropicModel, key: $anthropicKey, hasSavedKey: model.hasAnthropicKey) { Task { await model.saveAIProvider(.claude, model: anthropicModel, key: anthropicKey.isEmpty ? nil : anthropicKey); anthropicKey = "" } }
            }
            Label("Klucze są przechowywane lokalnie bez szyfrowania w mcp-secrets.json i nie trafiają do backupu Git.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            Spacer()
        }.padding(28) }.navigationTitle("Ustawienia").onAppear { if let settings = model.mcp.aiSettings { openAIModel = settings.openAIModel; anthropicModel = settings.claudeModel } }
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Wybierz"; if panel.runModal() == .OK, let url = panel.url { Task { await model.moveLibrary(to: url) } } }
}

struct AIProviderSettingsCard: View {
    let title: String, icon: String, modelLabel: String
    @Binding var modelName: String
    @Binding var key: String
    let hasSavedKey: Bool
    let onSave: () -> Void
    var body: some View { GroupBox { VStack(alignment: .leading, spacing: 12) { Label(title, systemImage: icon).font(.headline); TextField(modelLabel, text: $modelName); SecureField(hasSavedKey ? "Nowy klucz — obecny pozostanie bez zmian" : "Klucz API", text: $key); if hasSavedKey { Label("Klucz zapisany: ••••••••", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green) } else { Label("Brak zapisanego klucza", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }; HStack { Spacer(); Button("Zapisz \(title)", action: onSave).buttonStyle(.borderedProminent).disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(8) }.frame(maxWidth: .infinity) }
}

struct BatchTagView: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int; let existingTags: [String]
    let onSave: (String) -> Void
    @State private var tags = ""
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Dodaj tagi").font(.title2.bold()); Text("Wybrano \(count) skilli. Nowe tagi zostaną dopisane do już istniejących.").foregroundStyle(.secondary); HStack { TextField("np. seo, marketing, audit", text: $tags).textFieldStyle(.roundedBorder); ExistingTagMenu(tags: existingTags, text: $tags) }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj") { onSave(tags); dismiss() }.buttonStyle(.borderedProminent).disabled(AppModel.csv(tags).isEmpty) } }.padding(24).frame(width: 520) }
}

struct ExistingTagMenu: View {
    let tags: [String]; @Binding var text: String
    var body: some View { Menu("Używane tagi") { if tags.isEmpty { Text("Brak tagów") } else { ForEach(tags, id: \.self) { tag in Button("#\(tag)") { var values = Set(AppModel.csv(text)); values.insert(tag); text = values.sorted().joined(separator: ", ") } } } }.disabled(tags.isEmpty) }
}

struct AddGitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var subpath = ""
    let onAdd: (String, String) -> Void
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("Dodaj z Git").font(.title2.bold()); Text("Adres repozytorium lub link GitHub do konkretnego folderu. Możesz wkleić kilka adresów — po jednym w linii.").font(.caption).foregroundStyle(.secondary); TextEditor(text: $url).font(.system(.body, design: .monospaced)).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)); TextField("Podfolder, np. skills (opcjonalnie)", text: $subpath); Text("Dla linku GitHub `/tree/branch/folder` branch i podfolder zostaną rozpoznane automatycznie. Zwykły URL repozytorium importuje wszystkie znalezione katalogi z SKILL.md.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Importuj") { onAdd(url, subpath); dismiss() }.buttonStyle(.borderedProminent).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 580) }
}

/// The settings a project and a parent folder share. Both edit them through this one view, so a
/// folder can never offer less than a project — including the rule that a tag owns everything it
/// pulls in.
struct SharedSettingsForm: View {
    let skills: [Skill]
    let servers: [MCPServer]
    @Binding var tools: Set<Tool>
    @Binding var selectedSkills: Set<String>
    @Binding var selectedTags: Set<String>
    @Binding var selectedServers: Set<UUID>
    @Binding var selectedMCPtags: Set<String>
    @Binding var excluded: Set<String>
    @Binding var manageGitignore: Bool

    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: $tools)).toggleStyle(.checkbox) } }.padding(6) }
            GroupBox("Pojedyncze skille") { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(skills) { skill in skillToggle(skill) } }.padding(6) }.frame(height: 150) }
            GroupBox("Tagi skilli") { tagGrid(availableTags, selection: $selectedTags) }
            GroupBox("Pojedyncze serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(servers) { server in serverToggle(server) } }.padding(6) }
            GroupBox("Tagi MCP") { tagGrid(mcpTags, selection: $selectedMCPtags) }
            exclusionsBox
            GroupBox("Git") { VStack(alignment: .leading, spacing: 6) { Toggle("Dopisuj wygenerowane pliki MCP do .gitignore projektu", isOn: $manageGitignore).toggleStyle(.checkbox); Text(".gitignore jedzie z repozytorium, więc chroni też zespół. Agentbox dopisuje tylko własny blok i nigdy nie usuwa istniejących wpisów.").font(.caption).foregroundStyle(.secondary) }.padding(6) }
        }
    }

    /// Every skill a tag pulls in can be excluded here, including one that was also ticked
    /// individually — the tag locks its checkbox, so this box is the only way to drop it.
    private var tagMatched: [Skill] { skills.filter { covered($0.tags, by: selectedTags) }.sorted { $0.name < $1.name } }
    /// Tags are compared case-insensitively, the same way the sync resolves them.
    private func covered(_ tags: [String], by selection: Set<String>) -> Bool {
        let wanted = Set(selection.map { $0.lowercased() })
        return !wanted.isDisjoint(with: tags.map { $0.lowercased() })
    }
    @ViewBuilder private var exclusionsBox: some View {
        GroupBox("Wykluczenia") {
            VStack(alignment: .leading, spacing: 6) {
                if tagMatched.isEmpty { Text("Wybierz tagi skilli, aby móc wykluczyć pojedyncze pozycje.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text("Te skille wchodzą przez tagi. Zaznaczone zostaną pominięte.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                        ForEach(tagMatched) { skill in
                            Toggle(skill.name, isOn: Binding(get: { excluded.contains(skill.id) }, set: { if $0 { excluded.insert(skill.id); selectedSkills.remove(skill.id) } else { excluded.remove(skill.id) } })).toggleStyle(.checkbox)
                        }
                    }
                }
            }.padding(6)
        }
    }
    // A selected tag pulls the skill/server in on its own; showing it checked-but-locked here makes
    // that visible right on the list instead of only in the separate "Wykluczenia" box. The tag wins
    // even over an earlier individual tick, so an item tagged later looks the same as one the tag
    // pulled in from the start. Unticking the tag before saving brings the individual tick back;
    // saving hands the item to the tag, because the store drops ids a tag already covers.
    private func skillToggle(_ skill: Skill) -> some View {
        let tagCovered = covered(skill.tags, by: selectedTags)
        return Toggle(skill.name, isOn: tagCovered ? .constant(true) : setBinding(skill.id, in: $selectedSkills)).toggleStyle(.checkbox)
            .disabled(tagCovered).help(tagCovered ? "Wybrany przez tag — odznacz go w sekcji Wykluczenia, by pominąć" : "")
    }
    private func serverToggle(_ server: MCPServer) -> some View {
        let tagCovered = covered(server.tags ?? [], by: selectedMCPtags)
        return Toggle(server.name, isOn: tagCovered ? .constant(true) : setBinding(server.id, in: $selectedServers)).toggleStyle(.checkbox)
            .disabled(tagCovered).help(tagCovered ? "Wybrany przez tag MCP" : "")
    }
    private func tagGrid(_ tags: [String], selection: Binding<Set<String>>) -> some View { Group { if tags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) } else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(tags, id: \.self) { tag in Toggle("#\(tag)", isOn: setBinding(tag, in: selection)).toggleStyle(.checkbox) } }.padding(6) } } }
}

func setBinding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
    Binding(get: { set.wrappedValue.contains(value) }, set: { enabled in if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
}

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let servers: [MCPServer]
    let project: Project?
    /// The parent folder this project belongs to, when it came from one.
    var root: ProjectRoot?
    /// The project as synchronization sees it right now. When it follows the folder, this fills the
    /// form with what it actually gets, so switching to its own settings starts from today's state
    /// instead of an empty editor.
    var inheritedFrom: Project?
    let selectedServerIDs: [UUID]
    let selectedServerTags: [String]
    let onSave: (Project, [UUID], [String]) -> Void
    @State private var name = ""
    @State private var path = ""
    @State private var tools = Set(Tool.allCases)
    @State private var selected = Set<String>()
    @State private var selectedTags = Set<String>()
    @State private var selectedServers = Set<UUID>()
    @State private var selectedMCPtags = Set<String>()
    @State private var excluded = Set<String>()
    @State private var manageGitignore = false
    @State private var usesOwnSettings = true

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text(project == nil ? "Nowy projekt" : "Edytuj projekt").font(.title2.bold())
            TextField("Nazwa", text: $name)
            HStack { TextField("Folder projektu", text: $path); Button("Wybierz…") { chooseFolder() } }
            inheritanceBox
            SharedSettingsForm(skills: skills, servers: servers, tools: $tools, selectedSkills: $selected, selectedTags: $selectedTags, selectedServers: $selectedServers, selectedMCPtags: $selectedMCPtags, excluded: $excluded, manageGitignore: $manageGitignore)
                .disabled(!usesOwnSettings)
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { save(); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || path.isEmpty || (usesOwnSettings && tools.isEmpty)) }
        }.padding(24) }
        .frame(width: 700, height: 880)
        .onAppear { load() }
    }

    @ViewBuilder private var inheritanceBox: some View {
        if let root {
            GroupBox("Skąd projekt bierze ustawienia") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $usesOwnSettings) {
                        Text("Z folderu „\(root.name)”").tag(false)
                        Text("Własne dla tego projektu").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(usesOwnSettings
                         ? "Zmiany w folderze nadrzędnym nie będą już dotyczyć tego projektu."
                         : "Skille, tagi, serwery MCP i opcja .gitignore pochodzą z folderu nadrzędnego — zmiana tam obejmuje wszystkie projekty, które z niego korzystają. Poniżej widać, co folder ustawia.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
        }
    }

    private func load() {
        selectedServers = Set(selectedServerIDs); selectedMCPtags = Set(selectedServerTags)
        guard let project else { manageGitignore = true; return }
        name = project.name; path = project.path
        usesOwnSettings = root == nil || project.overridesRoot == true
        let source = usesOwnSettings ? project : (inheritedFrom ?? project)
        tools = Set(source.tools); selected = Set(source.skillIDs); selectedTags = Set(source.tags)
        excluded = Set(source.excludedSkillIDs ?? []); manageGitignore = source.manageGitignore ?? false
    }

    private func save() {
        let follows = root != nil && !usesOwnSettings
        // A project following its folder stores nothing of its own. Keeping a copy would look like
        // a second source of truth and would resurface the moment the folder's settings changed.
        let saved = Project(
            id: project?.id ?? UUID(), name: name, path: path,
            tools: follows ? [] : Array(tools),
            skillIDs: follows ? [] : Array(selected),
            tags: follows ? [] : Array(selectedTags).sorted(),
            excludedSkillIDs: follows || excluded.isEmpty ? nil : Array(excluded).sorted(),
            manageGitignore: follows ? nil : manageGitignore,
            rootID: project?.rootID,
            overridesRoot: root == nil ? nil : (usesOwnSettings ? true : nil))
        onSave(saved, follows ? [] : Array(selectedServers), follows ? [] : Array(selectedMCPtags).sorted())
    }

    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url?.path ?? path } }
}

/// Settings shared by every project in a parent folder. Editing them here is the point of adding a
/// folder in a batch: one change reaches all its projects instead of being repeated in each one.
struct ProjectRootEditor: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let servers: [MCPServer]
    let root: ProjectRoot
    let followingProjects: Int
    let selectedServerIDs: [UUID]
    let selectedServerTags: [String]
    let onSave: (ProjectRoot, [UUID], [String]) -> Void
    @State private var name = ""
    @State private var tools = Set<Tool>()
    @State private var selected = Set<String>()
    @State private var selectedTags = Set<String>()
    @State private var selectedServers = Set<UUID>()
    @State private var selectedMCPtags = Set<String>()
    @State private var excluded = Set<String>()
    @State private var manageGitignore = false
    @State private var watchesNewFolders = true
    @State private var ignoredPaths: [String] = []

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("Ustawienia folderu nadrzędnego").font(.title2.bold())
            TextField("Nazwa", text: $name)
            Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(followingProjects == 0
                 ? "Żaden projekt nie korzysta jeszcze z tych ustawień."
                 : "Te ustawienia obejmują \(followingProjects) projektów. Projekty z własnymi ustawieniami pozostają nietknięte.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Nowe podfoldery") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Pytaj, gdy w tym folderze pojawi się nowy podfolder", isOn: $watchesNewFolders).toggleStyle(.checkbox)
                    Text("Agentbox sprawdza folder przy każdym odświeżeniu listy projektów i proponuje dodanie oraz synchronizację nowych podfolderów.").font(.caption).foregroundStyle(.secondary)
                    if !ignoredPaths.isEmpty {
                        HStack {
                            Text("Pominięte podfoldery: \(ignoredPaths.count)").font(.caption).foregroundStyle(.secondary)
                            Button("Przywróć pominięte") { ignoredPaths = [] }.controlSize(.small)
                        }
                        Text(ignoredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }.padding(6)
            }
            SharedSettingsForm(skills: skills, servers: servers, tools: $tools, selectedSkills: $selected, selectedTags: $selectedTags, selectedServers: $selectedServers, selectedMCPtags: $selectedMCPtags, excluded: $excluded, manageGitignore: $manageGitignore)
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { save(); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || tools.isEmpty) }
        }.padding(24) }
        .frame(width: 700, height: 900)
        .onAppear {
            name = root.name; tools = Set(root.tools); selected = Set(root.skillIDs); selectedTags = Set(root.tags)
            excluded = Set(root.excludedSkillIDs ?? []); manageGitignore = root.manageGitignore ?? false
            watchesNewFolders = root.watchesNewFolders; ignoredPaths = root.ignoredPaths
            selectedServers = Set(selectedServerIDs); selectedMCPtags = Set(selectedServerTags)
        }
    }

    private func save() {
        let updated = ProjectRoot(id: root.id, name: name, path: root.path, tools: Array(tools), skillIDs: Array(selected), tags: Array(selectedTags).sorted(), excludedSkillIDs: excluded.isEmpty ? nil : Array(excluded).sorted(), manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders, ignoredPaths: ignoredPaths)
        onSave(updated, Array(selectedServers), Array(selectedMCPtags).sorted())
    }
}

/// What `Dodaj wiele` produces: either a parent folder plus the subfolders picked from it, or —
/// when the user does not want shared settings — plain projects, exactly as before.
struct BatchProjectRequest {
    var root: ProjectRoot?
    var folders: [String] = []
    var projects: [Project] = []
    var serverIDs: [UUID] = []
    var serverTags: [String] = []
    /// Subfolders left unticked are an answer too, so by default they are not proposed again.
    var treatingExistingAsKnown = true
}

struct BatchProjectView: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]; let servers: [MCPServer]; let existingProjects: [Project]; let existingRoots: [ProjectRoot]
    let onSave: (BatchProjectRequest) -> Void
    @State private var root = ""; @State private var folders: [URL] = []; @State private var selectedFolders = Set<String>()
    @State private var tools = Set(Tool.allCases); @State private var selectedSkills = Set<String>(); @State private var selectedTags = Set<String>(); @State private var selectedServers = Set<UUID>(); @State private var selectedMCPtags = Set<String>(); @State private var excluded = Set<String>(); @State private var manageGitignore = true; @State private var scanError = ""
    @State private var sharedSettings = true; @State private var watchesNewFolders = true; @State private var onlyFutureFolders = true; @State private var rootName = ""
    private var existingPaths: Set<String> { Set(existingProjects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) }
    private var availableFolders: [URL] { folders.filter { !existingPaths.contains($0.standardizedFileURL.path) } }
    private var rootAlreadyAdded: Bool { !root.isEmpty && existingRoots.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path } }
    private var rootNameTaken: Bool { existingRoots.contains { $0.name.caseInsensitiveCompare(rootName) == .orderedSame } }

    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text("Dodaj wiele projektów").font(.title2.bold())
        Text("Ustawienia zapisują się na folderze nadrzędnym i schodzą na jego podfoldery. Pojedynczy projekt może później dostać własne.").foregroundStyle(.secondary)
        HStack { TextField("Folder nadrzędny", text: $root); Button("Wybierz…") { chooseRoot() } }
        if !scanError.isEmpty { Label(scanError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        if rootAlreadyAdded { Label("Ten folder jest już dodany jako nadrzędny. Otwórz jego ustawienia na liście projektów.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        GroupBox("Ustawienia wspólne") { VStack(alignment: .leading, spacing: 6) {
            Toggle("Zapisz ustawienia na folderze nadrzędnym i dziedzicz je w podfolderach", isOn: $sharedSettings).toggleStyle(.checkbox)
            Toggle("Pytaj, gdy w folderze pojawi się nowy podfolder", isOn: $watchesNewFolders).toggleStyle(.checkbox).disabled(!sharedSettings)
            Toggle("Pytaj tylko o podfoldery, które pojawią się od teraz", isOn: $onlyFutureFolders).toggleStyle(.checkbox).disabled(!sharedSettings || !watchesNewFolders)
                .help("Odznaczone podfoldery z listy poniżej zostaną uznane za znane, więc Agentbox nie zapyta o nie ponownie")
            if sharedSettings {
                TextField("Nazwa folderu nadrzędnego", text: $rootName)
                if rootNameTaken { Text("Folder nadrzędny o tej nazwie już istnieje.").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Bez wspólnych ustawień każdy projekt dostaje własną kopię tego, co wybierzesz poniżej — tak jak w poprzednich wersjach.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(6) }
        GroupBox("Podfoldery") { VStack(alignment: .leading, spacing: 7) {
            if folders.isEmpty { Text("Wybierz folder, aby znaleźć projekty.").foregroundStyle(.secondary) }
            else { HStack { Button("Zaznacz dostępne") { selectedFolders = Set(availableFolders.map(\.path)) }; Button("Wyczyść") { selectedFolders.removeAll() }; Spacer(); Text("Wybrano \(selectedFolders.count)").foregroundStyle(.secondary) }; ForEach(folders, id: \.path) { folder in let exists = existingPaths.contains(folder.standardizedFileURL.path); Toggle(isOn: folderBinding(folder)) { HStack { Image(systemName: "folder"); Text(folder.lastPathComponent); Spacer(); if exists { Text("już dodany").font(.caption).foregroundStyle(.secondary) } } }.toggleStyle(.checkbox).disabled(exists) } }
        }.padding(6) }.frame(maxHeight: 230)
        SharedSettingsForm(skills: skills, servers: servers, tools: $tools, selectedSkills: $selectedSkills, selectedTags: $selectedTags, selectedServers: $selectedServers, selectedMCPtags: $selectedMCPtags, excluded: $excluded, manageGitignore: $manageGitignore)
        HStack { Spacer(); Button("Anuluj") { dismiss() }; Button(sharedSettings ? "Dodaj folder i \(selectedFolders.count) projektów" : "Dodaj \(selectedFolders.count) projektów") { save(); dismiss() }.buttonStyle(.borderedProminent).disabled(saveDisabled) }
    }.padding(24) }.frame(width: 760, height: 900) }

    private var saveDisabled: Bool {
        if tools.isEmpty || rootAlreadyAdded { return true }
        if sharedSettings { return root.isEmpty || rootName.isEmpty || rootNameTaken }
        return selectedFolders.isEmpty
    }

    private func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; guard panel.runModal() == .OK, let url = panel.url else { return }; root = url.path; rootName = url.lastPathComponent; do { folders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }; selectedFolders = Set(availableFolders.map(\.path)); scanError = "" } catch { folders = []; selectedFolders = []; scanError = error.localizedDescription } }
    private func folderBinding(_ folder: URL) -> Binding<Bool> { Binding(get: { selectedFolders.contains(folder.path) }, set: { if $0 { selectedFolders.insert(folder.path) } else { selectedFolders.remove(folder.path) } }) }

    private func save() {
        let chosen = availableFolders.filter { selectedFolders.contains($0.path) }
        let exclusions = excluded.isEmpty ? nil : Array(excluded).sorted()
        guard sharedSettings else {
            let projects = chosen.map { Project(name: $0.lastPathComponent, path: $0.path, tools: Array(tools), skillIDs: Array(selectedSkills), tags: Array(selectedTags).sorted(), excludedSkillIDs: exclusions, manageGitignore: manageGitignore) }
            onSave(BatchProjectRequest(root: nil, projects: projects, serverIDs: Array(selectedServers), serverTags: Array(selectedMCPtags).sorted()))
            return
        }
        let folder = ProjectRoot(name: rootName, path: root, tools: Array(tools), skillIDs: Array(selectedSkills), tags: Array(selectedTags).sorted(), excludedSkillIDs: exclusions, manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders)
        onSave(BatchProjectRequest(root: folder, folders: chosen.map(\.path), serverIDs: Array(selectedServers), serverTags: Array(selectedMCPtags).sorted(), treatingExistingAsKnown: onlyFutureFolders))
    }
}

/// Turns a folder that already holds projects into a parent folder with shared settings.
///
/// Adopting existing projects is not a neutral operation — a project that starts following the
/// folder synchronizes what the folder says, not what it said before. The form therefore starts
/// from everything the group already uses together and spells out, per project, what would change.
struct GroupRootSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let folderPath: String
    let projects: [Project]
    @State private var name = ""
    @State private var tools = Set<Tool>()
    @State private var selectedSkills = Set<String>()
    @State private var selectedTags = Set<String>()
    @State private var selectedServers = Set<UUID>()
    @State private var selectedMCPtags = Set<String>()
    @State private var excluded = Set<String>()
    @State private var manageGitignore = false
    @State private var watchesNewFolders = true
    @State private var onlyFutureFolders = true
    @State private var following = Set<UUID>()
    @State private var loaded = false

    private var nameTaken: Bool { model.projectRoots.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("Wspólne ustawienia folderu").font(.title2.bold())
            Text(folderPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Skille, tagi i serwery MCP ustawione tutaj obowiązują wszystkie zaznaczone projekty. Późniejsza zmiana w folderze obejmuje je wszystkie naraz.").foregroundStyle(.secondary)
            TextField("Nazwa folderu", text: $name)
            if nameTaken { Label("Folder nadrzędny o tej nazwie już istnieje.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            GroupBox("Projekty w tym folderze") { VStack(alignment: .leading, spacing: 7) {
                Text("Zaznaczone przechodzą na wspólne ustawienia. Odznaczone zostają w folderze, ale zachowują to, co mają dziś.").font(.caption).foregroundStyle(.secondary)
                ForEach(projects) { project in
                    Toggle(isOn: setBinding(project.id, in: $following)) {
                        HStack {
                            Text(project.name)
                            Spacer()
                            Text(change(for: project)).font(.caption).foregroundStyle(following.contains(project.id) ? .secondary : .tertiary)
                        }
                    }.toggleStyle(.checkbox)
                }
                HStack { Button("Zaznacz wszystkie") { following = Set(projects.map(\.id)) }; Button("Odznacz wszystkie") { following.removeAll() } }
            }.padding(6) }
            GroupBox("Nowe podfoldery") { VStack(alignment: .leading, spacing: 6) {
                Toggle("Pytaj, gdy w tym folderze pojawi się nowy podfolder", isOn: $watchesNewFolders).toggleStyle(.checkbox)
                Text("Nowy podfolder — na przykład świeżo sklonowane repozytorium — pojawi się jako pytanie nad listą projektów oraz jako plakietka przy `Projekty`.").font(.caption).foregroundStyle(.secondary)
                Toggle("Pytaj tylko o podfoldery, które pojawią się od teraz", isOn: $onlyFutureFolders).toggleStyle(.checkbox).disabled(!watchesNewFolders)
                Text(onlyFutureFolders
                     ? "Podfoldery, które są w tym folderze teraz i nie są projektami, zostają uznane za znane. Wrócą po kliknięciu `Przywróć pominięte` w ustawieniach folderu."
                     : "Agentbox zapyta także o podfoldery, które już tam leżą i nie są projektami.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6) }
            SharedSettingsForm(skills: model.skills, servers: model.mcp.servers, tools: $tools, selectedSkills: $selectedSkills, selectedTags: $selectedTags, selectedServers: $selectedServers, selectedMCPtags: $selectedMCPtags, excluded: $excluded, manageGitignore: $manageGitignore)
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz folder nadrzędny") { save(); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || nameTaken || tools.isEmpty) }
        }.padding(24) }
        .frame(width: 760, height: 900)
        .onAppear { load() }
    }

    /// Starts from everything the projects in the folder already use together, so creating the
    /// folder does not quietly take anything away from any of them.
    private func load() {
        guard !loaded else { return }
        loaded = true
        name = URL(fileURLWithPath: folderPath).lastPathComponent
        following = Set(projects.map(\.id))
        tools = Set(projects.flatMap(\.tools))
        selectedSkills = Set(projects.flatMap(\.skillIDs))
        selectedTags = Set(projects.flatMap(\.tags))
        // Only what every project already excludes stays excluded; anything else would drop a skill
        // that one of them deliberately keeps.
        excluded = projects.dropFirst().reduce(Set(projects.first?.excludedSkillIDs ?? [])) { $0.intersection(Set($1.excludedSkillIDs ?? [])) }
        manageGitignore = !projects.isEmpty && projects.allSatisfy { $0.manageGitignore == true }
        selectedServers = Set(projects.flatMap { model.selectedMCPServerIDs(for: $0) })
        selectedMCPtags = Set(projects.flatMap { model.selectedMCPServerTags(for: $0) })
    }

    /// What the project would gain or lose, counted the same way synchronization resolves it.
    private func change(for project: Project) -> String {
        guard following.contains(project.id) else { return "zachowa własne" }
        let before = resolvedSkills(ids: Set(project.skillIDs), tags: Set(project.tags), excluded: Set(project.excludedSkillIDs ?? []))
        let after = resolvedSkills(ids: selectedSkills, tags: selectedTags, excluded: excluded)
        let beforeServers = resolvedServers(ids: Set(model.selectedMCPServerIDs(for: project)), tags: Set(model.selectedMCPServerTags(for: project)))
        let afterServers = resolvedServers(ids: selectedServers, tags: selectedMCPtags)
        var parts: [String] = []
        let addedSkills = after.subtracting(before).count, removedSkills = before.subtracting(after).count
        let addedServers = afterServers.subtracting(beforeServers).count, removedServers = beforeServers.subtracting(afterServers).count
        if addedSkills > 0 { parts.append("+\(addedSkills) skilli") }
        if removedSkills > 0 { parts.append("−\(removedSkills) skilli") }
        if addedServers > 0 { parts.append("+\(addedServers) MCP") }
        if removedServers > 0 { parts.append("−\(removedServers) MCP") }
        return parts.isEmpty ? "bez zmian" : parts.joined(separator: ", ")
    }

    private func resolvedSkills(ids: Set<String>, tags: Set<String>, excluded: Set<String>) -> Set<String> {
        let wanted = Set(tags.map { $0.lowercased() })
        return Set(model.skills.filter { skill in
            (ids.contains(skill.id) || !wanted.isDisjoint(with: skill.tags.map { $0.lowercased() })) && !excluded.contains(skill.id)
        }.map(\.id))
    }

    private func resolvedServers(ids: Set<UUID>, tags: Set<String>) -> Set<UUID> {
        let wanted = Set(tags.map { $0.lowercased() })
        return Set(model.mcp.servers.filter { server in
            server.enabled && (ids.contains(server.id) || !wanted.isDisjoint(with: (server.tags ?? []).map { $0.lowercased() }))
        }.map(\.id))
    }

    private func save() {
        let root = ProjectRoot(name: name, path: folderPath, tools: Array(tools), skillIDs: Array(selectedSkills), tags: Array(selectedTags).sorted(), excludedSkillIDs: excluded.isEmpty ? nil : Array(excluded).sorted(), manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders)
        let followers = projects.map(\.id).filter { following.contains($0) }
        let owners = projects.map(\.id).filter { !following.contains($0) }
        model.adoptGroupIntoRoot(root, following: followers, keepingOwnSettings: owners, serverIDs: Array(selectedServers), serverTags: Array(selectedMCPtags).sorted(), treatingExistingAsKnown: onlyFutureFolders)
    }
}

/// Subfolders that showed up in a watched parent folder. Each one is a yes/no question, and both
/// answers are remembered: adding makes it a project, skipping stops it from being offered again.
struct DetectedFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var selected = Set<String>()

    private var groups: [(name: String, folders: [DetectedProjectFolder])] {
        Dictionary(grouping: model.detectedFolders, by: \.rootName)
            .map { (name: $0.key, folders: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var chosen: [DetectedProjectFolder] { model.detectedFolders.filter { selected.contains($0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nowe podfoldery").font(.title2.bold())
            Text("Te foldery pojawiły się w folderach nadrzędnych i nie są jeszcze projektami. Dodane projekty korzystają z ustawień swojego folderu.").foregroundStyle(.secondary)
            HStack { Button("Zaznacz wszystkie") { selected = Set(model.detectedFolders.map(\.path)) }; Button("Wyczyść") { selected.removeAll() }; Spacer(); Text("Wybrano \(selected.count)").foregroundStyle(.secondary) }
            List {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.folders) { folder in
                            Toggle(isOn: setBinding(folder.path, in: $selected)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.name)
                                    Text(folder.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).help(folder.path)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                Button("Pomijaj zaznaczone") { let folders = chosen; Task { await model.ignoreDetected(folders) }; dismiss() }.disabled(selected.isEmpty)
                Spacer()
                Button("Później") { dismiss() }
                Button("Dodaj bez synchronizacji") { let folders = chosen; Task { await model.addDetected(folders, synchronizing: false) }; dismiss() }.disabled(selected.isEmpty)
                Button("Dodaj i synchronizuj") { let folders = chosen; Task { await model.addDetected(folders, synchronizing: true) }; dismiss() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .onAppear { selected = Set(model.detectedFolders.map(\.path)) }
    }
}

/// A skill written or pasted straight into Agentbox, with no folder on disk and no repository.
struct NewSkillDraft {
    var id = ""
    var name = ""
    var description = ""
    var content = ""
    var tags: [String] = []
}

struct NewSkillView: View {
    @Environment(\.dismiss) private var dismiss
    let existingTags: [String]
    let existingIDs: Set<String>
    let onCreate: (NewSkillDraft) -> Void
    @State private var name = ""
    @State private var identifier = ""
    @State private var identifierEdited = false
    @State private var description = ""
    @State private var tags = ""
    @State private var content = ""

    /// Content pasted with its own YAML block is a finished `SKILL.md`, so the name and description
    /// fields would be a lie — Agentbox saves such a paste untouched and says so.
    private var pastedComplete: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") }
    private var suggestedID: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-") }
    private var effectiveID: String { (identifierEdited ? identifier : suggestedID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var idValid: Bool { effectiveID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil }
    private var idTaken: Bool { existingIDs.contains(effectiveID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nowy skill").font(.title2.bold())
            Text("Treść trafia prosto do biblioteki jako `SKILL.md`. Taki skill można później edytować w Agentbox — w przeciwieństwie do skilli z Git, które nadpisuje aktualizacja.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Nazwa", text: $name); TextField("Identyfikator", text: Binding(get: { identifierEdited ? identifier : suggestedID }, set: { identifier = $0; identifierEdited = true })) }
            if !effectiveID.isEmpty && !idValid { Label("Identyfikator może zawierać tylko małe litery, cyfry i pojedyncze myślniki.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if idTaken { Label("Skill o tym identyfikatorze już jest w bibliotece.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            TextField("Opis (trafia do nagłówka SKILL.md)", text: $description).disabled(pastedComplete)
            HStack { TextField("tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }
            GroupBox(pastedComplete ? "Treść — wklejony SKILL.md zostanie zapisany bez zmian" : "Treść") {
                TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 240)
            }
            Text(pastedComplete
                 ? "Wykryto nagłówek YAML, więc Agentbox nie dopisuje własnego."
                 : "Agentbox dopisze nagłówek YAML z nazwą i opisem. Wklej gotowy plik z blokiem `---`, aby zachować własny nagłówek.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz skill") { onCreate(NewSkillDraft(id: effectiveID, name: name, description: description, content: content, tags: AppModel.csv(tags))); dismiss() }.buttonStyle(.borderedProminent).disabled(!idValid || idTaken || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24)
        .frame(width: 720, height: 640)
    }
}

struct StatusToast: View { let text: String; let onClose: () -> Void; var body: some View { HStack(spacing: 10) { Label(text, systemImage: "info.circle.fill"); Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Zamknij") }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).shadow(radius: 8).padding(.bottom, 14) } }
