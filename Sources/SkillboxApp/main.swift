import SwiftUI
import AppKit
import Combine
import Sparkle
import SkillboxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); DispatchQueue.main.async { NSApp.windows.first?.makeKeyAndOrderFront(nil) } }
}

@main struct AgentboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updaterController: SPUStandardUpdaterController
    init() { updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) }
    var body: some Scene {
        WindowGroup { ContentView(updater: updaterController.updater) }.defaultSize(width: 1100, height: 720)
            .commands { CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: updaterController.updater) } }
    }
}

enum SectionKind: String, CaseIterable, Identifiable {
    case library = "Biblioteka", projects = "Projekty", mcp = "MCP", backup = "Backup", recovery = "Odzyskiwanie", settings = "Ustawienia"
    var id: String { rawValue }
    var icon: String { switch self { case .library: "square.grid.2x2"; case .projects: "folder"; case .mcp: "network"; case .backup: "externaldrive.badge.timemachine"; case .recovery: "clock.arrow.circlepath"; case .settings: "gearshape" } }
}

struct OperationLogEntry: Identifiable {
    enum Kind { case success, error, info }
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
    @Published var projectBackups: [ProjectSyncBackup] = []
    private var automaticBackupTask: Task<Void, Never>?
    var service: SkillboxService?
    init() {
        let saved = UserDefaults.standard.string(forKey: "SkillboxLibraryRoot")
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Skillbox").path
        let shared = AgentboxRootPreference.load()?.path
        rootPath = saved ?? shared ?? defaultPath
        service = try? SkillboxService(root: URL(fileURLWithPath: rootPath))
        Task { await reload() }
    }
    func reload() async { do { skills = try await service?.listSkills() ?? []; projects = try await service?.listProjects() ?? []; mcp = try await service?.mcpConfiguration() ?? MCPConfiguration(); if let service { hasOpenAIKey = try await service.hasMCPAIKey(.openAI); hasAnthropicKey = try await service.hasMCPAIKey(.claude) }; if selection == nil { selection = skills.first?.id }; await loadMarkdown() } catch { message = error.localizedDescription } }
    func loadMarkdown() async { guard let selection else { markdown = ""; return }; markdown = (try? await service?.skillMarkdown(skillID: selection)) ?? "" }
    func addLocal(_ url: URL) async { await perform(autoBackup: true) { _ = try await self.service?.addLocal(path: url.path); self.message = "Dodano skill z dysku" } }
    func addGit(_ url: String, subpath: String) async { await perform(autoBackup: true) { let urls = url.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; var count = 0; for item in urls { count += try await self.service?.addGitCollection(url: item, subpath: subpath.isEmpty ? nil : subpath).count ?? 0 }; self.message = "Zaimportowano \(count) skilli" } }
    func checkUpdates() async { isWorking = true; defer { isWorking = false }; do { updateAvailable = try await service?.checkUpdates() ?? []; hasCheckedUpdates = true; message = updateAvailable.isEmpty ? "Wszystkie skille są aktualne" : "Dostępne aktualizacje: \(updateAvailable.count)" } catch { message = error.localizedDescription } }
    func update(_ id: String) async { await perform(autoBackup: true) { _ = try await self.service?.update(skillID: id); self.updateAvailable.remove(id); self.message = "Zaktualizowano \(id)" } }
    func saveTags(_ id: String, text: String) async { await perform(autoBackup: true) { try await self.service?.setTags(skillID: id, tags: Self.csv(text)); self.message = "Zapisano tagi" } }
    func addTags(_ ids: Set<String>, text: String) async { await perform(autoBackup: true) { try await self.service?.addTags(skillIDs: Array(ids), tags: Self.csv(text)); self.message = "Dodano tagi do \(ids.count) skilli" } }
    func deleteSkill(_ id: String) async { await perform(autoBackup: true) { try await self.service?.deleteSkill(skillID: id); if self.selection == id { self.selection = nil; self.markdown = "" }; self.updateAvailable.remove(id); self.message = "Usunięto skill \(id)" } }
    func addProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async { await perform { if let created = try await self.service?.addProject(name: project.name, path: project.path, tools: project.tools) { try await self.service?.configureProject(id: created.id, skillIDs: project.skillIDs, tags: project.tags); try await self.service?.setMCPServers(projectID: created.id, serverIDs: serverIDs, tags: serverTags) }; self.message = "Dodano projekt \(project.name)" } }
    func addProjects(_ projects: [Project], serverIDs: [UUID], serverTags: [String]) async { await perform { for project in projects { if let created = try await self.service?.addProject(name: project.name, path: project.path, tools: project.tools) { try await self.service?.configureProject(id: created.id, skillIDs: project.skillIDs, tags: project.tags); try await self.service?.setMCPServers(projectID: created.id, serverIDs: serverIDs, tags: serverTags) } }; self.message = "Dodano projekty: \(projects.count)" } }
    func updateProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async { await perform { try await self.service?.updateProject(project); try await self.service?.setMCPServers(projectID: project.id, serverIDs: serverIDs, tags: serverTags); try await self.service?.setMCPPresets(projectID: project.id, presetIDs: []); self.message = "Zapisano projekt" } }
    func selectedMCPServerIDs(for project: Project) -> [UUID] { let direct = modelServerIDs(project.id); let legacyPresetIDs = Set(mcp.projectPresetIDs[project.id.uuidString] ?? []); let legacy = mcp.presets.filter { legacyPresetIDs.contains($0.id) }.flatMap(\.serverIDs); return Array(Set(direct + legacy)) }
    private func modelServerIDs(_ projectID: UUID) -> [UUID] { mcp.projectServerIDs?[projectID.uuidString] ?? [] }
    func deleteProject(_ project: Project) async { await perform { try await self.service?.deleteProject(id: project.id); self.message = "Usunięto projekt \(project.name) z Agentbox" } }
    func sync(_ project: Project) async { await perform { _ = try await self.service?.syncProject(id: project.id); self.message = "Zsynchronizowano \(project.name)" } }
    func loadBackupStatus() async { backupStatus = (try? await service?.backupStatus()) ?? "Nie można odczytać statusu." }
    func backup(remote: String) async { await perform { self.message = try await self.service?.backup(remote: remote.isEmpty ? nil : remote) ?? "Gotowe" }; await loadBackupStatus() }
    func loadRecovery() async { do { librarySnapshots = try await service?.librarySnapshots() ?? []; projectBackups = try await service?.projectSyncBackups() ?? [] } catch { reportError(error) } }
    func restoreLibrary(_ snapshot: LibrarySnapshot) async { await perform { let files = try await self.service?.restoreLibrarySnapshot(named: snapshot.name) ?? []; self.message = "Przywrócono snapshot biblioteki: \(files.joined(separator: ", "))" }; await loadRecovery() }
    func restoreProject(_ backup: ProjectSyncBackup) async { await perform { let targets = try await self.service?.restoreProjectSyncBackup(projectID: backup.projectID, named: backup.name) ?? []; self.message = "Przywrócono \(targets.count) elementów projektu \(backup.projectName)" }; await loadRecovery() }
    func saveMCPServer(_ server: MCPServer) async { await perform(autoBackup: true) { try await self.service?.saveMCPServer(server); self.message = "Zapisano serwer MCP" } }
    func deleteMCPServer(_ id: UUID) async { await perform(autoBackup: true) { try await self.service?.deleteMCPServer(id: id); self.message = "Usunięto serwer MCP" } }
    func previewMCP(_ project: Project) async throws -> [MCPPreview] { try await service?.previewMCP(projectID: project.id) ?? [] }
    func syncMCP(_ project: Project) async { await perform { _ = try await self.service?.syncMCP(projectID: project.id); self.message = "Zsynchronizowano MCP dla \(project.name)" } }
    func previewProjectSync(_ project: Project) async throws -> ProjectSyncPreview { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.previewProjectSync(projectID: project.id) }
    func syncEverything(_ project: Project) async { await perform { _ = try await self.service?.syncProjectTransaction(projectID: project.id); self.message = "Zsynchronizowano skille i MCP dla \(project.name)" } }
    func analyzeMCP(_ text: String) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.analyzeMCPJSON(text) }
    func importMCP(_ text: String, serverNames: Set<String>, classifications: [String: MCPValueClassification]) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text, serverNames: serverNames, classifications: classifications); await reload(); scheduleAutomaticBackup(); message = "Zaimportowano \(result.servers.count) serwerów MCP"; record(.success, message); return result }
    func generateMCP(_ instructions: String, settings: MCPAISettings, key: String?) async throws -> String { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; try await service.saveMCPAISettings(settings, apiKey: key); return try await service.generateMCPConfiguration(instructions: instructions, settings: settings) }
    func saveAISettings(_ settings: MCPAISettings, key: String?) async { await perform { try await self.service?.saveMCPAISettings(settings, apiKey: key); self.message = key?.isEmpty == false ? "Zapisano ustawienia AI i klucz API" : "Zapisano ustawienia AI" } }
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
        NavigationSplitView { List(SectionKind.allCases, selection: $section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }.navigationTitle("Agentbox").navigationSplitViewColumnWidth(min: 180, ideal: 210) } detail: {
            Group { switch section ?? .library { case .library: LibraryView(model: model, showGit: $showGit); case .projects: ProjectsView(model: model, showProject: $showProject); case .mcp: MCPView(model: model); case .backup: BackupView(model: model); case .recovery: RecoveryView(model: model); case .settings: SettingsView(model: model, updater: updater) } }
        }
        .overlay(alignment: .bottom) { if !model.message.isEmpty { StatusToast(text: model.message) { model.message = "" } } }
        .task(id: model.message) { let current = model.message; guard !current.isEmpty else { return }; try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, model.message == current else { return }; withAnimation { model.message = "" } }
        .overlay { if model.isWorking { ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .sheet(isPresented: $showGit) { AddGitView { url, path in Task { await model.addGit(url, subpath: path) } } }
        .sheet(isPresented: $showProject) { ProjectEditor(skills: model.skills, servers: model.mcp.servers, project: nil, selectedServerIDs: [], selectedServerTags: []) { project, servers, tags in Task { await model.addProject(project, serverIDs: servers, serverTags: tags) } } }
        .sheet(isPresented: $showHistory) { OperationHistoryView(entries: model.operationLog) }
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
    @State private var search = ""
    @State private var selectedTag = ""
    @State private var sort: SkillSort = .name
    @State private var grouping: SkillGrouping = .repository
    @State private var checked = Set<String>()
    @State private var expanded = Set<String>()
    @State private var showBatchTags = false
    var tags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    var filtered: [Skill] {
        var result = model.skills.filter { (selectedTag.isEmpty || $0.tags.contains(selectedTag)) && (search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }) }
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
            HStack { Picker("Tag", selection: $selectedTag) { Text("Wszystkie tagi").tag(""); ForEach(tags, id: \.self) { Text("#\($0)").tag($0) } }.labelsHidden().frame(maxWidth: 165); Picker("Grupowanie", selection: $grouping) { ForEach(SkillGrouping.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: 145); Picker("Sortowanie", selection: $sort) { ForEach(SkillSort.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: 115); Menu { Button("Rozwiń wszystko") { expanded = Set(groups.map(\.name)) }; Button("Zwiń wszystko") { expanded.removeAll() } } label: { Image(systemName: "rectangle.expand.vertical") }; Button { Task { await model.checkUpdates() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sprawdź aktualizacje"); Spacer(); if !checked.isEmpty { Text("Wybrano: \(checked.count)").font(.caption).foregroundStyle(.secondary) } }.padding(10).background(.bar)
            List { ForEach(groups, id: \.name) { group in DisclosureGroup(isExpanded: groupExpansion(group.name)) { ForEach(group.skills) { skill in HStack(alignment: .top, spacing: 9) { Toggle("", isOn: checkBinding(skill.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5); SkillRow(skill: skill, updateAvailable: model.updateAvailable.contains(skill.id)) }.contentShape(Rectangle()).onTapGesture { model.selection = skill.id; Task { await model.loadMarkdown() } }.listRowBackground(model.selection == skill.id ? Color.accentColor.opacity(0.13) : Color.clear) } } label: { HStack { Toggle("", isOn: groupCheckBinding(group.skills)).labelsHidden().toggleStyle(.checkbox); Image(systemName: grouping == .repository ? "shippingbox" : grouping == .tag ? "tag" : grouping == .source ? "tray.full" : "square.grid.2x2").foregroundStyle(.tint); Text(group.name).fontWeight(.semibold); Text("\(group.skills.count)").font(.caption).foregroundStyle(.secondary); Spacer(); let updates = group.skills.filter { model.updateAvailable.contains($0.id) }.count; if updates > 0 { Label("\(updates)", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.orange) } } } } }.searchable(text: $search, prompt: "Nazwa lub tag")
            Divider(); HStack { Button { chooseSkill() } label: { Label("Z dysku", systemImage: "folder.badge.plus") }; Button { showGit = true } label: { Label("Z Git", systemImage: "arrow.down.circle") }; if !checked.isEmpty { Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent); Button("Wyczyść") { checked.removeAll() } }; Spacer(); Text("\(filtered.count) z \(model.skills.count)").foregroundStyle(.secondary) }.padding(12)
        }.frame(minWidth: 410, idealWidth: 480)
        if let id = model.selection, let skill = model.skills.first(where: { $0.id == id }) { SkillDetail(model: model, skill: skill) } else { ContentUnavailableView("Wybierz skill", systemImage: "text.book.closed") }
    }.navigationTitle("Biblioteka").sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: tags) { text in Task { await model.addTags(checked, text: text); checked.removeAll() } } } }
    private func checkBinding(_ id: String) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
    private func groupCheckBinding(_ skills: [Skill]) -> Binding<Bool> { let ids = Set(skills.map(\.id)); return Binding(get: { !ids.isEmpty && ids.isSubset(of: checked) }, set: { if $0 { checked.formUnion(ids) } else { checked.subtract(ids) } }) }
    private func groupExpansion(_ name: String) -> Binding<Bool> { Binding(get: { !search.isEmpty || expanded.contains(name) || grouping == .none }, set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } }) }
    private func chooseSkill() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { Task { await model.addLocal(url) } } }
}

