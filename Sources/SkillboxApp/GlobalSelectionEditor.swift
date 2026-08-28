import SwiftUI
import SkillboxCore

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
                Text("Skille globalne").font(.title2.bold())
                Text("Te skille trafiają do katalogu użytkownika i są widoczne we wszystkich sesjach wybranego klienta, niezależnie od projektu.").foregroundStyle(.secondary)
                GroupBox("Gdzie trafią") { VStack(alignment: .leading, spacing: 4) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        if selection.tools.contains(tool) {
                            Text(tool.globalSkillsURL().path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    if selection.tools.isEmpty { Text("Nie wybrano żadnego narzędzia.").font(.caption).foregroundStyle(.secondary) }
                }.padding(6) }

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
