import SwiftUI
import AppKit
import SkillboxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); DispatchQueue.main.async { NSApp.windows.first?.makeKeyAndOrderFront(nil) } }
}

@main struct AgentboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1100, height: 720) }
}

enum SectionKind: String, CaseIterable, Identifiable {
    case library = "Biblioteka", projects = "Projekty", mcp = "MCP", backup = "Backup", settings = "Ustawienia"
    var id: String { rawValue }
    var icon: String { switch self { case .library: "square.grid.2x2"; case .projects: "folder"; case .mcp: "network"; case .backup: "externaldrive.badge.timemachine"; case .settings: "gearshape" } }
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
    func addProject(_ project: Project, presetIDs: [UUID], profiles: [String: UUID]) async { await perform { if let created = try await self.service?.addProject(name: project.name, path: project.path, tools: project.tools) { try await self.service?.configureProject(id: created.id, skillIDs: project.skillIDs, tags: project.tags); try await self.service?.setMCPPresets(projectID: created.id, presetIDs: presetIDs); try await self.service?.setMCPProfiles(projectID: created.id, selections: profiles) }; self.message = "Dodano projekt \(project.name)" } }
    func updateProject(_ project: Project, presetIDs: [UUID], profiles: [String: UUID]) async { await perform { try await self.service?.updateProject(project); try await self.service?.setMCPPresets(projectID: project.id, presetIDs: presetIDs); try await self.service?.setMCPProfiles(projectID: project.id, selections: profiles); self.message = "Zapisano projekt" } }
    func deleteProject(_ project: Project) async { await perform { try await self.service?.deleteProject(id: project.id); self.message = "Usunięto projekt \(project.name) z Agentbox" } }
    func sync(_ project: Project) async { await perform { _ = try await self.service?.syncProject(id: project.id); self.message = "Zsynchronizowano \(project.name)" } }
    func loadBackupStatus() async { backupStatus = (try? await service?.backupStatus()) ?? "Nie można odczytać statusu." }
    func backup(remote: String) async { await perform { self.message = try await self.service?.backup(remote: remote.isEmpty ? nil : remote) ?? "Gotowe" }; await loadBackupStatus() }
    func saveMCPServer(_ server: MCPServer) async { await perform(autoBackup: true) { try await self.service?.saveMCPServer(server); self.message = "Zapisano serwer MCP" } }
    func saveMCPPreset(_ preset: MCPPreset) async { await perform(autoBackup: true) { try await self.service?.saveMCPPreset(preset); self.message = "Zapisano preset MCP" } }
    func deleteMCPServer(_ id: UUID) async { await perform(autoBackup: true) { try await self.service?.deleteMCPServer(id: id); self.message = "Usunięto serwer MCP" } }
    func deleteMCPPreset(_ id: UUID) async { await perform(autoBackup: true) { try await self.service?.deleteMCPPreset(id: id); self.message = "Usunięto preset MCP" } }
    func previewMCP(_ project: Project) async throws -> [MCPPreview] { try await service?.previewMCP(projectID: project.id) ?? [] }
    func syncMCP(_ project: Project) async { await perform { _ = try await self.service?.syncMCP(projectID: project.id); self.message = "Zsynchronizowano MCP dla \(project.name)" } }
    func syncEverything(_ project: Project) async { await perform { _ = try await self.service?.syncProject(id: project.id); _ = try await self.service?.syncMCP(projectID: project.id); self.message = "Zsynchronizowano skille i MCP dla \(project.name)" } }
    func analyzeMCP(_ text: String) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; return try await service.analyzeMCPJSON(text) }
    func importMCP(_ text: String, serverNames: Set<String>) async throws -> MCPImportSummary { guard let service else { throw SkillboxError.commandFailed("Brak usługi") }; let result = try await service.importMCPJSON(text, serverNames: serverNames); await reload(); scheduleAutomaticBackup(); message = "Zaimportowano \(result.servers.count) serwerów MCP"; return result }
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
    private func perform(autoBackup: Bool = false, _ action: @escaping @MainActor () async throws -> Void) async { isWorking = true; defer { isWorking = false }; do { try await action(); await reload(); if autoBackup { scheduleAutomaticBackup() } } catch { await reload(); message = error.localizedDescription } }
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
    @StateObject private var model = AppModel(); @State private var section: SectionKind? = .library
    @State private var showGit = false
    @State private var showProject = false
    var body: some View {
        NavigationSplitView { List(SectionKind.allCases, selection: $section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }.navigationTitle("Agentbox").navigationSplitViewColumnWidth(min: 180, ideal: 210) } detail: {
            Group { switch section ?? .library { case .library: LibraryView(model: model, showGit: $showGit); case .projects: ProjectsView(model: model, showProject: $showProject); case .mcp: MCPView(model: model); case .backup: BackupView(model: model); case .settings: SettingsView(model: model) } }
        }
        .overlay(alignment: .bottom) { if !model.message.isEmpty { StatusToast(text: model.message) { model.message = "" } } }
        .task(id: model.message) { let current = model.message; guard !current.isEmpty else { return }; try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, model.message == current else { return }; withAnimation { model.message = "" } }
        .overlay { if model.isWorking { ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .sheet(isPresented: $showGit) { AddGitView { url, path in Task { await model.addGit(url, subpath: path) } } }
        .sheet(isPresented: $showProject) { ProjectEditor(skills: model.skills, presets: model.mcp.presets, servers: model.mcp.servers, project: nil, selectedPresetIDs: [], selectedProfiles: [:]) { project, presets, profiles in Task { await model.addProject(project, presetIDs: presets, profiles: profiles) } } }
    }
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
    }.navigationTitle("Biblioteka").sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count) { text in Task { await model.addTags(checked, text: text); checked.removeAll() } } } }
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
    var body: some View { VStack(alignment: .leading, spacing: 0) { VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text(skill.name).font(.title2.bold()); Text(skill.source.location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if model.updateAvailable.contains(skill.id) { Button("Aktualizuj") { Task { await model.update(skill.id) } }.buttonStyle(.borderedProminent).tint(.orange) } else if model.hasCheckedUpdates && skill.source.kind == .git { Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }; Button("Usuń", role: .destructive) { confirmDelete = true } }; HStack { TextField("tagi, oddzielone przecinkami", text: $tags).textFieldStyle(.roundedBorder); Button("Zapisz tagi") { Task { await model.saveTags(skill.id, text: tags) } } }.padding(.top, 2) }.padding(); Divider(); ScrollView { Text(model.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() } }.onAppear { tags = skill.tags.joined(separator: ", ") }.onChange(of: skill.id) { tags = skill.tags.joined(separator: ", ") }.confirmationDialog("Usunąć skill \(skill.name)?", isPresented: $confirmDelete) { Button("Usuń skill", role: .destructive) { Task { await model.deleteSkill(skill.id) } }; Button("Anuluj", role: .cancel) {} } message: { Text("Skill zostanie usunięty z biblioteki i przypisań projektów. Zniknie z folderów projektów przy kolejnej synchronizacji.") } }
}