struct SkillRow: View { let skill: Skill; let updateAvailable: Bool; var body: some View { VStack(alignment: .leading, spacing: 7) { HStack { Image(systemName: skill.source.kind == .git ? "network" : "internaldrive").foregroundStyle(.tint); Text(skill.name).fontWeight(.medium); Spacer(); if updateAvailable { Label("Aktualizacja", systemImage: "arrow.down.circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(.orange) } }; if skill.tags.isEmpty { Text("bez tagów").font(.caption).foregroundStyle(.tertiary) } else { FlowTags(tags: skill.tags) } }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading) } }

struct FlowTags: View { let tags: [String]; var body: some View { HStack(spacing: 5) { ForEach(tags.prefix(4), id: \.self) { TagPill(tag: $0) }; if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption2).foregroundStyle(.secondary) } } } }
struct TagPill: View { let tag: String; private var color: Color { let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo]; let value = tag.unicodeScalars.reduce(0) { $0 + Int($1.value) }; return colors[value % colors.count] }; var body: some View { Text("#\(tag)").font(.caption2.weight(.medium)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule()) } }

struct SkillDetail: View {
    @ObservedObject var model: AppModel; let skill: Skill; @State private var tags = ""; @State private var confirmDelete = false
    var body: some View { VStack(alignment: .leading, spacing: 0) { VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text(skill.name).font(.title2.bold()); Text(skill.source.location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if model.updateAvailable.contains(skill.id) { Button("Aktualizuj") { Task { await model.update(skill.id) } }.buttonStyle(.borderedProminent).tint(.orange) } else if model.hasCheckedUpdates && skill.source.kind == .git { Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }; Button("Usuń", role: .destructive) { confirmDelete = true } }; HStack { TextField("tagi, oddzielone przecinkami", text: $tags).textFieldStyle(.roundedBorder); ExistingTagMenu(tags: Array(Set(model.skills.flatMap(\.tags))).sorted(), text: $tags); Button("Zapisz tagi") { Task { await model.saveTags(skill.id, text: tags) } } }.padding(.top, 2) }.padding(); Divider(); ScrollView { Text(model.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() } }.onAppear { tags = skill.tags.joined(separator: ", ") }.onChange(of: skill.id) { tags = skill.tags.joined(separator: ", ") }.confirmationDialog("Usunąć skill \(skill.name)?", isPresented: $confirmDelete) { Button("Usuń skill", role: .destructive) { Task { await model.deleteSkill(skill.id) } }; Button("Anuluj", role: .cancel) {} } message: { Text("Skill zostanie usunięty z biblioteki i przypisań projektów. Zniknie z folderów projektów przy kolejnej synchronizacji.") } }
}

struct ProjectsView: View {
    @ObservedObject var model: AppModel; @Binding var showProject: Bool; @State private var showBatch = false; @State private var editing: Project?; @State private var previewProject: Project?; @State private var deleting: Project?
    var body: some View { VStack(spacing: 0) { if model.projects.isEmpty { ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode.")) } else { List(model.projects) { project in VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text(project.name).font(.headline); Text(project.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edytuj") { editing = project }; Button("Usuń", role: .destructive) { deleting = project }; Button("Synchronizuj wszystko") { previewProject = project }.buttonStyle(.borderedProminent) }; HStack { ForEach(project.tools, id: \.self) { Text($0.rawValue).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) }; ForEach(project.tags, id: \.self) { TagPill(tag: $0) } } }.padding(.vertical, 7) } }; Divider(); HStack { Button { showProject = true } label: { Label("Dodaj projekt", systemImage: "plus") }; Button { showBatch = true } label: { Label("Dodaj wiele", systemImage: "folder.badge.plus") }; Spacer() }.padding(12) }.navigationTitle("Projekty")
        .sheet(isPresented: $showBatch) { BatchProjectView(skills: model.skills, servers: model.mcp.servers, existingProjects: model.projects) { projects, servers, tags in Task { await model.addProjects(projects, serverIDs: servers, serverTags: tags) } } }
        .sheet(item: $editing) { project in ProjectEditor(skills: model.skills, servers: model.mcp.servers, project: project, selectedServerIDs: model.selectedMCPServerIDs(for: project), selectedServerTags: model.mcp.projectServerTags?[project.id.uuidString] ?? []) { updated, servers, tags in Task { await model.updateProject(updated, serverIDs: servers, serverTags: tags) } } }
        .sheet(item: $previewProject) { project in MCPPreviewView(model: model, project: project) }
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("Usuń projekt", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting) } }; deleting = nil }; Button("Anuluj", role: .cancel) { deleting = nil } } message: { Text("Folder projektu i jego pliki pozostaną na dysku.") }
    }
}

