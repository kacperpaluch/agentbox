import SwiftUI
import SkillboxCore

/// A local template copied into the new-project form. It deliberately has no preview or sync
/// action: saving it changes only future projects, never an already configured folder.
struct ProjectDefaultsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var selection = AttachmentSelection(tools: Tool.allCases)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Domyślne dla nowych projektów").font(.title2.bold())
                    Text("Ten zestaw pojawi się w formularzu przy tworzeniu pojedynczego projektu lub grupy projektów. Możesz go wtedy dowolnie zmienić; zapis tutaj nie wpływa na istniejące projekty.")
                        .foregroundStyle(.secondary)
                    AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, selection: $selection)
                }
                .padding(24)
            }
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Zapisz domyślne") {
                    Task {
                        await model.saveProjectDefaults(selection)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.tools.isEmpty || model.isWorking)
            }
        }
        .sheetFrame(width: 700, height: 640)
        .onAppear { selection = model.projectDefaults }
    }
}

/// The Mac itself, edited exactly like a project or a parent folder.
///
/// This used to be its own sidebar section called "Globalne", which sat one row away from another
/// called "MCP globalne" and meant the opposite thing — one pushes your skills out to
/// `~/.claude/skills`, the other only opts out of servers somebody else declared. Globalne is not a
/// different kind of screen, though: it is a place attachments land, like every row in Projekty. So
/// it moved there, and this is the same sheet the other rows open.
struct GlobalSelectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var selection = AttachmentSelection()
    @State private var previews: [SkillSyncPreview] = []
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text("Skille we wszystkich sesjach").font(.title2.bold())
                Text("Te skille trafiają do katalogu użytkownika i są widoczne we wszystkich sesjach wybranego klienta, niezależnie od projektu.").foregroundStyle(.secondary)
                GroupBox("Gdzie trafią") { VStack(alignment: .leading, spacing: 4) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        if selection.tools.contains(tool) {
                            Text(tool.globalSkillsURL().path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    if selection.tools.isEmpty { Text("Nie wybrano żadnego narzędzia.").font(.caption).foregroundStyle(.secondary) }
                }.padding(6) }

                // No plugin picker here, unlike every project and folder editor: Claude Code installs
                // a plugin into a project folder, and this target has none. Offering the choice would
                // mean saving a selection no synchronization can ever act on.
                AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, selection: $selection, includesServersAndDocs: false)

                if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
                if !previews.isEmpty {
                    GroupBox("Podgląd") { VStack(alignment: .leading, spacing: 10) { ForEach(previews, id: \.tool) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.target).font(.caption).foregroundStyle(.secondary)
                            SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                        }
                    } }.padding(6) }
                }
            }.padding(24) }
            SheetFooter {
                Button("Zamknij") { dismiss() }
                Button("Zapisz wybór") { Task { await save(); await refresh() } }.buttonStyle(.bordered).disabled(model.isWorking)
                Button("Zapisz i synchronizuj") { Task { await save(); if await model.syncGlobal() { dismiss() } } }
                    .buttonStyle(.borderedProminent).disabled(selection.tools.isEmpty || model.isWorking)
            }
        }
        .sheetFrame(width: 700, height: 640)
        .task {
            guard !loaded else { return }
            loaded = true
            selection = model.global
            await refresh()
        }
    }

    private func save() async {
        await model.saveSelection(selection, for: .global, named: "skille globalne")
    }

    private func refresh() async {
        do { previews = try await model.previewGlobalSync(); error = "" }
        catch { previews = []; self.error = error.localizedDescription }
    }
}
