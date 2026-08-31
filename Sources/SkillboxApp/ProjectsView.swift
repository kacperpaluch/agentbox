import SwiftUI
import AppKit
import Combine
import SkillboxCore

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Binding var showProject: Bool
    @State private var showBatch = false
    @State private var showAllSync = false
    @State private var editing: Project?
    @State private var previewProject: Project?
    @State private var deleting: Project?
    @State private var adopting: Project?
    @State private var managingPlugins: Project?
    @State private var deleteFiles = false
    @State private var collapsedGroups = Set<String>()
    @State private var editingRoot: ProjectRoot?
    @State private var deletingRoot: ProjectRoot?
    @State private var settingUpRoot: ProjectGroup?
    @State private var showDetected = false
    @State private var showProjectDefaults = false
    @State private var showGlobalSkills = false
    @State private var showClientServers = false

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
            projectList
        }
        .navigationTitle("Projekty")
        .sheet(isPresented: $showBatch) { BatchProjectView(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, existingProjects: model.projects, existingRoots: model.projectRoots, initialSelection: model.projectDefaults) { request in Task { await model.addBatch(request) } } }
        .sheet(isPresented: $showDetected) { DetectedFoldersView(model: model) }
        .sheet(isPresented: $showProjectDefaults) { ProjectDefaultsEditor(model: model) }
        .sheet(isPresented: $showGlobalSkills) { GlobalSelectionEditor(model: model) }
        .sheet(isPresented: $showClientServers) { ClientServersView(model: model) }
        .sheet(item: $settingUpRoot) { group in GroupRootSetupView(model: model, folderPath: group.path, projects: group.projects) }
        .sheet(item: $editingRoot) { root in
            ProjectRootEditor(
                skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, root: root,
                followingProjects: model.storedProjects.filter { $0.rootID == root.id && $0.overridesRoot != true }.count,
                initialSelection: model.selection(for: .root(root.id))
            ) { updated, selection in Task { await model.saveRoot(updated, selection: selection) } }
        }
        .sheet(item: $editing) { project in
            ProjectEditor(
                skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs,
                project: model.storedProject(id: project.id) ?? project,
                root: model.root(for: project),
                inheritedFrom: model.inheritsRoot(project) ? model.projects.first { $0.id == project.id } : nil,
                // Resolved on purpose: a project following its folder opens showing what it actually
                // gets, so switching to own settings starts from today's state, not an empty form.
                initialSelection: model.selection(for: .project(project.id), resolvingInheritance: true)
            ) { updated, selection in Task { await model.updateProject(updated, selection: selection) } }
        }
        .sheet(item: $previewProject) { project in MCPPreviewView(model: model, project: project) }
        .sheet(isPresented: $showAllSync) { AllProjectsSyncPreviewView(model: model) }
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Usuń tylko z Agentbox", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: false) } }; deleting = nil }
            Button("Usuń i posprzątaj pliki w projekcie", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: true) } }; deleting = nil }
            Button("Anuluj", role: .cancel) { deleting = nil }
        } message: { Text("Sprzątanie usuwa z folderu projektu wyłącznie katalogi skilli i wpisy MCP wymienione w manifestach Agentbox. Przed zmianą powstaje backup, który można cofnąć w sekcji Odzyskiwanie.") }
        .sheet(item: $adopting) { project in AdoptSkillsView(model: model, project: project) }
        .sheet(item: $managingPlugins) { project in ClaudePluginsView(model: model, project: project) }
        .confirmationDialog("Usunąć wspólne ustawienia folderu \(deletingRoot?.name ?? "")?", isPresented: Binding(get: { deletingRoot != nil }, set: { if !$0 { deletingRoot = nil } })) {
            Button("Usuń ustawienia folderu", role: .destructive) { if let deletingRoot { Task { await model.deleteRoot(deletingRoot) } }; deletingRoot = nil }
            Button("Anuluj", role: .cancel) { deletingRoot = nil }
        } message: { Text("Projekty zostają. Każdy, który korzystał z ustawień folderu, dostaje ich kopię, więc do repozytoriów trafia dokładnie to samo co dziś. Agentbox przestaje tylko pytać o nowe podfoldery.") }
    }

    /// The question the user asked for: a new subfolder in a watched parent folder is offered as a
    /// project instead of being noticed only when something is missing from it.
    private var detectedBanner: some View {
        HStack(spacing: Space.section - 2) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.detectedFolders.count == 1 ? "Nowy podfolder w obserwowanym folderze" : "Nowe podfoldery w obserwowanych folderach: \(model.detectedFolders.count)").font(.callout.weight(.medium))
                Text(model.detectedFolders.prefix(3).map(\.name).joined(separator: ", ") + (model.detectedFolders.count > 3 ? "…" : "")).rowMetadata().lineLimit(1)
            }
            Spacer()
            Button("Przejrzyj…") { showDetected = true }.buttonStyle(.borderedProminent)
            Button("Dodaj i synchronizuj") { let folders = model.detectedFolders; Task { await model.addDetected(folders, synchronizing: true) } }.buttonStyle(.bordered).disabled(model.isWorking)
        }
        .padding(.horizontal, Space.page).padding(.vertical, Space.row + 2)
        .background(.quaternary.opacity(0.4))
    }

    private var projectList: some View {
        List {
            defaultsSection
            if model.projects.isEmpty && model.projectRoots.isEmpty {
                ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode."))
                    .listRowSeparator(.hidden)
            }
            if !model.projects.isEmpty { projectColumnHeader }
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: groupExpansion(group.path)) {
                    if group.projects.isEmpty { Text("Folder bez projektów. Dodaj podfoldery przez `Dodaj wiele` albo poczekaj, aż Agentbox je wykryje.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                    ForEach(group.projects) { project in
                        // A project that belongs to a watched folder but opted out of its shared
                        // settings looks, at a glance, exactly like one that simply follows it — the
                        // one place that showed the difference was deep in its own editor. Surfacing
                        // it here means a change to the folder's settings does not quietly skip this
                        // project without anyone noticing on the list.
                        let ownSettings = group.root != nil && !model.inheritsRoot(project)
                        ProjectRow(project: project, status: model.statuses[project.id], inheritsRoot: model.inheritsRoot(project), ownSettingsInRoot: ownSettings, rootName: group.root?.name, editing: $editing, previewProject: $previewProject, deleting: $deleting, adopting: $adopting, managingPlugins: $managingPlugins)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.tight + 2) {
                                Image(systemName: group.root == nil ? "folder" : "folder.badge.gearshape").foregroundStyle(.tint)
                                Text(group.name).sectionLabel()
                                Text("\(group.projects.count)").rowMetadata()
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
            Menu {
                Button { showProject = true } label: { Label("Jeden projekt…", systemImage: "folder.badge.plus") }
                Button { showBatch = true } label: { Label("Wiele projektów…", systemImage: "folder.badge.plus") }
            } label: { Label("Dodaj projekt", systemImage: "plus") }
                .menuStyle(.borderedButton)
            Menu {
                Button { Task { await model.refreshProjects() } } label: { Label("Sprawdź stan projektów", systemImage: "arrow.clockwise") }
                    .disabled((model.projects.isEmpty && model.projectRoots.isEmpty) || model.isCheckingStatuses)
                Button { showClientServers = true } label: { Label("Serwery klientów…", systemImage: "server.rack") }
                Button { showGlobalSkills = true } label: { Label("Skille we wszystkich sesjach…", systemImage: "person.crop.circle") }
                Divider()
                Button("Rozwiń wszystko") { collapsedGroups.removeAll() }
                Button("Zwiń wszystko") { collapsedGroups = Set(groups.map(\.path)) }
            } label: { Label("Więcej", systemImage: "ellipsis") }
            Spacer()
            if model.isCheckingStatuses { ProgressView().controlSize(.small) }
        }
    }

    /// A starting template, not an inherited configuration: it is copied into the editor only when
    /// a project is created, so changing it can never alter an existing project.
    private var defaultsSection: some View {
        HStack(spacing: Space.tight + 4) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Domyślne dla nowych projektów").sectionLabel()
                Text(globalSummary).rowMetadata().lineLimit(1)
            }
            Spacer()
            Button("Skonfiguruj…") { showProjectDefaults = true }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, Space.row)
        .listRowBackground(Color.accentColor.opacity(0.06))
    }

    private var projectColumnHeader: some View {
        HStack(spacing: Space.section) {
            Text("PROJEKT").frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            Text("STAN").frame(width: 145, alignment: .leading)
            Text("ZAWARTOŚĆ").frame(width: 170, alignment: .leading)
            Text("AKCJE").frame(width: 150, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, Space.tight)
        .listRowSeparator(.hidden)
    }

    private var globalSummary: String {
        let defaults = model.projectDefaults
        let clients = defaults.tools.isEmpty ? "bez klientów" : defaults.tools.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let skills = defaults.skillIDs.count + defaults.skillTags.count
        let servers = defaults.serverIDs.count + defaults.serverTags.count
        let docs = defaults.docIDs.count + defaults.docTags.count
        return "\(clients) · \(skills) skilli · \(servers) MCP · \(docs) dokumentów"
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
    /// True when the project sits in a watched parent folder but was deliberately switched to its
    /// own settings — so a change to the folder silently stops reaching it.
    var ownSettingsInRoot: Bool = false
    var rootName: String?
    @Binding var editing: Project?
    @Binding var previewProject: Project?
    @Binding var deleting: Project?
    @Binding var adopting: Project?
    @Binding var managingPlugins: Project?

    var body: some View {
        HStack(alignment: .center, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(project.name).rowTitle()
                Text(project.path).rowMetadata().lineLimit(1).help(project.path)
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            ProjectStatusBadge(status: status)
                .frame(width: 145, alignment: .leading)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text(contentSummary).rowMetadata().lineLimit(1)
                if ownSettingsInRoot {
                    MetaBadge(text: "Własne ustawienia", tint: .orange)
                        .help("Projekt nie dziedziczy ustawień folderu\(rootName.map { " „\($0)”" } ?? "")")
                } else if inheritsRoot {
                    Label("Ustawienia folderu", systemImage: "arrow.turn.up.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, alignment: .leading)

            HStack(spacing: Space.tight) {
                Button("Synchronizuj") { previewProject = project }.buttonStyle(.borderedProminent).controlSize(.small)
                RowMenu {
                    Button("Edytuj…") { editing = project }
                    Button("Przejmij skille z projektu…") { adopting = project }
                    Button("Pluginy Claude…") { managingPlugins = project }
                    Divider()
                    Button("Usuń projekt…", role: .destructive) { deleting = project }
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.vertical, Space.row)
    }

    private var contentSummary: String {
        let pieces = ["\(project.tools.count) klientów", "\(project.tags.count) tagów"]
        return pieces.joined(separator: " · ")
    }
}
struct ClaudePluginsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let project: Project
    @State private var plugins: [ClaudePlugin]?
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var scope: ClaudePluginScope = .project
    @State private var installConfirmation = false
    @State private var uninstalling: ClaudePlugin?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pluginy Claude").font(.title2.bold())
            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            Text("Pluginy mogą dodawać skille, agentów, hooki, MCP i programy wykonywalne. Instaluj wyłącznie źródła, którym ufasz. Agentbox przekazuje instalację do Claude Code, aby zachować jego zależności i cache.").font(.caption).foregroundStyle(.orange)
            GroupBox("Zainstaluj plugin") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Marketplace, np. AgriciDaniel/claude-seo (opcjonalnie)", text: $marketplace)
                    TextField("Plugin, np. claude-seo@agricidaniel-claude-seo", text: $plugin)
                    Picker("Zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
                    HStack { Spacer(); Button("Zainstaluj…") { installConfirmation = true }.buttonStyle(.borderedProminent).disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking) }
                }.padding(6)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("Aktywne w tym projekcie") {
                if plugins == nil { ProgressView().padding(8) }
                else if plugins?.isEmpty == true { Text("Brak pluginów Claude w zakresie projektu lub lokalnym.").font(.caption).foregroundStyle(.secondary).padding(8) }
                else { List(plugins ?? []) { item in
                    HStack { VStack(alignment: .leading, spacing: 2) { Text(item.id).fontWeight(.medium); Text(item.scope.displayName).font(.caption).foregroundStyle(.secondary) }; Spacer(); if !item.enabled { MetaBadge(text: "wyłączony", tint: .secondary) }; Button("Usuń", role: .destructive) { uninstalling = item }.buttonStyle(.bordered).controlSize(.small).disabled(model.isWorking) }.padding(.vertical, 2)
                }.frame(minHeight: 120) }
            }
            HStack { Spacer(); Button("Zamknij") { dismiss() } }
        }
        .padding(24).sheetFrame(width: 680, height: 590)
        .task { await reload() }
        .confirmationDialog("Zainstalować plugin w projekcie?", isPresented: $installConfirmation) {
            Button("Zainstaluj", role: .destructive) { let requestedMarketplace = marketplace.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.installClaudePlugin(project: project, marketplace: requestedMarketplace.isEmpty ? nil : requestedMarketplace, plugin: plugin, scope: scope); await reload() } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Claude Code pobierze plugin „\(plugin)” i może aktywować jego hooki, MCP oraz pliki wykonywalne. Zakres: \(scope.displayName).") }
        .confirmationDialog("Usunąć plugin \(uninstalling?.id ?? "")?", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
            Button("Usuń plugin", role: .destructive) { if let uninstalling { Task { await model.uninstallClaudePlugin(project: project, plugin: uninstalling); self.uninstalling = nil; await reload() } } }
            Button("Anuluj", role: .cancel) { uninstalling = nil }
        } message: { Text("Plugin zostanie wyłączony w tym zakresie projektu przez Claude Code.") }
    }

    private func reload() async {
        do { plugins = try await model.claudePlugins(for: project); error = "" }
        catch let loadError { plugins = []; error = loadError.localizedDescription }
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
        }.padding(24).sheetFrame(width: 820, height: 700).task { do { plans = try await model.previewAllProjectsSync() } catch { self.error = error.localizedDescription; model.reportError(error) } }
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
                ForEach(plan.preview.docs, id: \.file) { item in
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
        .padding(24).sheetFrame(width: 640, height: 520)
        .task { do { candidates = try await model.adoptableSkills(project) } catch { self.error = error.localizedDescription } }
    }
}