struct MCPView: View {
    @ObservedObject var model: AppModel
    @State private var editingServer: MCPServer?
    @State private var serverToDelete: MCPServer?
    @State private var showImport = false
    var body: some View { VStack(spacing: 0) { List {
        Section("Serwery") { ForEach(model.mcp.servers) { server in HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe").foregroundStyle(.tint); VStack(alignment: .leading, spacing: 5) { HStack { Text(server.name).fontWeight(.medium); Text(server.transport == .stdio ? "Lokalny" : "HTTP").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background((server.transport == .stdio ? Color.blue : Color.green).opacity(0.14), in: Capsule()); ForEach(server.tags ?? [], id: \.self) { TagPill(tag: $0) } }; let secretCount = (server.secretEnvironment?.count ?? 0) + (server.secretHeaders?.count ?? 0); Text("\(server.arguments.count) argumentów · \((server.environment.count) + (server.literalEnvironment?.count ?? 0) + (server.secretEnvironment?.count ?? 0)) zmiennych\(secretCount > 0 ? " · \(secretCount) sekretów lokalnych" : "")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Szczegóły") { editingServer = server }; Button(role: .destructive) { serverToDelete = server } label: { Image(systemName: "trash") } } } }
    }; Divider(); HStack { Button { showImport = true } label: { Label("Importuj lub użyj AI", systemImage: "sparkles") }.buttonStyle(.borderedProminent); Button { editingServer = MCPServer(name: "", transport: .stdio) } label: { Label("Nowy serwer", systemImage: "plus") }; Spacer() }.padding(12) }.navigationTitle("MCP")
        .sheet(isPresented: $showImport) { MCPImportView(model: model) }
        .sheet(item: $editingServer) { server in MCPServerEditor(server: server, existingTags: Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted()) { value in Task { await model.saveMCPServer(value) } } }
        .confirmationDialog("Usunąć serwer \(serverToDelete?.name ?? "")?", isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })) { Button("Usuń", role: .destructive) { if let serverToDelete { Task { await model.deleteMCPServer(serverToDelete.id) } }; serverToDelete = nil }; Button("Anuluj", role: .cancel) { serverToDelete = nil } } message: { Text("Serwer zostanie usunięty także z bezpośrednich przypisań projektów.") }
    }
}

struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: MCPServer; let existingTags: [String]; let onSave: (MCPServer) -> Void
    @State private var name: String; @State private var transport: MCPTransport; @State private var command: String; @State private var arguments: String; @State private var url: String; @State private var environment: String; @State private var headers: String; @State private var enabled: Bool; @State private var tags: String
    init(server: MCPServer, existingTags: [String], onSave: @escaping (MCPServer) -> Void) { original = server; self.existingTags = existingTags; self.onSave = onSave; _name = State(initialValue: server.name); _transport = State(initialValue: server.transport); _command = State(initialValue: server.command); _arguments = State(initialValue: server.arguments.joined(separator: "\n")); _url = State(initialValue: server.url); _environment = State(initialValue: Self.format(server.environment)); _headers = State(initialValue: Self.format(server.headers)); _enabled = State(initialValue: server.enabled); _tags = State(initialValue: (server.tags ?? []).joined(separator: ", ")) }
    var body: some View { Form { Text("Serwer MCP").font(.title2.bold()); TextField("Nazwa techniczna", text: $name); HStack { TextField("Tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }; Picker("Transport", selection: $transport) { Text("Lokalny STDIO").tag(MCPTransport.stdio); Text("Zdalny HTTP").tag(MCPTransport.http) }.pickerStyle(.segmented); if transport == .stdio { TextField("Polecenie, np. npx", text: $command); Text("Argumenty — jeden na linię").font(.caption).foregroundStyle(.secondary); TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 90); Text("Zmienne: NAZWA=NAZWA, jedna na linię (Codex wymaga identycznych nazw)").font(.caption).foregroundStyle(.secondary); TextEditor(text: $environment).font(.system(.body, design: .monospaced)).frame(height: 70) } else { TextField("URL", text: $url); Text("Nagłówki: Header=SOURCE_ENV, np. Authorization=GITHUB_TOKEN").font(.caption).foregroundStyle(.secondary); TextEditor(text: $headers).font(.system(.body, design: .monospaced)).frame(height: 80) }; Toggle("Włączony", isOn: $enabled); let stored = (original.secretEnvironment?.count ?? 0) + (original.secretHeaders?.count ?? 0); if stored > 0 { Label("Ten serwer ma \(stored) lokalnych sekretów. Edycja nie zmienia ich wartości.", systemImage: "lock.doc").font(.caption).foregroundStyle(.orange) }; Text("Pola powyżej służą do odwołań do zmiennych systemowych. Sekrety z importu są w lokalnym mcp-secrets.json.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { onSave(MCPServer(id: original.id, name: name, transport: transport, command: command, arguments: arguments.split(whereSeparator: \.isNewline).map(String.init), url: url, environment: Self.parse(environment), headers: Self.parse(headers), enabled: enabled, literalEnvironment: original.literalEnvironment, literalHeaders: original.literalHeaders, secretEnvironment: original.secretEnvironment, secretHeaders: original.secretHeaders, group: original.group, profile: original.profile, tags: AppModel.csv(tags))); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || (transport == .stdio ? command.isEmpty : url.isEmpty)) } }.padding(24).frame(width: 620, height: 630) }
    private static func parse(_ text: String) -> [String: String] { var result: [String: String] = [:]; for line in text.split(whereSeparator: \.isNewline) { let parts = line.split(separator: "=", maxSplits: 1).map(String.init); if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) } }; return result }
    private static func format(_ values: [String: String]) -> String { values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }
}