struct ProjectsView: View {
    @ObservedObject var model: AppModel; @Binding var showProject: Bool; @State private var editing: Project?; @State private var previewProject: Project?; @State private var deleting: Project?
    var body: some View { VStack(spacing: 0) { if model.projects.isEmpty { ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode.")) } else { List(model.projects) { project in VStack(alignment: .leading, spacing: 10) { HStack { VStack(alignment: .leading) { Text(project.name).font(.headline); Text(project.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edytuj") { editing = project }; Button("Usuń", role: .destructive) { deleting = project }; Button("Synchronizuj wszystko") { previewProject = project }.buttonStyle(.borderedProminent) }; HStack { ForEach(project.tools, id: \.self) { Text($0.rawValue).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) }; ForEach(project.tags, id: \.self) { TagPill(tag: $0) } } }.padding(.vertical, 7) } }; Divider(); HStack { Button { showProject = true } label: { Label("Dodaj projekt", systemImage: "plus") }; Spacer() }.padding(12) }.navigationTitle("Projekty")
        .sheet(item: $editing) { project in ProjectEditor(skills: model.skills, presets: model.mcp.presets, servers: model.mcp.servers, project: project, selectedPresetIDs: model.mcp.projectPresetIDs[project.id.uuidString] ?? [], selectedProfiles: model.mcp.projectProfileSelections?[project.id.uuidString] ?? [:]) { updated, presets, profiles in Task { await model.updateProject(updated, presetIDs: presets, profiles: profiles) } } }
        .sheet(item: $previewProject) { project in MCPPreviewView(model: model, project: project) }
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("Usuń projekt", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting) } }; deleting = nil }; Button("Anuluj", role: .cancel) { deleting = nil } } message: { Text("Folder projektu i jego pliki pozostaną na dysku.") }
    }
}

