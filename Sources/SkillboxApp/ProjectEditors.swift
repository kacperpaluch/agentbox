import SwiftUI
import AppKit
import Combine
import SkillboxCore

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
                HStack { Button("Zaznacz wszystkie") { following = Set(projects.map(\.id)) }; Button("Wyczyść") { following.removeAll() } }
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