struct MCPImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var source = ""
    @State private var summary: MCPImportSummary?
    @State private var error = ""
    @State private var useAI = false
    @State private var provider: MCPAIProvider = .openAI
    @State private var openAIModel = "gpt-5.6"
    @State private var claudeModel = "claude-sonnet-5"
    @State private var apiKey = ""
    @State private var working = false
    @State private var selected = Set<String>()
    @State private var classifications: [String: MCPValueClassification] = [:]
    var body: some View { VStack(alignment: .leading, spacing: 0) { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text("Import konfiguracji MCP").font(.title2.bold())
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
    }.frame(width: 760, height: 680).onAppear { if let settings = model.mcp.aiSettings { provider = settings.provider; openAIModel = settings.openAIModel; claudeModel = settings.claudeModel } } }
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
            if preview?.mcp.contains(where: { $0.file.hasSuffix(".jsonc") }) == true { Label("Plik OpenCode JSONC zostanie przepisany jako JSON. Komentarze i dotychczasowe formatowanie zostaną usunięte; kopia powstanie w .skillbox/mcp-backups.", systemImage: "text.badge.xmark").font(.caption).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if preview == nil { ProgressView() }
            else if let preview { ScrollView { VStack(alignment: .leading, spacing: 12) {
                Text("Skille").font(.headline)
                ForEach(preview.skills, id: \.tool) { item in GroupBox { VStack(alignment: .leading, spacing: 6) { Text(item.target).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed) }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "folder") } }
                Text("MCP").font(.headline).padding(.top, 4)
                ForEach(preview.mcp, id: \.tool.rawValue) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); DisclosureGroup("Podgląd pliku") { Text(item.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) } }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "doc.text") } }
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
    @AppStorage("AgentboxAutoBackup") private var autoBackup = true
    @AppStorage("AgentboxAutoPush") private var autoPush = false
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Label("Backup Git", systemImage: "externaldrive.badge.timemachine").font(.largeTitle.bold())
        Text("Do Git trafiają skille, tagi i konfiguracja MCP bez sekretów. Lokalne ścieżki projektów pozostają tylko na tym Macu.").foregroundStyle(.secondary)
        GroupBox("Automatyzacja") { VStack(alignment: .leading, spacing: 10) { Toggle("Automatycznie twórz lokalne commity", isOn: $autoBackup); Toggle("Automatycznie wysyłaj do origin", isOn: $autoPush).disabled(!autoBackup); Text("Zmiany skilli, tagów i serwerów są łączone przez 5 sekund w jeden commit. Pierwszy backup i konfigurację origin wykonaj ręcznie.").font(.caption).foregroundStyle(.secondary) }.padding(8) }
        TextField("Git remote, np. git@github.com:user/agentbox-backup.git", text: $remote).textFieldStyle(.roundedBorder)
        HStack { Button("Odśwież status") { Task { await model.loadBackupStatus() } }; Button("Wykonaj backup teraz") { Task { await model.backup(remote: remote) } }.buttonStyle(.borderedProminent) }
        GroupBox("Status") { Text(model.backupStatus.isEmpty ? "Kliknij „Odśwież status”." : model.backupStatus).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
        Spacer()
    }.padding(28).navigationTitle("Backup").task { await model.loadBackupStatus() } }
}

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    @State private var snapshotToRestore: LibrarySnapshot?
    @State private var projectBackupToRestore: ProjectSyncBackup?
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .medium; return value }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Odzyskiwanie", systemImage: "clock.arrow.circlepath").font(.largeTitle.bold()); Spacer(); Button("Odśwież") { Task { await model.loadRecovery() } } }
            Text("Przywrócenie tworzy najpierw kopię aktualnego stanu, więc można cofnąć również samą operację odzyskiwania.").foregroundStyle(.secondary)
            List {
                Section("Snapshoty biblioteki") {
                    if model.librarySnapshots.isEmpty { Text("Brak snapshotów biblioteki.").foregroundStyle(.secondary) }
                    ForEach(model.librarySnapshots) { snapshot in HStack { Image(systemName: "externaldrive").foregroundStyle(.blue); VStack(alignment: .leading, spacing: 3) { Text(formatter.string(from: snapshot.date)).fontWeight(.medium); Text(snapshot.files.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Przywróć") { snapshotToRestore = snapshot }.buttonStyle(.bordered) } }
                }
                Section("Backupy synchronizacji projektów") {
                    if model.projectBackups.isEmpty { Text("Brak backupów z metadanymi. Pojawią się po kolejnej synchronizacji projektu.").foregroundStyle(.secondary) }
                    ForEach(model.projectBackups) { backup in HStack(alignment: .top) { Image(systemName: "folder.badge.clock").foregroundStyle(.purple); VStack(alignment: .leading, spacing: 3) { Text(backup.projectName).fontWeight(.medium); Text(formatter.string(from: backup.date)).font(.caption).foregroundStyle(.secondary); DisclosureGroup("\(backup.targets.count) elementów") { ForEach(backup.targets, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } } }; Spacer(); Button("Przywróć") { projectBackupToRestore = backup }.buttonStyle(.bordered) } }
                }
            }
        }
        .padding(24).navigationTitle("Odzyskiwanie").task { await model.loadRecovery() }
        .confirmationDialog("Przywrócić snapshot biblioteki?", isPresented: Binding(get: { snapshotToRestore != nil }, set: { if !$0 { snapshotToRestore = nil } })) {
            Button("Przywróć bibliotekę", role: .destructive) { if let snapshotToRestore { Task { await model.restoreLibrary(snapshotToRestore) } }; snapshotToRestore = nil }
            Button("Anuluj", role: .cancel) { snapshotToRestore = nil }
        } message: { Text("Aktualny stan zostanie zachowany jako nowy snapshot. Sekrety i katalog skills nie zostaną zmienione.") }
        .confirmationDialog("Cofnąć synchronizację projektu?", isPresented: Binding(get: { projectBackupToRestore != nil }, set: { if !$0 { projectBackupToRestore = nil } })) {
            Button("Przywróć projekt", role: .destructive) { if let projectBackupToRestore { Task { await model.restoreProject(projectBackupToRestore) } }; projectBackupToRestore = nil }
            Button("Anuluj", role: .cancel) { projectBackupToRestore = nil }
        } message: { Text("Zarządzane katalogi skilli, pliki MCP i manifest zostaną przywrócone. Przed zmianą powstanie backup aktualnego stanu.") }
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
        HStack { Text("Wersja \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Sprawdź teraz") { model.check() }.disabled(!model.canCheckForUpdates) }
        Text("Aktualizacje są pobierane z GitHub Releases i weryfikowane podpisem EdDSA przed instalacją.").font(.caption).foregroundStyle(.secondary)
    }.padding(8) } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @State private var openAIModel = "gpt-5.6"
    @State private var anthropicModel = "claude-sonnet-5"
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Label("Ustawienia", systemImage: "gearshape").font(.largeTitle.bold())
            UpdateSettingsCard(updater: updater)
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

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let servers: [MCPServer]
    let project: Project?
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
    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { Text(project == nil ? "Nowy projekt" : "Edytuj projekt").font(.title2.bold()); TextField("Nazwa", text: $name); HStack { TextField("Folder projektu", text: $path); Button("Wybierz…") { chooseFolder() } }; GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: toolBinding(tool)).toggleStyle(.checkbox) } }.padding(6) }; GroupBox("Pojedyncze skille") { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(skills) { skill in Toggle(skill.name, isOn: skillBinding(skill.id)).toggleStyle(.checkbox) } }.padding(6) }.frame(height: 150) }; GroupBox("Tagi skilli") { tagGrid(availableTags, selection: $selectedTags) }; GroupBox("Pojedyncze serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(servers) { server in Toggle(server.name, isOn: serverBinding(server.id)).toggleStyle(.checkbox) } }.padding(6) }; GroupBox("Tagi MCP") { tagGrid(mcpTags, selection: $selectedMCPtags) }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { onSave(Project(id: project?.id ?? UUID(), name: name, path: path, tools: Array(tools), skillIDs: Array(selected), tags: Array(selectedTags).sorted()), Array(selectedServers), Array(selectedMCPtags).sorted()); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || path.isEmpty || tools.isEmpty) } }.padding(24) }.frame(width: 700, height: 820).onAppear { selectedServers = Set(selectedServerIDs); selectedMCPtags = Set(selectedServerTags); if let project { name = project.name; path = project.path; tools = Set(project.tools); selected = Set(project.skillIDs); selectedTags = Set(project.tags) } } }
    private func toolBinding(_ tool: Tool) -> Binding<Bool> { Binding(get: { tools.contains(tool) }, set: { if $0 { tools.insert(tool) } else { tools.remove(tool) } }) }
    private func skillBinding(_ id: String) -> Binding<Bool> { Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } }) }
    private func serverBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { selectedServers.contains(id) }, set: { if $0 { selectedServers.insert(id) } else { selectedServers.remove(id) } }) }
    private func tagGrid(_ tags: [String], selection: Binding<Set<String>>) -> some View { Group { if tags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) } else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(tags, id: \.self) { tag in Toggle("#\(tag)", isOn: Binding(get: { selection.wrappedValue.contains(tag) }, set: { if $0 { selection.wrappedValue.insert(tag) } else { selection.wrappedValue.remove(tag) } })).toggleStyle(.checkbox) } }.padding(6) } } }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url?.path ?? path } }
}

