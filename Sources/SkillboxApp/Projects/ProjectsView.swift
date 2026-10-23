import SwiftUI
import SkillboxCore

struct ProjectsView: View {
    let model: AppModel
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
    /// Table selection: project ids and `group/…` ids. Click, ⌘, ⇧ and ⌘A work as everywhere on the Mac.
    @State private var selection = Set<String>()
    @State private var deletingChecked = false
    @State private var followingChecked = false
    /// Folder paths, one per line. Kept between launches so a long list opens the way it was left.
    @AppStorage("AgentboxCollapsedProjectGroups") private var collapsedStorage = ""

    private struct SyncScope: Identifiable {
        let id = UUID()
        let ids: Set<UUID>?
        let title: String
    }

    private var collapsedGroups: Set<String> {
        get { Set(collapsedStorage.split(separator: "\n").map(String.init)) }
        nonmutating set { collapsedStorage = newValue.sorted().joined(separator: "\n") }
    }
    private var isFiltering: Bool { !search.isEmpty || filter != .all }
    private var checkedProjects: [Project] { ProjectTableRow.projects(for: selection, in: shownGroups) }
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
        return (rootGroups + pathGroups).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    /// Groups with the projects the search and filter leave; while filtering, groups left empty go.
    private var shownGroups: [(group: ProjectGroup, shown: [Project])] {
        groups.map { group in (group, group.projects.filter { ProjectFilter.matches($0, search: search) && filter.includes(model.statuses[$0.id]?.state) }) }
            .filter { !isFiltering || !$0.shown.isEmpty }
    }
    private func count(_ filter: ProjectFilter, in projects: [Project]) -> Int { projects.count { filter.includes(model.statuses[$0.id]?.state) } }
    /// A project without its folder has nothing to synchronize into; a selection made only of those disables the button.
    private func syncable(_ projects: [Project]) -> Set<UUID> { Set(projects.filter { model.statuses[$0.id]?.state != .missing }.map(\.id)) }
    private func names(_ projects: [Project]) -> String {
        let shown = projects.prefix(8).map(\.name).joined(separator: ", ")
        return projects.count > 8 ? "\(shown) i \(projects.count - 8) więcej" : shown
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if !model.detectedFolders.isEmpty { DetectedFoldersBanner(model: model) { showDetected = true } }
            ProjectDefaultsStrip(model: model) { showProjectDefaults = true }
            Divider()
            projectTable
        }
        .navigationTitle("Projekty")
        .searchable(text: $search, prompt: "Nazwa lub ścieżka projektu")
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
        .confirmationDialog("Usunąć projekt \(deleting?.name ?? "") z Agentbox?", item: $deleting) { deleting in
            Button("Usuń tylko z Agentbox", role: .destructive) { Task { await model.deleteProject(deleting, removingFiles: false) } }
            Button("Usuń i posprzątaj pliki w projekcie", role: .destructive) { Task { await model.deleteProject(deleting, removingFiles: true) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("Sprzątanie usuwa wyłącznie skille, wpisy MCP i dokumenty zarządzane przez Agentbox. Kopia na czas operacji służy do cofnięcia zmian w razie błędu; po udanej operacji jest usuwana i nie pojawia się w odzyskiwaniu. Pliki można odtworzyć z biblioteki po ponownym dodaniu i skonfigurowaniu projektu oraz synchronizacji.") }
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
        .confirmationDialog("Usunąć wspólne ustawienia folderu \(deletingRoot?.name ?? "")?", item: $deletingRoot) { deletingRoot in
            Button("Usuń ustawienia folderu", role: .destructive) { Task { await model.deleteRoot(deletingRoot) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("Projekty zostają. Każdy, który korzystał z ustawień folderu, dostaje ich kopię, więc do repozytoriów trafia dokładnie to samo co dziś. Agentbox przestaje tylko pytać o nowe podfoldery.") }
    }

    @ViewBuilder private var projectTable: some View {
        if model.projects.isEmpty && model.projectRoots.isEmpty {
            ContentUnavailableView("Brak projektów", systemImage: "folder.badge.plus", description: Text("Dodaj folder i wybierz skille dla Claude, Codex lub OpenCode."))
        } else {
            let entries = shownGroups
            Table(of: ProjectTableRow.self, selection: $selection) {
                TableColumn("Projekt") { row in
                    ProjectNameCell(row: row, pending: count(.pending, in: row.group.projects), problems: count(.problems, in: row.group.projects))
                }
                .width(min: 220, ideal: 380)
                TableColumn("Stan") { row in
                    ProjectStateCell(row: row, status: row.project.flatMap { model.statuses[$0.id] }, pending: count(.pending, in: row.group.projects), problems: count(.problems, in: row.group.projects))
                }
                .width(min: 130, ideal: 170)
                TableColumn("Wyjątki") { row in
                    if let project = row.project {
                        ProjectExceptionsCell(
                            project: project,
                            // A project that opted out of its folder's settings looks, at a glance, like one
                            // that follows it; the badge keeps a folder change from quietly skipping it.
                            ownSettingsInRoot: model.hasOwnSettingsInRoot(project), rootName: row.group.root?.name,
                            enabledTools: model.enabledTools,
                            usualTools: ProjectFilter.usualTools(row.group.projects, enabled: model.enabledTools),
                            usualTags: ProjectFilter.usualTags(row.group.projects)
                        )
                    }
                }
                .width(min: 110, ideal: 170)
                TableColumn("Akcje") { row in
                    ProjectActionsCell(row: row, status: row.project.flatMap { model.statuses[$0.id] }, pending: count(.pending, in: row.group.projects), isWorking: model.isWorking, perform: perform)
                }
                .width(min: 170, ideal: 210)
            } rows: {
                ForEach(entries, id: \.group.id) { entry in
                    DisclosureTableRow(ProjectTableRow(group: entry.group), isExpanded: groupExpansion(entry.group.path)) {
                        ForEach(entry.shown) { project in TableRow(ProjectTableRow(project: project, in: entry.group)) }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in contextMenu(for: ids, in: entries) } primaryAction: { ids in open(ids, in: entries) }
            .onDeleteCommand { if !checkedProjects.isEmpty { deletingChecked = true } }
            .overlay {
                if entries.isEmpty {
                    if filter == .all { ContentUnavailableView.search }
                    else { ContentUnavailableView("Nic nie pasuje", systemImage: "line.3.horizontal.decrease.circle", description: Text("Brak projektów w widoku „\(filter.rawValue)”.")) }
                }
            }
        }
    }

    private func row(_ id: String, in entries: [(group: ProjectGroup, shown: [Project])]) -> ProjectTableRow? {
        for (group, shown) in entries {
            if ProjectTableRow(group: group).id == id { return ProjectTableRow(group: group) }
            if let project = shown.first(where: { $0.id.uuidString == id }) { return ProjectTableRow(project: project, in: group) }
        }
        return nil
    }

    /// Right-click acts on what was clicked: one row gets its own menu, several get the bulk actions.
    @ViewBuilder private func contextMenu(for ids: Set<String>, in entries: [(group: ProjectGroup, shown: [Project])]) -> some View {
        if ids.count == 1, let id = ids.first, let row = row(id, in: entries) {
            ProjectRowMenu(row: row, isMissing: row.project.map { model.statuses[$0.id]?.state == .missing } ?? false, perform: perform)
        } else {
            let projects = ProjectTableRow.projects(for: ids, in: entries)
            if !projects.isEmpty {
                Button("Synchronizuj zaznaczone (\(projects.count))…") { selection = ids; syncChecked() }.disabled(syncable(projects).isEmpty || model.isWorking)
                if projects.contains(where: model.hasOwnSettingsInRoot) {
                    Button("Przełącz na ustawienia folderu…") { selection = ids; followingChecked = true }
                }
                Divider()
                Button("Usuń zaznaczone (\(projects.count))…", role: .destructive) { selection = ids; deletingChecked = true }
            }
        }
    }

    /// Double click or Return: a project opens what it gets and why; a folder opens its settings.
    private func open(_ ids: Set<String>, in entries: [(group: ProjectGroup, shown: [Project])]) {
        guard ids.count == 1, let id = ids.first, let row = row(id, in: entries) else { return }
        if let project = row.project { perform(.configure(project)) }
        else if let root = row.group.root { perform(.rootSettings(root)) }
        else { perform(.setUpRoot(row.group)) }
    }

    private func perform(_ action: ProjectRowAction) {
        switch action {
        case .sync(let project): previewProject = project
        case .configure(let project): configurationProject = project
        case .edit(let project): editing = project
        case .adopt(let project): adopting = project
        case .plugins(let project): managingPlugins = project
        case .delete(let project): deleting = project
        case .syncGroup(let group): syncScope = SyncScope(ids: Set(group.projects.map(\.id)), title: "Synchronizacja: \(group.name)")
        case .rootSettings(let root): editingRoot = root
        case .setUpRoot(let group): settingUpRoot = group
        case .deleteRoot(let root): deletingRoot = root
        }
    }

    private func syncChecked() { syncScope = SyncScope(ids: Set(checkedProjects.map(\.id)), title: "Synchronizacja zaznaczonych projektów") }

    private var actionBar: some View {
        ActionBar {
            if checkedProjects.count < 2 {
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
                Text("Wybrano \(PolishNoun.project(checkedProjects.count))").rowMetadata()
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
                Button("Odznacz") { selection.removeAll() }.buttonStyle(.bordered)
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

    private func groupExpansion(_ path: String) -> Binding<Bool> {
        // A search or a filter opens every group: hiding a match inside a collapsed folder would look like no match.
        Binding(get: { isFiltering || !collapsedGroups.contains(path) }, set: { open in
            if open { collapsedGroups.remove(path) } else { collapsedGroups.insert(path) }
        })
    }
}
