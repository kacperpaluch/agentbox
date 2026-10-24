import SwiftUI
import SkillboxCore

/// A new project with its first choice, or an existing one's name and folder. An existing project's
/// choice is edited in the inspector; repeating the whole form here meant two places to change it.
struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.enabledTools) private var enabledTools
    let skills: [Skill]
    let servers: [MCPServer]
    let docs: [AgentDoc]
    var claudePlugins: [ClaudePluginDefinition] = []
    let project: Project?
    /// The parent folder this project belongs to, when it came from one.
    var root: ProjectRoot?
    /// The project as synchronization sees it right now. When it follows the folder, this fills the
    /// form with what it actually gets, so switching to its own settings starts from today's state
    /// instead of an empty editor.
    var inheritedFrom: Project?
    /// What this project has attached today. For a project that follows its folder this is filled
    /// with the folder's values, so switching to own settings starts from what it actually gets.
    let initialSelection: AttachmentSelection
    /// Reports whether the save succeeded. The form closed on the click, so a rejected name or
    /// a vanished folder threw away everything the user had typed.
    let onSave: (Project, AttachmentSelection) async -> Bool
    @State private var saving = false
    @State private var name = ""
    @State private var path = ""
    @State private var selection = AttachmentSelection(tools: Tool.allCases)
    @State private var manageGitignore = false
    @State private var usesOwnSettings = true
    @State private var start = ProjectStart.defaults

    var body: some View {
        // The actions sit outside the ScrollView: this form is long enough that they used to scroll
        // out of reach, and a sheet taller than the window put them under the Dock entirely.
        VStack(spacing: 0) {
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text(project == nil ? "Nowy projekt" : "Nazwa i folder").font(.title2.bold())
                TextField("Nazwa", text: $name)
                HStack { TextField("Folder projektu", text: $path); Button("Wybierz…") { chooseFolder() } }
                if project == nil {
                    ProjectStartPicker(start: $start)
                    AttachmentPicker(skills: skills, servers: servers, docs: docs, claudePlugins: claudePlugins, selection: $selection, manageGitignore: $manageGitignore)
                }
            }.padding(24) }
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Zapisz") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || name.isEmpty || path.isEmpty || (usesOwnSettings && selection.tools.isEmpty))
            }
        }
        .sheetFrame(width: 700, height: project == nil ? 640 : 260)
        .onAppear { load() }
        .onChange(of: start) { selection = start == .defaults ? initialSelection : AttachmentSelection(tools: enabledTools) }
    }

    private func load() {
        selection = initialSelection
        guard let project else { manageGitignore = true; return }
        name = project.name; path = project.path
        usesOwnSettings = root == nil || project.overridesRoot == true
        let source = usesOwnSettings ? project : (inheritedFrom ?? project)
        selection.tools = source.tools
        selection.skillIDs = source.skillIDs
        selection.skillTags = source.tags
        selection.excludedSkillIDs = source.excludedSkillIDs ?? []
        manageGitignore = source.manageGitignore ?? false
    }

    private func save() async -> Bool {
        saving = true; defer { saving = false }
        let follows = root != nil && !usesOwnSettings
        // A project following its folder stores nothing of its own. Keeping a copy would look like
        // a second source of truth and would resurface the moment the folder's settings changed.
        let saved = Project(
            id: project?.id ?? UUID(), name: name, path: path,
            tools: follows ? [] : selection.tools,
            skillIDs: follows ? [] : selection.skillIDs,
            tags: follows ? [] : selection.skillTags,
            excludedSkillIDs: follows || selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs,
            manageGitignore: follows ? nil : manageGitignore,
            rootID: project?.rootID,
            overridesRoot: root == nil ? nil : (usesOwnSettings ? true : nil))
        return await onSave(saved, follows ? AttachmentSelection() : selection)
    }

    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { path = panel.url?.path ?? path } }
}