struct MCPView: View {
    @ObservedObject var model: AppModel
    @State private var editingServer: MCPServer?
    @State private var editingPreset: MCPPreset?
    @State private var serverToDelete: MCPServer?
    @State private var presetToDelete: MCPPreset?
    @State private var showImport = false
    var body: some View { VStack(spacing: 0) { List {
        Section("Serwery") { ForEach(model.mcp.servers) { server in HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe").foregroundStyle(.tint); VStack(alignment: .leading, spacing: 5) { HStack { Text(server.name).fontWeight(.medium); Text(server.transport == .stdio ? "Lokalny" : "HTTP").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background((server.transport == .stdio ? Color.blue : Color.green).opacity(0.14), in: Capsule()); if let profile = server.profile { Text(profile).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2).background(Color.purple.opacity(0.14), in: Capsule()) } }; let secretCount = (server.secretEnvironment?.count ?? 0) + (server.secretHeaders?.count ?? 0); Text("\(server.arguments.count) argumentów · \((server.environment.count) + (server.literalEnvironment?.count ?? 0) + (server.secretEnvironment?.count ?? 0)) zmiennych\(secretCount > 0 ? " · \(secretCount) sekretów lokalnych" : "")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Szczegóły") { editingServer = server }; Button(role: .destructive) { serverToDelete = server } label: { Image(systemName: "trash") } } } }
        Section("Presety") { ForEach(model.mcp.presets) { preset in HStack { Image(systemName: "shippingbox").foregroundStyle(.purple); VStack(alignment: .leading) { Text(preset.name).fontWeight(.medium); Text("\(preset.serverIDs.count) serwerów").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edytuj") { editingPreset = preset }; Button("Usuń", role: .destructive) { presetToDelete = preset } } } }
    }; Divider(); HStack { Button { showImport = true } label: { Label("Importuj lub użyj AI", systemImage: "sparkles") }.buttonStyle(.borderedProminent); Button { editingServer = MCPServer(name: "", transport: .stdio) } label: { Label("Nowy serwer", systemImage: "plus") }; Button { editingPreset = MCPPreset(name: "") } label: { Label("Nowy preset", systemImage: "shippingbox") }; Spacer() }.padding(12) }.navigationTitle("MCP")
        .sheet(isPresented: $showImport) { MCPImportView(model: model) }
        .sheet(item: $editingServer) { server in MCPServerEditor(server: server) { value in Task { await model.saveMCPServer(value) } } }
        .sheet(item: $editingPreset) { preset in MCPPresetEditor(preset: preset, servers: model.mcp.servers) { value in Task { await model.saveMCPPreset(value) } } }
        .confirmationDialog("Usunąć serwer \(serverToDelete?.name ?? "")?", isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })) { Button("Usuń", role: .destructive) { if let serverToDelete { Task { await model.deleteMCPServer(serverToDelete.id) } }; serverToDelete = nil }; Button("Anuluj", role: .cancel) { serverToDelete = nil } } message: { Text("Serwer zostanie również usunięty ze wszystkich presetów.") }
        .confirmationDialog("Usunąć preset \(presetToDelete?.name ?? "")?", isPresented: Binding(get: { presetToDelete != nil }, set: { if !$0 { presetToDelete = nil } })) { Button("Usuń", role: .destructive) { if let presetToDelete { Task { await model.deleteMCPPreset(presetToDelete.id) } }; presetToDelete = nil }; Button("Anuluj", role: .cancel) { presetToDelete = nil } }
    }
}

struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: MCPServer; let onSave: (MCPServer) -> Void
    @State private var name: String; @State private var transport: MCPTransport; @State private var command: String; @State private var arguments: String; @State private var url: String; @State private var environment: String; @State private var headers: String; @State private var enabled: Bool
    init(server: MCPServer, onSave: @escaping (MCPServer) -> Void) { original = server; self.onSave = onSave; _name = State(initialValue: server.name); _transport = State(initialValue: server.transport); _command = State(initialValue: server.command); _arguments = State(initialValue: server.arguments.joined(separator: "\n")); _url = State(initialValue: server.url); _environment = State(initialValue: Self.format(server.environment)); _headers = State(initialValue: Self.format(server.headers)); _enabled = State(initialValue: server.enabled) }
    var body: some View { Form { Text("Serwer MCP").font(.title2.bold()); TextField("Nazwa techniczna", text: $name); Picker("Transport", selection: $transport) { Text("Lokalny STDIO").tag(MCPTransport.stdio); Text("Zdalny HTTP").tag(MCPTransport.http) }.pickerStyle(.segmented); if transport == .stdio { TextField("Polecenie, np. npx", text: $command); Text("Argumenty — jeden na linię").font(.caption).foregroundStyle(.secondary); TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 90); Text("Zmienne: NAZWA=NAZWA, jedna na linię (Codex wymaga identycznych nazw)").font(.caption).foregroundStyle(.secondary); TextEditor(text: $environment).font(.system(.body, design: .monospaced)).frame(height: 70) } else { TextField("URL", text: $url); Text("Nagłówki: Header=SOURCE_ENV, np. Authorization=GITHUB_TOKEN").font(.caption).foregroundStyle(.secondary); TextEditor(text: $headers).font(.system(.body, design: .monospaced)).frame(height: 80) }; Toggle("Włączony", isOn: $enabled); let stored = (original.secretEnvironment?.count ?? 0) + (original.secretHeaders?.count ?? 0); if stored > 0 { Label("Ten serwer ma \(stored) lokalnych sekretów. Edycja nie zmienia ich wartości.", systemImage: "lock.doc").font(.caption).foregroundStyle(.orange) }; Text("Pola powyżej służą do odwołań do zmiennych systemowych. Sekrety z importu są w lokalnym mcp-secrets.json.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { onSave(MCPServer(id: original.id, name: name, transport: transport, command: command, arguments: arguments.split(whereSeparator: \.isNewline).map(String.init), url: url, environment: Self.parse(environment), headers: Self.parse(headers), enabled: enabled, literalEnvironment: original.literalEnvironment, literalHeaders: original.literalHeaders, secretEnvironment: original.secretEnvironment, secretHeaders: original.secretHeaders, group: original.group, profile: original.profile)); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || (transport == .stdio ? command.isEmpty : url.isEmpty)) } }.padding(24).frame(width: 600, height: 590) }
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
        if let summary { GroupBox("Rozpoznano") { VStack(alignment: .leading, spacing: 8) { HStack { Text("\(summary.servers.count) serwerów · \(summary.stdioCount) lokalnych · \(summary.httpCount) HTTP · \(summary.secretCount) sekretów"); Spacer(); Button("Wszystkie") { selected = Set(summary.servers.map(\.name)) }.buttonStyle(.link); Button("Wyczyść") { selected.removeAll() }.buttonStyle(.link) }; if !summary.profileGroups.isEmpty { Text("Warianty: \(summary.profileGroups.joined(separator: ", "))").foregroundStyle(.purple) }; ForEach(summary.servers) { server in Toggle(isOn: Binding(get: { selected.contains(server.name) }, set: { if $0 { selected.insert(server.name) } else { selected.remove(server.name) } })) { HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe"); Text(server.name); Spacer(); if let profile = server.profile { Text(profile).font(.caption).foregroundStyle(.secondary) } } }.toggleStyle(.checkbox) } }.padding(6).frame(maxWidth: .infinity, alignment: .leading) } }
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }.padding(24) }; Divider(); HStack { if working { ProgressView() }; if summary != nil { Text("Wybrano: \(selected.count)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Anuluj") { dismiss() }; Button(useAI ? "Przygotuj z AI" : "Analizuj") { Task { await prepare() } }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working); Button("Importuj wybrane") { Task { await importNow() } }.buttonStyle(.borderedProminent).disabled(summary == nil || selected.isEmpty || working) }.padding(16).background(.bar)
    }.frame(width: 760, height: 680).onAppear { if let settings = model.mcp.aiSettings { provider = settings.provider; openAIModel = settings.openAIModel; claudeModel = settings.claudeModel } } }
    private func prepare() async { working = true; error = ""; summary = nil; selected.removeAll(); defer { working = false }; do { if useAI { let settings = MCPAISettings(provider: provider, openAIModel: openAIModel, claudeModel: claudeModel); source = try await model.generateMCP(source, settings: settings, key: apiKey.isEmpty ? nil : apiKey) }; let analyzed = try await model.analyzeMCP(source); summary = analyzed; selected = Set(analyzed.servers.map(\.name)) } catch { self.error = error.localizedDescription } }
    private func importNow() async { working = true; error = ""; defer { working = false }; do { _ = try await model.importMCP(source, serverNames: selected); dismiss() } catch { self.error = error.localizedDescription } }
    private func chooseFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.canChooseFiles = true; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { do { source = try String(contentsOf: url, encoding: .utf8); summary = nil } catch { self.error = error.localizedDescription } } }
}

struct MCPPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: MCPPreset, servers: [MCPServer], onSave: (MCPPreset) -> Void
    @State private var name: String; @State private var selected: Set<UUID>
    init(preset: MCPPreset, servers: [MCPServer], onSave: @escaping (MCPPreset) -> Void) { original = preset; self.servers = servers; self.onSave = onSave; _name = State(initialValue: preset.name); _selected = State(initialValue: Set(preset.serverIDs)) }
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Preset MCP").font(.title2.bold()); TextField("Nazwa presetu", text: $name); GroupBox("Serwery") { VStack(alignment: .leading) { ForEach(servers) { server in Toggle(server.name, isOn: binding(server.id)).toggleStyle(.checkbox) } }.padding(8).frame(maxWidth: .infinity, alignment: .leading) }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { onSave(MCPPreset(id: original.id, name: name, serverIDs: Array(selected))); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty) } }.padding(24).frame(width: 480) }
    private func binding(_ id: UUID) -> Binding<Bool> { Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } }) }
}

struct MCPPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel; let project: Project
    @State private var previews: [MCPPreview] = []; @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja · \(project.name)").font(.title2.bold())
            Text("Skille zostaną zsynchronizowane po zatwierdzeniu poniższych konfiguracji MCP.").font(.caption).foregroundStyle(.secondary)
            Label("Pliki projektu mogą zawierać jawne sekrety. Agentbox doda je do lokalnego .git/info/exclude, ale nie szyfruje ich na dysku.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if previews.contains(where: { $0.file.hasSuffix(".jsonc") }) { Label("Plik OpenCode JSONC zostanie przepisany jako JSON. Komentarze i dotychczasowe formatowanie zostaną usunięte; kopia powstanie w .skillbox/mcp-backups.", systemImage: "text.badge.xmark").font(.caption).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if previews.isEmpty { ProgressView() }
            else { ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(previews, id: \.tool.rawValue) { preview in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(preview.file).font(.caption).foregroundStyle(.secondary); HStack { ForEach(preview.added, id: \.self) { Text("+ \($0)").foregroundStyle(.green) }; ForEach(preview.removed, id: \.self) { Text("− \($0)").foregroundStyle(.orange) } }; DisclosureGroup("Podgląd pliku") { Text(preview.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) } }.padding(7) } label: { Label(preview.tool.rawValue.capitalized, systemImage: "doc.text") } } } } }
            HStack { Spacer(); Button("Zamknij") { dismiss() }; Button("Synchronizuj skille i MCP") { Task { await model.syncEverything(project); dismiss() } }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || previews.isEmpty) }
        }.padding(24).frame(width: 780, height: 650).task { do { previews = try await model.previewMCP(project) } catch { self.error = error.localizedDescription } }
    }
}

