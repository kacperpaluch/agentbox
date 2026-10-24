import SwiftUI
import SkillboxCore

/// A local template copied into the new-project form. It deliberately has no preview or sync
/// action: saving it changes only future projects, never an already configured folder.
struct ProjectDefaultsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var selection = AttachmentSelection(tools: Tool.allCases)
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Domyślne dla nowych projektów").font(.title2.bold())
                    Text("Ten zestaw wypełnia formularz nowego projektu. Nie zmienia istniejących.")
                        .foregroundStyle(.secondary)
                    AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, selection: $selection)
                    if !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(24)
            }
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Zapisz domyślne") {
                    Task { if await model.saveProjectDefaults(selection) { dismiss() } else { error = model.message } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.tools.isEmpty || model.isWorking)
            }
        }
        .sheetFrame(width: 700, height: 640)
        .onAppear { selection = model.projectDefaults }
    }
}
