import SwiftUI
import AppKit
import Combine
import SkillboxCore

/// What the Projekty list shows. "Problemy" are the projects that cannot be synchronized as they are.
enum ProjectFilter: String, CaseIterable, Identifiable {
    case all = "Wszystkie", pending = "Do synchronizacji", problems = "Problemy"
    var id: String { rawValue }

    func includes(_ state: ProjectStatus.State?) -> Bool {
        switch (self, state) {
        case (.all, _), (.pending, .pending?), (.problems, .blocked?), (.problems, .missing?): true
        default: false
        }
    }
    /// Lower comes first: what needs a decision, then what needs a sync, then everything else.
    static func rank(_ state: ProjectStatus.State?) -> Int {
        switch state {
        case .blocked?: 0
        case .missing?: 1
        case .pending?: 2
        case .synced?: 3
        case nil: 4
        }
    }
    static func matches(_ project: Project, search: String) -> Bool {
        search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search)
    }
    /// The order inside a group: attention first, then by name.
    /// What most projects of a group have. A row names its clients and tags only when they differ,
    /// so a folder whose projects all use Claude and `#seo` does not say so on every line.
    static func usual<T: Hashable>(_ sets: [Set<T>], otherwise fallback: Set<T>) -> Set<T> {
        let counts = Dictionary(sets.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.count > $1.key.count }?.key ?? fallback
    }
    static func usualTools(_ projects: [Project], enabled: [Tool]) -> Set<Tool> {
        usual(projects.map { Set($0.tools.filter(enabled.contains)) }, otherwise: Set(enabled))
    }
    static func usualTags(_ projects: [Project]) -> Set<String> { usual(projects.map { Set($0.tags) }, otherwise: []) }
    static func sorted(_ projects: [Project], statuses: [UUID: ProjectStatus]) -> [Project] {
        projects.sorted {
            let (left, right) = (rank(statuses[$0.id]?.state), rank(statuses[$1.id]?.state))
            return left != right ? left < right : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Binding var showProject: Bool
    @State private var showBatch = false
    @State private var syncScope: SyncScope?
    @State private var configurationProject: Project?
    @State private var editing: Project?
    @State private var previewProject: Project?
    @State private var deleting: Project?
    @State private var deletingMissing = false
    @State private var adopting: Project?
    @State private var managingPlugins: Project?
    @State private var editingRoot: ProjectRoot?
    @State private var deletingRoot: ProjectRoot?
    @State private var settingUpRoot: ProjectGroup?
    @State private var showDetected = false
    @State private var showProjectDefaults = false
    @State private var showGlobalSkills = false
    @State private var showClientServers = false
    @State private var search = ""
    @State private var filter = ProjectFilter.all
    @State private var checked = Set<UUID>()
    @State private var deletingChecked = false
    @State private var followingChecked = false
    /// Folder paths, one per line. Kept between launches so a long list opens the way it was left.
    @AppStorage("AgentboxCollapsedProjectGroups") private var collapsedStorage = ""

    private struct SyncScope: Identifiable {
        let id = UUID()
        let ids: Set<UUID>?
        let title: String
    }

    private struct ProjectGroup: Identifiable {
        let path: String
        let root: ProjectRoot?
        let projects: [Project]
        var id: String { root?.id.uuidString ?? path }
        var name: String { root?.name ?? URL(fileURLWithPath: path).lastPathComponent }
    }

    private var collapsedGroups: Set<String> {
        get { Set(collapsedStorage.split(separator: "\n").map(String.init)) }
        nonmutating set { collapsedStorage = newValue.sorted().joined(separator: "\n") }
    }
    private var isFiltering: Bool { !search.isEmpty || filter != .all }
    private var checkedProjects: [Project] { model.projects.filter { checked.contains($0.id) } }
    private var followable: [Project] { checkedProjects.filter(model.hasOwnSettingsInRoot) }

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
        let sorted: ([Project]) -> [Project] = { ProjectFilter.sorted($0, statuses: model.statuses) }
        // A folder with no projects left still appears, otherwise its shared settings would become
        // unreachable the moment its last project is removed.
        let rootGroups = model.projectRoots.map { ProjectGroup(path: $0.path, root: $0, projects: sorted(byRoot[$0.id] ?? [])) }
        let pathGroups = byPath.map { ProjectGroup(path: $0.key, root: nil, projects: sorted($0.value)) }
        return (rootGroups + pathGroups).sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }
    private func visible(_ group: ProjectGroup) -> [Project] {
        group.projects.filter { ProjectFilter.matches($0, search: search) && filter.includes(model.statuses[$0.id]?.state) }
    }
    private func count(_ filter: ProjectFilter, in projects: [Project]) -> Int { projects.filter { filter.includes(model.statuses[$0.id]?.state) }.count }
    /// A project without its folder has nothing to synchronize into; a selection made only of those disables the button.
    private func syncable(_ projects: [Project]) -> Set<UUID> { Set(projects.filter { model.statuses[$0.id]?.state != .missing }.map(\.id)) }
    private func names(_ projects: [Project]) -> String {
        let shown = projects.prefix(8).map(\.name).joined(separator: ", ")
        return projects.count > 8 ? "\(shown) i \(projects.count - 8) więcej" : shown
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if !model.detectedFolders.isEmpty { detectedBanner }
            projectList
        }
        .navigationTitle("Projekty")
        .searchable(text: $search, prompt: "Nazwa lub ścieżka projektu")
        .onChange(of: model.projects.map(\.id)) { checked.formIntersection(model.projects.map(\.id)) }
        .sheet(isPresented: $showBatch) { BatchProjectView(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, existingProjects: model.projects, existingRoots: model.projectRoots, claudePlugins: model.claudePluginLibrary, initialSelection: model.projectDefaults) { request in await model.addBatch(request) } }
        .sheet(isPresented: $showDetected) { DetectedFoldersView(model: model) }
        .sheet(isPresented: $showProjectDefaults) { ProjectDefaultsEditor(model: model) }
        .sheet(isPresented: $showGlobalSkills) { GlobalSelectionEditor(model: model) }
        .sheet(isPresented: $showClientServers) { ClientServersView(model: model) }
        .sheet(item: $settingUpRoot) { group in GroupRootSetupView(model: model, folderPath: group.path, projects: group.projects) }
        .sheet(item: $editingRoot) { root in
            ProjectRootEditor(
                skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, root: root,
                followingProjects: model.storedProjects.filter { $0.rootID == root.id && $0.overridesRoot != true }.count,
                initialSelection: model.selection(for: .root(root.id))
            ) { updated, selection in await model.saveRoot(updated, selection: selection) }
        }
        .sheet(item: $editing) { project in
            ProjectEditor(
                skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary,
                project: model.storedProject(id: project.id) ?? project,
                root: model.root(for: project),
                inheritedFrom: model.inheritsRoot(project) ? model.projects.first { $0.id == project.id } : nil,
                // Resolved on purpose: a project following its folder opens showing what it actually
                // gets, so switching to own settings starts from today's state, not an empty form.
                initialSelection: model.selection(for: .project(project.id), resolvingInheritance: true)
            ) { updated, selection in await model.updateProject(updated, selection: selection) }
        }
        .sheet(item: $configurationProject) { project in ProjectConfigurationView(model: model, project: project) }
        .sheet(item: $previewProject) { project in MCPPreviewView(model: model, project: project) }
        .sheet(item: $syncScope) { scope in AllProjectsSyncPreviewView(model: model, ids: scope.ids, title: scope.title) }
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Usuń tylko z Agentbox", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: false) } }; deleting = nil }
            Button("Usuń i posprzątaj pliki w projekcie", role: .destructive) { if let deleting { Task { await model.deleteProject(deleting, removingFiles: true) } }; deleting = nil }
            Button("Anuluj", role: .cancel) { deleting = nil }
        } message: { Text("Sprzątanie usuwa wyłącznie skille, wpisy MCP i dokumenty zarządzane przez Agentbox. Kopia na czas operacji służy do cofnięcia zmian w razie błędu; po udanej operacji jest usuwana i nie pojawia się w odzyskiwaniu. Pliki można odtworzyć z biblioteki po ponownym dodaniu i skonfigurowaniu projektu oraz synchronizacji.") }
        .confirmationDialog("Usunąć z Agentbox projekty bez folderu (\(model.missingProjects.count))?", isPresented: $deletingMissing) {
            Button("Usuń z Agentbox", role: .destructive) { Task { await model.deleteMissingProjects() } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text(model.missingProjects.map(\.name).joined(separator: ", ") + "\n\nAgentbox zapomina tylko ich ustawienia; niczego nie usuwa z dysku. Przed zapisem powstaje snapshot biblioteki.") }
        .confirmationDialog("Usunąć z Agentbox \(PolishNoun.project(checkedProjects.count))?", isPresented: $deletingChecked) {
            Button("Usuń tylko z Agentbox", role: .destructive) { let projects = checkedProjects; Task { await model.deleteProjects(projects, removingFiles: false) } }
            // A project without its folder has no files to clean, and trying would stop the whole action.
            if !checkedProjects.contains(where: { model.statuses[$0.id]?.state == .missing }) {
                Button("Usuń i posprzątaj pliki w projektach", role: .destructive) { let projects = checkedProjects; Task { await model.deleteProjects(projects, removingFiles: true) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { Text(names(checkedProjects) + "\n\nSprzątanie usuwa wyłącznie skille, wpisy MCP i dokumenty zarządzane przez Agentbox. Foldery projektów zostają na dysku.") }
        .confirmationDialog("Przełączyć na ustawienia folderu \(PolishNoun.project(followable.count))?", isPresented: $followingChecked) {
            Button("Przełącz na ustawienia folderu", role: .destructive) { let projects = followable; Task { await model.followRoot(projects) } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text(names(followable) + "\n\nIch własne wybory skilli, MCP i dokumentów zostaną usunięte; od teraz dostają to, co ustawiono w folderze. Pliki w projektach zmienią się dopiero przy synchronizacji. Zmianę można cofnąć snapshotem biblioteki.") }
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
        let shownGroups = groups.map { ($0, visible($0)) }.filter { !isFiltering || !$0.1.isEmpty }
        return List {
            defaultsSection
            if model.projects.isEmpty && model.projectRoots.isEmpty {
                ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode."))
                    .listRowSeparator(.hidden)
            } else if isFiltering && shownGroups.isEmpty {
                ContentUnavailableView("Nic nie pasuje", systemImage: "magnifyingglass", description: Text(filter == .all ? "Żaden projekt nie pasuje do „\(search)”." : "Brak projektów w widoku „\(filter.rawValue)”."))
                    .listRowSeparator(.hidden)
            }
            if !model.projects.isEmpty && !shownGroups.isEmpty { projectColumnHeader }
            ForEach(shownGroups, id: \.0.id) { group, shown in
                let usualTools = ProjectFilter.usualTools(group.projects, enabled: model.enabledTools)
                let usualTags = ProjectFilter.usualTags(group.projects)
                DisclosureGroup(isExpanded: groupExpansion(group.path)) {
                    if group.projects.isEmpty { Text("Folder bez projektów. Dodaj podfoldery przez `Dodaj wiele` albo poczekaj, aż Agentbox je wykryje.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                    ForEach(shown) { project in
                        ProjectRow(
                            project: project, status: model.statuses[project.id],
                            // A project that opted out of its folder's settings looks, at a glance, like
                            // one that follows it; the badge keeps a folder change from quietly skipping it.
                            ownSettingsInRoot: group.root != nil && !model.inheritsRoot(project),
                            rootName: group.root?.name, enabledTools: model.enabledTools, usualTools: usualTools, usualTags: usualTags,
                            isChecked: checkBinding(project.id),
                            open: { configurationProject = project }, sync: { previewProject = project }
                        ) { projectActions(project) }
                        .contextMenu { contextMenu(for: project) }
                    }
                } label: { groupHeader(group, shown: shown) }
            }
        }
    }

    private func groupHeader(_ group: ProjectGroup, shown: [Project]) -> some View {
        let pending = count(.pending, in: group.projects), problems = count(.problems, in: group.projects)
        return HStack {
            if !shown.isEmpty { Toggle("", isOn: groupCheckBinding(shown)).labelsHidden().toggleStyle(.checkbox).help("Zaznacz widoczne projekty tej grupy") }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.tight + 2) {
                    Image(systemName: group.root == nil ? "folder" : "folder.badge.gearshape").foregroundStyle(.tint)
                    Text(group.name).sectionLabel()
                    Text("\(group.projects.count)").rowMetadata()
                    if let root = group.root, root.watchesNewFolders { Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary).help("Agentbox pyta o nowe podfoldery w tym folderze") }
                    if pending > 0 { MetaBadge(text: "\(pending) do synchronizacji", tint: .orange) }
                    if problems > 0 { MetaBadge(text: "\(problems) z problemem", tint: .red) }
                }
                Text(group.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).help(group.path)
            }
            Spacer()
            if pending > 0 {
                Button { syncScope = SyncScope(ids: Set(group.projects.map(\.id)), title: "Synchronizacja: \(group.name)") } label: { Label("Synchronizuj grupę", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isWorking)
            }
            if let root = group.root {
                Button { editingRoot = root } label: { Label("Ustawienia folderu", systemImage: "gearshape") }.buttonStyle(.bordered).controlSize(.small)
                // A bare trash icon read as "delete this group and its projects"; it only ever removed the
                // shared settings, so it now says so, one click further away.
                RowMenu {
                    Button("Usuń wspólne ustawienia folderu…", role: .destructive) { deletingRoot = root }
                }
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

    /// One list of a project's actions, shared by its "…" menu and its right-click menu.
    @ViewBuilder private func projectActions(_ project: Project) -> some View {
        Button("Konfiguracja i pochodzenie…") { configurationProject = project }
        Button("Edytuj…") { editing = project }
        Button("Przejmij z projektu…") { adopting = project }
        Button("Pluginy Claude…") { managingPlugins = project }
        Divider()
        Button("Usuń projekt…", role: .destructive) { deleting = project }
    }

    /// Right-clicking a checked row acts on everything checked, as in Finder; any other row acts on itself.
    @ViewBuilder private func contextMenu(for project: Project) -> some View {
        if checked.contains(project.id) && checked.count > 1 {
            Button("Synchronizuj zaznaczone (\(checked.count))…") { syncChecked() }.disabled(syncable(checkedProjects).isEmpty || model.isWorking)
            if !followable.isEmpty { Button("Przełącz na ustawienia folderu (\(followable.count))…") { followingChecked = true } }
            Divider()
            Button("Usuń zaznaczone (\(checked.count))…", role: .destructive) { deletingChecked = true }
        } else {
            Button("Synchronizuj…") { previewProject = project }.disabled(model.statuses[project.id]?.state == .missing)
            projectActions(project)
        }
    }

    private func syncChecked() { syncScope = SyncScope(ids: checked, title: "Synchronizacja zaznaczonych projektów") }

    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { syncScope = SyncScope(ids: nil, title: "Synchronizacja wszystkich projektów") } label: { Label("Synchronizuj wszystkie", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.projects.isEmpty || model.isWorking)
                Menu {
                    Button { showProject = true } label: { Label("Jeden projekt…", systemImage: "folder.badge.plus") }
                    Button { showBatch = true } label: { Label("Wiele projektów…", systemImage: "folder.badge.plus") }
                } label: { Label("Dodaj projekt", systemImage: "plus") }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                Menu {
                    Button { Task { await model.refreshProjects() } } label: { Label("Sprawdź stan projektów", systemImage: "arrow.clockwise") }
                        .disabled((model.projects.isEmpty && model.projectRoots.isEmpty) || model.isCheckingStatuses)
                    Button { showClientServers = true } label: { Label("Serwery klientów…", systemImage: "server.rack") }
                    Button { showGlobalSkills = true } label: { Label("Skille we wszystkich sesjach…", systemImage: "person.crop.circle") }
                    Divider()
                    Button(role: .destructive) { deletingMissing = true } label: { Label("Usuń projekty bez folderu (\(model.missingProjects.count))…", systemImage: "questionmark.folder") }
                        .disabled(model.missingProjects.isEmpty || model.isWorking)
                    Divider()
                    Button("Rozwiń wszystko") { collapsedGroups = [] }
                    Button("Zwiń wszystko") { collapsedGroups = Set(groups.map(\.path)) }
                } label: { Label("Więcej", systemImage: "ellipsis") }
                    .fixedSize()
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { syncChecked() } label: { Label("Synchronizuj", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncable(checkedProjects).isEmpty || model.isWorking)
                if !followable.isEmpty {
                    Button { followingChecked = true } label: { Label("Ustawienia folderu (\(followable.count))", systemImage: "arrow.turn.up.right") }
                        .buttonStyle(.bordered)
                        .help("Przełącz projekty z własnymi ustawieniami na ustawienia ich folderu")
                }
                Button(role: .destructive) { deletingChecked = true } label: { Label("Usuń", systemImage: "trash") }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            if model.isCheckingStatuses {
                ProgressView().controlSize(.small)
                if let progress = model.progress, progress.total > 1 {
                    Text("\(progress.done)/\(progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("Pokaż", selection: $filter) {
                ForEach(ProjectFilter.allCases) { item in
                    Text(item == .all ? "\(item.rawValue) \(model.projects.count)" : "\(item.rawValue) \(count(item, in: model.projects))").tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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
            Text("WYJĄTKI").frame(width: 170, alignment: .leading)
            Text("AKCJE").frame(width: 150, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 22)
        .padding(.vertical, Space.tight)
        .listRowSeparator(.hidden)
    }

    private var globalSummary: String {
        let defaults = model.projectDefaults
        let tools = defaults.tools.filter(model.enabledTools.contains)
        let clients = tools.isEmpty ? "bez klientów" : tools.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let skills = defaults.skillIDs.count + defaults.skillTags.count
        let servers = defaults.serverIDs.count + defaults.serverTags.count
        let docs = defaults.docIDs.count + defaults.docTags.count
        return "\(clients) · \(skills) skilli · \(servers) MCP · \(docs) dokumentów"
    }

    private func groupExpansion(_ path: String) -> Binding<Bool> {
        // A search or a filter opens every group: hiding a match inside a collapsed folder would look like no match.
        Binding(get: { isFiltering || !collapsedGroups.contains(path) }, set: { open in
            if open { collapsedGroups.remove(path) } else { collapsedGroups.insert(path) }
        })
    }
    private func checkBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
    private func groupCheckBinding(_ projects: [Project]) -> Binding<Bool> {
        let ids = Set(projects.map(\.id))
        return Binding(get: { !ids.isEmpty && ids.isSubset(of: checked) }, set: { if $0 { checked.formUnion(ids) } else { checked.subtract(ids) } })
    }
}
struct ProjectStatusBadge: View {
    let status: ProjectStatus?
    var body: some View {
        switch status?.state {
        case .synced:
            // The common case stays quiet so the states that need something stand out.
            Label { Text("Aktualny").foregroundStyle(.secondary) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }.font(.caption)
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
/// One line per project. The third column lists only what differs from the usual — own settings
/// inside a folder, a narrower set of clients, skill tags — so a list of identical projects reads as
/// identical instead of repeating the same facts on every row.
private struct ProjectRow<Actions: View>: View {
    let project: Project
    let status: ProjectStatus?
    let ownSettingsInRoot: Bool
    let rootName: String?
    let enabledTools: [Tool]
    let usualTools: Set<Tool>
    let usualTags: Set<String>
    @Binding var isChecked: Bool
    let open: () -> Void
    let sync: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Space.section) {
            Toggle("", isOn: $isChecked).labelsHidden().toggleStyle(.checkbox)
            HStack(spacing: Space.row) {
                Button(action: open) { Text(project.name).rowTitle() }.buttonStyle(.plain).help("Co trafia do projektu i dlaczego")
                Text(project.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(project.path)
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            ProjectStatusBadge(status: status)
                .frame(width: 145, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if ownSettingsInRoot {
                    MetaBadge(text: "Własne ustawienia", tint: .orange)
                        .help("Projekt nie dziedziczy ustawień folderu\(rootName.map { " „\($0)”" } ?? "")")
                }
                if let toolsException { Text(toolsException).rowMetadata().lineLimit(1) }
                if Set(project.tags) != usualTags {
                    Text(project.tags.isEmpty ? "Bez tagów" : project.tags.map { "#\($0)" }.joined(separator: " ")).rowMetadata().lineLimit(1).help(project.tags.joined(separator: ", "))
                }
            }
            .frame(width: 170, alignment: .leading)

            HStack(spacing: Space.tight) {
                // Prominent only where there is something to write; elsewhere it would be one of
                // dozens of identical blue buttons drowning out the rows that need attention.
                if case .pending? = status?.state {
                    Button("Synchronizuj", action: sync).buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Synchronizuj", action: sync).buttonStyle(.bordered).controlSize(.small).disabled(status?.state == .missing)
                }
                RowMenu { actions }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.vertical, Space.tight)
    }

    /// Clients named only when they differ from what the rest of the group uses.
    private var toolsException: String? {
        let used = enabledTools.filter(project.tools.contains)
        guard Set(used) != usualTools else { return nil }
        let names = used.map { $0.rawValue.capitalized }.joined(separator: ", ")
        return used.isEmpty ? "Bez klientów" : Set(used).isSubset(of: usualTools) ? "Tylko \(names)" : names
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
    @State private var selectedLibraryPlugins = Set<UUID>()
    /// Set when the stored choice could not be read. Saving is blocked then: the checkboxes would
    /// show nothing selected, and saving that would clear the real selection.
    @State private var selectionError = ""
    private var inheritsRoot: Bool { model.inheritsRoot(project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pluginy Claude").font(.title2.bold())
            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            Text("Pluginy mogą dodawać skille, agentów, hooki, MCP i programy wykonywalne. Instaluj wyłącznie źródła, którym ufasz. Agentbox przekazuje instalację do Claude Code, aby zachować jego zależności i cache.").font(.caption).foregroundStyle(.orange)
            GroupBox("Z biblioteki Agentbox") {
                if model.claudePluginLibrary.isEmpty { Text("Dodaj definicję w Biblioteka → Pluginy.").font(.caption).foregroundStyle(.secondary).padding(6) }
                else { VStack(alignment: .leading, spacing: 5) {
                    // A project following its folder shares one selection with every other project
                    // there, so saving here would change all of them at once. The choice is shown —
                    // it is what this project gets — but it stays the folder's to change.
                    if inheritsRoot {
                        Label("Wybór pochodzi z folderu nadrzędnego i obowiązuje wszystkie projekty w nim. Zmień go w ustawieniach folderu albo nadaj projektowi własne ustawienia.", systemImage: "arrow.down.right.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.claudePluginLibrary) { item in Toggle(item.name, isOn: Binding(get: { selectedLibraryPlugins.contains(item.id) }, set: { enabled in if enabled { selectedLibraryPlugins.insert(item.id) } else { selectedLibraryPlugins.remove(item.id) } })).toggleStyle(.checkbox).help(item.plugin).disabled(inheritsRoot) }
                    if !selectionError.isEmpty { Label("Nie udało się wczytać wyboru: \(selectionError)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    HStack { Spacer(); Button("Zapisz wybór") { Task { await model.saveClaudePluginSelection(project: project, ids: Array(selectedLibraryPlugins)); await reloadSelection() } }.buttonStyle(.bordered).disabled(model.isWorking || inheritsRoot || !selectionError.isEmpty) }
                }.padding(6) }
            }
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
        .task { await reload(); await reloadSelection() }
        .confirmationDialog("Zainstalować plugin w projekcie?", isPresented: $installConfirmation) {
            Button("Zainstaluj", role: .destructive) { let requestedMarketplace = marketplace.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.installClaudePlugin(project: project, marketplace: requestedMarketplace.isEmpty ? nil : requestedMarketplace, plugin: plugin, scope: scope); await reload() } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Claude Code pobierze plugin „\(plugin)” i może aktywować jego hooki, MCP oraz pliki wykonywalne. Zakres: \(scope.displayName).") }
        .confirmationDialog("Usunąć plugin \(uninstalling?.id ?? "")?", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
            Button("Usuń plugin", role: .destructive) { if let uninstalling { Task { await model.uninstallClaudePlugin(project: project, plugin: uninstalling); self.uninstalling = nil; await reload(); await reloadSelection() } } }
            Button("Anuluj", role: .cancel) { uninstalling = nil }
        } message: { Text(inheritsRoot
            ? "Plugin zostanie wyłączony w tym zakresie projektu przez Claude Code. Wybór z biblioteki należy do folderu nadrzędnego, więc kolejna synchronizacja może go przywrócić."
            : "Plugin zostanie wyłączony w tym zakresie projektu przez Claude Code i zniknie z wyboru dla tego projektu, więc synchronizacja go nie przywróci.") }
    }

    private func reload() async {
        do { plugins = try await model.claudePlugins(for: project); error = "" }
        catch let loadError { plugins = []; error = loadError.localizedDescription }
    }

    /// Read back instead of assumed: removing a plugin also drops it from the selection, and the
    /// checkboxes have to show what is actually stored.
    private func reloadSelection() async {
        do { selectedLibraryPlugins = Set(try await model.selectedClaudePluginIDs(for: project)); selectionError = "" }
        catch { selectedLibraryPlugins = []; selectionError = error.localizedDescription }
    }
}

struct AllProjectsSyncPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var plans: [ProjectSyncPlan]?; @State private var error = ""
    @State private var outcomes: [ProjectSyncOutcome] = []
    /// In scope but without a folder: synchronization leaves them out, and this says so.
    @State private var skipped: [Project] = []
    /// A group or a selection; `nil` synchronizes every project.
    var ids: Set<UUID>? = nil
    var title = "Synchronizacja wszystkich projektów"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text("Agentbox najpierw sprawdza plan dla wszystkich wybranych projektów. Każdy projekt jest synchronizowany transakcyjnie ze swoim backupem i rollbackiem. Błąd zatrzymuje serię, a projekt, który go zgłosił, wraca do stanu sprzed zmiany.").font(.caption).foregroundStyle(.secondary)
            Label("Wynikowe pliki MCP mogą zawierać jawne sekrety, dlatego pozostają wykluczone lokalnie z Git.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if !skipped.isEmpty {
                Label("Pominięto, bo nie ma folderu: \(skipped.map(\.name).joined(separator: ", ")). Usuniesz je przez Więcej → Usuń projekty bez folderu.", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if plans == nil { ProgressView() }
            else if !outcomes.isEmpty { ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(outcomes) { ProjectSyncOutcomeRow(outcome: $0) } } } }
            else if let plans { ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(plans) { AllProjectsSyncPlanRow(plan: $0) } } } }
            HStack {
                Spacer()
                Button(outcomes.isEmpty ? "Zamknij" : "Gotowe") { dismiss() }
                if outcomes.isEmpty {
                    Button("Synchronizuj \(PolishNoun.project(plans?.count ?? 0))") {
                        Task {
                            // A run that never started is not "everything succeeded": the sheet stays with the reason.
                            guard let result = await model.syncAllProjects(ids: ids) else { error = model.message; return }
                            if result.allSatisfy({ $0.state == .synced || $0.state == .upToDate }) { dismiss() } else { outcomes = result }
                        }
                    }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || plans == nil || model.isWorking)
                }
            }
        }
        .padding(24).sheetFrame(width: 820, height: 700)
        // Okno arkusza zasłania overlay z App.swift, więc postęp musi być rysowany też tutaj.
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .task { skipped = await model.projectsWithoutFolder(in: ids); do { plans = try await model.previewAllProjectsSync(ids: ids) } catch { self.error = error.localizedDescription; model.reportError(error) } }
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
                if !plan.preview.plugins.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Pluginy Claude").font(.caption.weight(.semibold)); ForEach(plan.preview.plugins) { item in ClaudePluginPreviewRow(item: item) } } }
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
    @State private var drifted: [DriftedSkill]?
    @State private var selected = Set<String>()
    @State private var selectedChanges = Set<String>()
    @State private var error = ""
    /// A failed "Przejmij" keeps the sheet open with its reason, next to a freshly read list.
    @State private var adoptError = ""
    /// Git-backed skills are listed so the user learns why they cannot be taken, but they are not
    /// selectable — `adoptSkillChanges` refuses them for the same reason.
    private var selectable: Int { (candidates?.count ?? 0) + (drifted?.filter { !$0.isGitBacked }.count ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Przejmij z projektu").font(.title2.bold())
            Text("Wszystko, co w \(project.name) czeka na przeniesienie do biblioteki: katalogi ze `SKILL.md`, których biblioteka jeszcze nie zna, oraz zarządzane skille zmienione tutaj po ostatniej synchronizacji. Nic nie znika z projektu.").font(.caption).foregroundStyle(.secondary)
            if !adoptError.isEmpty { Label(adoptError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if candidates == nil { ProgressView() }
            else if candidates?.isEmpty == true && drifted?.isEmpty == true { ContentUnavailableView("Brak kandydatów", systemImage: "checkmark.circle", description: Text("Wszystkie skille w tym projekcie są zarządzane i zgodne z biblioteką.")) }
            else {
                List {
                    if let drifted, !drifted.isEmpty {
                        Section("Zmienione w tym projekcie") {
                            ForEach(drifted) { item in
                                Toggle(isOn: Binding(get: { selectedChanges.contains(item.id) }, set: { if $0 { selectedChanges.insert(item.id) } else { selectedChanges.remove(item.id) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.skillID).fontWeight(.medium)
                                            if item.isGitBacked { MetaBadge(text: "z Git", tint: .orange) }
                                        }
                                        Text(item.isGitBacked
                                             ? "Skill pochodzi z repozytorium — zmianę trzeba wprowadzić w źródle, bo aktualizacja i tak zastąpi kopię w bibliotece."
                                             : "Wersja z projektu zastąpi kopię w bibliotece; pozostałe projekty dostaną ją przy swojej synchronizacji.")
                                            .font(.caption).foregroundStyle(item.isGitBacked ? .orange : .secondary)
                                    }
                                }.toggleStyle(.checkbox).disabled(item.isGitBacked)
                            }
                        }
                    }
                    if let candidates, !candidates.isEmpty {
                        Section("Nieznane bibliotece") {
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
                }
            }
            HStack {
                if selectable > 0 {
                    Button("Zaznacz wszystkie") {
                        selected = Set((candidates ?? []).map(\.id))
                        selectedChanges = Set((drifted ?? []).filter { !$0.isGitBacked }.map(\.id))
                    }
                    Button("Wyczyść") { selected.removeAll(); selectedChanges.removeAll() }
                }
                Spacer()
                Button("Zamknij") { dismiss() }
                Button("Przejmij \(selected.count + selectedChanges.count)") {
                    let newSkills = (candidates ?? []).filter { selected.contains($0.id) }
                    let changes = (drifted ?? []).filter { selectedChanges.contains($0.id) }
                    Task {
                        adoptError = ""
                        if await model.adoptFromProject(newSkills: newSkills, changes: changes) { dismiss() }
                        else { adoptError = model.message; selected.removeAll(); selectedChanges.removeAll(); await load() }
                    }
                }.buttonStyle(.borderedProminent).disabled((selected.isEmpty && selectedChanges.isEmpty) || model.isWorking)
            }
        }
        .padding(24).sheetFrame(width: 640, height: 520)
        .task { await load() }
    }

    private func load() async {
        do {
            candidates = try await model.adoptableSkills(project)
            drifted = try await model.driftedSkills(project)
        } catch { self.error = error.localizedDescription }
    }
}
