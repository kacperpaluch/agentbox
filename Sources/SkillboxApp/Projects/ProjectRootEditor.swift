import SwiftUI
import SkillboxCore

/// Settings shared by every project in a parent folder. Editing them here is the point of adding a
/// folder in a batch: one change reaches all its projects instead of being repeated in each one.
struct ProjectRootEditor: View {
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let servers: [MCPServer]
    let docs: [AgentDoc]
    let claudePlugins: [ClaudePluginDefinition]
    let root: ProjectRoot
    let followingProjects: Int
    let initialSelection: AttachmentSelection
    /// See `ProjectEditor.onSave`.
    let onSave: (ProjectRoot, AttachmentSelection) async -> Bool
    @State private var saving = false
    @State private var name = ""
    @State private var selection = AttachmentSelection()
    @State private var manageGitignore = false
    @State private var watchesNewFolders = true
    @State private var ignoredPaths: [String] = []

    var body: some View {
        // Actions stay pinned below the scrolling form: on a short display they used to
        // scroll out of reach, or sit under the Dock entirely.
        VStack(spacing: 0) {
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text("Ustawienia folderu nadrzędnego").font(.title2.bold())
                TextField("Nazwa", text: $name)
                Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(followingProjects == 0
                     ? "Żaden projekt nie korzysta jeszcze z tych ustawień."
                     : "Obejmują \(followingProjects) projektów; te z własnymi ustawieniami zostają nietknięte.")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox("Nowe podfoldery") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Pytaj, gdy w tym folderze pojawi się nowy podfolder", isOn: $watchesNewFolders).toggleStyle(.checkbox)
                        Text("Agentbox zaproponuje dodanie i synchronizację nowych podfolderów.").font(.caption).foregroundStyle(.secondary)
                        if !ignoredPaths.isEmpty {
                            HStack {
                                Text("Pominięte podfoldery: \(ignoredPaths.count)").font(.caption).foregroundStyle(.secondary)
                                Button("Przywróć pominięte") { ignoredPaths = [] }.controlSize(.small)
                            }
                            Text(ignoredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.padding(6)
                }
                AttachmentPicker(skills: skills, servers: servers, docs: docs, claudePlugins: claudePlugins, selection: $selection, manageGitignore: $manageGitignore)
            }.padding(24) }
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Zapisz") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || name.isEmpty || selection.tools.isEmpty)
            }
        }
        .sheetFrame(width: 700, height: 640)
        .onAppear {
            name = root.name
            selection = initialSelection
            manageGitignore = root.manageGitignore ?? false
            watchesNewFolders = root.watchesNewFolders; ignoredPaths = root.ignoredPaths
        }
    }

    private func save() async -> Bool {
        saving = true; defer { saving = false }
        let updated = ProjectRoot(id: root.id, name: name, path: root.path, tools: selection.tools, skillIDs: selection.skillIDs, tags: selection.skillTags, excludedSkillIDs: selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs, manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders, ignoredPaths: ignoredPaths)
        return await onSave(updated, selection)
    }
}