struct BackupView: View {
    @ObservedObject var model: AppModel
    @State private var remote = ""
    @AppStorage("AgentboxAutoBackup") private var autoBackup = true
    @AppStorage("AgentboxAutoPush") private var autoPush = false
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Label("Backup Git", systemImage: "externaldrive.badge.timemachine").font(.largeTitle.bold())
        Text("Do Git trafiają skille, tagi i konfiguracja MCP bez sekretów. Lokalne ścieżki projektów pozostają tylko na tym Macu.").foregroundStyle(.secondary)
        GroupBox("Automatyzacja") { VStack(alignment: .leading, spacing: 10) { Toggle("Automatycznie twórz lokalne commity", isOn: $autoBackup); Toggle("Automatycznie wysyłaj do origin", isOn: $autoPush).disabled(!autoBackup); Text("Zmiany skilli, tagów, serwerów i presetów są łączone przez 5 sekund w jeden commit. Pierwszy backup i konfigurację origin wykonaj ręcznie.").font(.caption).foregroundStyle(.secondary) }.padding(8) }
        TextField("Git remote, np. git@github.com:user/agentbox-backup.git", text: $remote).textFieldStyle(.roundedBorder)
        HStack { Button("Odśwież status") { Task { await model.loadBackupStatus() } }; Button("Wykonaj backup teraz") { Task { await model.backup(remote: remote) } }.buttonStyle(.borderedProminent) }
        GroupBox("Status") { Text(model.backupStatus.isEmpty ? "Kliknij „Odśwież status”." : model.backupStatus).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
        Spacer()
    }.padding(28).navigationTitle("Backup").task { await model.loadBackupStatus() } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var openAIModel = "gpt-5.6"
    @State private var anthropicModel = "claude-sonnet-5"
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Label("Ustawienia", systemImage: "gearshape").font(.largeTitle.bold())
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
    let count: Int
    let onSave: (String) -> Void
    @State private var tags = ""
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Dodaj tagi").font(.title2.bold()); Text("Wybrano \(count) skilli. Nowe tagi zostaną dopisane do już istniejących.").foregroundStyle(.secondary); TextField("np. seo, marketing, audit", text: $tags).textFieldStyle(.roundedBorder); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj") { onSave(tags); dismiss() }.buttonStyle(.borderedProminent).disabled(AppModel.csv(tags).isEmpty) } }.padding(24).frame(width: 480) }
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
    let presets: [MCPPreset]
    let servers: [MCPServer]
    let project: Project?
    let selectedPresetIDs: [UUID]
    let selectedProfiles: [String: UUID]
    let onSave: (Project, [UUID], [String: UUID]) -> Void
    @State private var name = ""
    @State private var path = ""
    @State private var tools = Set(Tool.allCases)
    @State private var selected = Set<String>()
    @State private var selectedTags = Set<String>()
    @State private var selectedPresets = Set<UUID>()
    @State private var profiles: [String: UUID] = [:]
    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var profileGroups: [String: [MCPServer]] { Dictionary(grouping: servers.filter { $0.group != nil }, by: { $0.group! }) }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { Text(project == nil ? "Nowy projekt" : "Edytuj projekt").font(.title2.bold()); TextField("Nazwa", text: $name); HStack { TextField("Folder projektu", text: $path); Button("Wybierz…") { chooseFolder() } }; GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: toolBinding(tool)).toggleStyle(.checkbox) } }.padding(6) }; GroupBox("Pojedyncze skille") { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(skills) { skill in Toggle(skill.name, isOn: skillBinding(skill.id)).toggleStyle(.checkbox) } }.padding(6) }.frame(height: 150) }; GroupBox("Tagi dynamiczne") { if availableTags.isEmpty { Text("Najpierw dodaj tagi do skilli.").foregroundStyle(.secondary).padding(6) } else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) { ForEach(availableTags, id: \.self) { tag in Button { if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) } } label: { HStack { Image(systemName: selectedTags.contains(tag) ? "checkmark.circle.fill" : "circle"); TagPill(tag: tag); Text("\(skills.filter { $0.tags.contains(tag) }.count)").font(.caption2).foregroundStyle(.secondary) } }.buttonStyle(.plain) } }.padding(6) } }; GroupBox("Presety MCP") { if presets.isEmpty { Text("Brak presetów MCP.").foregroundStyle(.secondary).padding(6) } else { HStack { ForEach(presets) { preset in Toggle(preset.name, isOn: presetBinding(preset.id)).toggleStyle(.checkbox) } }.padding(6) } }; if !profileGroups.isEmpty { GroupBox("Warianty MCP dla tego projektu") { VStack { ForEach(profileGroups.keys.sorted(), id: \.self) { group in Picker(group, selection: profileBinding(group)) { ForEach(profileGroups[group] ?? []) { server in Text(server.profile ?? server.name).tag(server.id) } } } }.padding(6) } }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { onSave(Project(id: project?.id ?? UUID(), name: name, path: path, tools: Array(tools), skillIDs: Array(selected), tags: Array(selectedTags).sorted()), Array(selectedPresets), profiles); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || path.isEmpty || tools.isEmpty) } }.padding(24) }.frame(width: 700, height: 760).onAppear { selectedPresets = Set(selectedPresetIDs); profiles = selectedProfiles; for (group, values) in profileGroups where profiles[group] == nil { profiles[group] = values.first?.id }; if let project { name = project.name; path = project.path; tools = Set(project.tools); selected = Set(project.skillIDs); selectedTags = Set(project.tags) } } }
    private func toolBinding(_ tool: Tool) -> Binding<Bool> { Binding(get: { tools.contains(tool) }, set: { if $0 { tools.insert(tool) } else { tools.remove(tool) } }) }
    private func skillBinding(_ id: String) -> Binding<Bool> { Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } }) }
    private func presetBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { selectedPresets.contains(id) }, set: { if $0 { selectedPresets.insert(id) } else { selectedPresets.remove(id) } }) }
    private func profileBinding(_ group: String) -> Binding<UUID> { Binding(get: { profiles[group] ?? profileGroups[group]!.first!.id }, set: { profiles[group] = $0 }) }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url?.path ?? path } }
}

struct StatusToast: View { let text: String; let onClose: () -> Void; var body: some View { HStack(spacing: 10) { Label(text, systemImage: "info.circle.fill"); Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Zamknij") }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).shadow(radius: 8).padding(.bottom, 14) } }