struct BatchProjectView: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]; let servers: [MCPServer]; let existingProjects: [Project]
    let onSave: ([Project], [UUID], [String]) -> Void
    @State private var root = ""; @State private var folders: [URL] = []; @State private var selectedFolders = Set<String>()
    @State private var tools = Set(Tool.allCases); @State private var selectedSkills = Set<String>(); @State private var selectedTags = Set<String>(); @State private var selectedServers = Set<UUID>(); @State private var selectedMCPtags = Set<String>(); @State private var scanError = ""
    private var existingPaths: Set<String> { Set(existingProjects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) }
    private var availableFolders: [URL] { folders.filter { !existingPaths.contains($0.standardizedFileURL.path) } }
    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text("Dodaj wiele projektów").font(.title2.bold())
        Text("Każdy zaznaczony podfolder otrzyma kopię tych samych ustawień początkowych.").foregroundStyle(.secondary)
        HStack { TextField("Folder nadrzędny", text: $root); Button("Wybierz…") { chooseRoot() } }
        if !scanError.isEmpty { Label(scanError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        GroupBox("Podfoldery") { VStack(alignment: .leading, spacing: 7) {
            if folders.isEmpty { Text("Wybierz folder, aby znaleźć projekty.").foregroundStyle(.secondary) }
            else { HStack { Button("Zaznacz dostępne") { selectedFolders = Set(availableFolders.map(\.path)) }; Button("Wyczyść") { selectedFolders.removeAll() }; Spacer(); Text("Wybrano \(selectedFolders.count)").foregroundStyle(.secondary) }; ForEach(folders, id: \.path) { folder in let exists = existingPaths.contains(folder.standardizedFileURL.path); Toggle(isOn: folderBinding(folder)) { HStack { Image(systemName: "folder"); Text(folder.lastPathComponent); Spacer(); if exists { Text("już dodany").font(.caption).foregroundStyle(.secondary) } } }.toggleStyle(.checkbox).disabled(exists) } }
        }.padding(6) }.frame(maxHeight: 230)
        GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: $tools)).toggleStyle(.checkbox) } }.padding(6) }
        GroupBox("Pojedyncze skille") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading) { ForEach(skills) { skill in Toggle(skill.name, isOn: setBinding(skill.id, in: $selectedSkills)).toggleStyle(.checkbox) } }.padding(6) }
        GroupBox("Tagi dynamiczne") { if availableTags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) } else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(availableTags, id: \.self) { tag in Toggle("#\(tag)", isOn: setBinding(tag, in: $selectedTags)).toggleStyle(.checkbox) } }.padding(6) } }
        GroupBox("Pojedyncze serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading) { ForEach(servers) { server in Toggle(server.name, isOn: setBinding(server.id, in: $selectedServers)).toggleStyle(.checkbox) } }.padding(6) }
        GroupBox("Tagi MCP") { if mcpTags.isEmpty { Text("Brak tagów MCP.").foregroundStyle(.secondary).padding(6) } else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(mcpTags, id: \.self) { tag in Toggle("#\(tag)", isOn: setBinding(tag, in: $selectedMCPtags)).toggleStyle(.checkbox) } }.padding(6) } }
        HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj \(selectedFolders.count) projektów") { save(); dismiss() }.buttonStyle(.borderedProminent).disabled(selectedFolders.isEmpty || tools.isEmpty) }
    }.padding(24) }.frame(width: 760, height: 860) }
    private func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; guard panel.runModal() == .OK, let url = panel.url else { return }; root = url.path; do { folders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }; selectedFolders = Set(availableFolders.map(\.path)); scanError = "" } catch { folders = []; selectedFolders = []; scanError = error.localizedDescription } }
    private func folderBinding(_ folder: URL) -> Binding<Bool> { Binding(get: { selectedFolders.contains(folder.path) }, set: { if $0 { selectedFolders.insert(folder.path) } else { selectedFolders.remove(folder.path) } }) }
    private func setBinding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> { Binding(get: { set.wrappedValue.contains(value) }, set: { enabled in if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } }) }
    private func save() { let projects = availableFolders.filter { selectedFolders.contains($0.path) }.map { Project(name: $0.lastPathComponent, path: $0.path, tools: Array(tools), skillIDs: Array(selectedSkills), tags: Array(selectedTags).sorted()) }; onSave(projects, Array(selectedServers), Array(selectedMCPtags).sorted()) }
}

struct StatusToast: View { let text: String; let onClose: () -> Void; var body: some View { HStack(spacing: 10) { Label(text, systemImage: "info.circle.fill"); Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Zamknij") }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).shadow(radius: 8).padding(.bottom, 14) } }
