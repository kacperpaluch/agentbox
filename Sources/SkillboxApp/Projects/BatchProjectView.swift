import SwiftUI
import SkillboxCore

struct BatchProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.enabledTools) private var enabledTools
    @State private var start = ProjectStart.defaults
    let skills: [Skill]; let servers: [MCPServer]; let docs: [AgentDoc]; let existingProjects: [Project]; let existingRoots: [ProjectRoot]
    let claudePlugins: [ClaudePluginDefinition]
    let initialSelection: AttachmentSelection
    /// See `ProjectEditor.onSave`.
    let onSave: (BatchProjectRequest) async -> Bool
    @State private var saving = false
    @State private var root = ""; @State private var folders: [URL] = []; @State private var selectedFolders = Set<String>()
    @State private var selection = AttachmentSelection(tools: Tool.allCases); @State private var manageGitignore = true; @State private var scanError = ""
    @State private var sharedSettings = true; @State private var watchesNewFolders = true; @State private var onlyFutureFolders = true; @State private var rootName = ""
    private var existingPaths: Set<String> { Set(existingProjects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) }
    private var availableFolders: [URL] { folders.filter { !existingPaths.contains($0.standardizedFileURL.path) } }
    private var rootAlreadyAdded: Bool { !root.isEmpty && existingRoots.contains { URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path } }
    private var rootNameTaken: Bool { existingRoots.contains { $0.name.caseInsensitiveCompare(rootName) == .orderedSame } }

    var body: some View { VStack(spacing: 0) { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text("Dodaj wiele projektów").font(.title2.bold())
        Text("Ustawienia zapisują się na folderze nadrzędnym i obowiązują jego podfoldery.").foregroundStyle(.secondary)
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
                Text("Każdy projekt dostanie własną kopię wyboru poniżej.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(6) }
        GroupBox("Podfoldery") { VStack(alignment: .leading, spacing: 7) {
            if folders.isEmpty { Text("Wybierz folder, aby znaleźć projekty.").foregroundStyle(.secondary) }
            else { HStack { Button("Zaznacz dostępne") { selectedFolders = Set(availableFolders.map(\.path)) }; Button("Wyczyść") { selectedFolders.removeAll() }; Spacer(); Text("Wybrano \(selectedFolders.count)").foregroundStyle(.secondary) }; ForEach(folders, id: \.path) { folder in let exists = existingPaths.contains(folder.standardizedFileURL.path); Toggle(isOn: folderBinding(folder)) { HStack { Image(systemName: "folder"); Text(folder.lastPathComponent); Spacer(); if exists { Text("już dodany").font(.caption).foregroundStyle(.secondary) } } }.toggleStyle(.checkbox).disabled(exists) } }
        }.padding(6) }.frame(maxHeight: 230)
        ProjectStartPicker(start: $start)
        AttachmentPicker(skills: skills, servers: servers, docs: docs, claudePlugins: claudePlugins, selection: $selection, manageGitignore: $manageGitignore)
    }.padding(24) }
    // Pinned below the scrolling form, so the action stays reachable on any display.
    SheetFooter {
        Button("Anuluj") { dismiss() }
        Button(sharedSettings ? "Dodaj folder i \(PolishNoun.project(selectedFolders.count))" : "Dodaj \(PolishNoun.project(selectedFolders.count))") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || saveDisabled)
    } }.sheetFrame(width: 760, height: 640).onAppear { selection = initialSelection }
        .onChange(of: start) { selection = start == .defaults ? initialSelection : AttachmentSelection(tools: enabledTools) } }

    private var saveDisabled: Bool {
        if selection.tools.isEmpty || rootAlreadyAdded { return true }
        if sharedSettings { return root.isEmpty || rootName.isEmpty || rootNameTaken }
        return selectedFolders.isEmpty
    }

    private func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; guard panel.runModal() == .OK, let url = panel.url else { return }; root = url.path; rootName = url.lastPathComponent; do { folders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }; selectedFolders = Set(availableFolders.map(\.path)); scanError = "" } catch { folders = []; selectedFolders = []; scanError = error.localizedDescription } }
    private func folderBinding(_ folder: URL) -> Binding<Bool> { Binding(get: { selectedFolders.contains(folder.path) }, set: { if $0 { selectedFolders.insert(folder.path) } else { selectedFolders.remove(folder.path) } }) }

    private func save() async -> Bool {
        saving = true; defer { saving = false }
        let chosen = availableFolders.filter { selectedFolders.contains($0.path) }
        let exclusions = selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs
        guard sharedSettings else {
            let projects = chosen.map { Project(name: $0.lastPathComponent, path: $0.path, tools: selection.tools, skillIDs: selection.skillIDs, tags: selection.skillTags, excludedSkillIDs: exclusions, manageGitignore: manageGitignore) }
            return await onSave(BatchProjectRequest(root: nil, projects: projects, selection: selection))
        }
        let folder = ProjectRoot(name: rootName, path: root, tools: selection.tools, skillIDs: selection.skillIDs, tags: selection.skillTags, excludedSkillIDs: exclusions, manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders)
        return await onSave(BatchProjectRequest(root: folder, folders: chosen.map(\.path), selection: selection, treatingExistingAsKnown: onlyFutureFolders))
    }
}
