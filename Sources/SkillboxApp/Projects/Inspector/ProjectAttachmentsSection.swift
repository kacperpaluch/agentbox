import SwiftUI
import SkillboxCore

/// The project's choice, edited where its result is shown. Nothing is written until `Zapisz`: a
/// checkbox click that rewrote the library and recomputed every status would make the list jump
/// under the cursor, and a half-made choice is not one the user asked to store.
struct ProjectAttachmentsSection: View {
    let model: AppModel
    let project: Project
    @State private var draft = AttachmentSelection()
    @State private var saved = AttachmentSelection()
    @State private var gitignore = false
    @State private var savedGitignore = false
    @State private var saving = false

    private var isDirty: Bool { draft != saved || gitignore != savedGitignore }
    private var folder: ProjectRoot? { model.inheritsRoot(project) ? model.root(for: project) : nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let folder {
                        Label("Wybór należy do folderu „\(folder.name)” i obejmuje \(PolishNoun.project(model.followers(of: folder))).", systemImage: "folder.badge.gearshape")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, selection: $draft, manageGitignore: $gitignore)
                }
                .padding(Space.page)
            }
            // Pinned, so a change made at the top of a long form can be saved without scrolling.
            SheetFooter {
                if isDirty { Text("Niezapisane zmiany").rowMetadata() }
                Button("Przywróć") { load() }.disabled(!isDirty || saving)
                Button("Zapisz") {
                    Task {
                        saving = true; defer { saving = false }
                        if await model.saveAttachments(draft, manageGitignore: gitignore, for: project) { load() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || saving || model.isWorking || draft.tools.isEmpty)
            }
        }
        .task(id: project.id) { load() }
        // A reload from elsewhere (the CLI, another window) refreshes an untouched form; one being
        // edited keeps the user's checkboxes until they save or revert.
        .onChange(of: model.generation) { if !isDirty { load() } }
    }

    private func load() {
        saved = model.selection(for: .project(project.id), resolvingInheritance: true)
        savedGitignore = (folder?.manageGitignore ?? model.storedProject(id: project.id)?.manageGitignore) ?? false
        draft = saved; gitignore = savedGitignore
    }
}
