import SwiftUI
import SkillboxCore

/// This Mac, shown like any other row of Projekty: skills copied to the user's directories, so every
/// session of a client sees them whatever the project. It used to be a sheet behind `Więcej`, one
/// row away from `Serwery klientów`, which means the opposite thing; both now live on this row.
struct MacInspector: View {
    let model: AppModel
    @State private var selection = AttachmentSelection()
    @State private var saved = AttachmentSelection()
    @State private var previews: [SkillSyncPreview] = []
    @State private var error = ""
    @State private var showClientServers = false

    private var isDirty: Bool { selection != saved }
    private var hasChanges: Bool { previews.contains { !$0.added.isEmpty || !$0.updated.isEmpty || !$0.removed.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.row) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Ten Mac", systemImage: "laptopcomputer").font(.title3.bold())
                    Spacer()
                    Button("Serwery klientów…") { showClientServers = true }
                }
                Text("Skille widoczne we wszystkich sesjach wybranych klientów.").rowMetadata()
                if model.globalState != nil { ProjectStatusBadge(state: model.globalState) }
            }
            .padding(Space.page)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, selection: $selection, includesServersAndDocs: false)
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                    GroupBox("Podgląd") {
                        VStack(alignment: .leading, spacing: Space.row) {
                            if previews.isEmpty { Text("Nie wybrano żadnego narzędzia.").rowMetadata() }
                            ForEach(previews, id: \.tool) { item in
                                VStack(alignment: .leading, spacing: Space.tight) {
                                    Text(item.target).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                    SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                                }
                            }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.page)
            }
            SheetFooter {
                Button("Zapisz") { Task { _ = await save() } }.disabled(!isDirty || model.isWorking)
                // A failed save must not go on to apply the selection that was there before.
                Button(isDirty ? "Zapisz i synchronizuj" : "Synchronizuj") {
                    Task { if await save() { if !(await model.syncGlobal()) { error = model.message }; await refresh() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(isDirty || hasChanges) || model.isWorking)
            }
        }
        .sheet(isPresented: $showClientServers) { ClientServersView(model: model) }
        .onChange(of: selection) { Task { await refresh() } }
        .onChange(of: model.generation) { if !isDirty { load() } }
        .task { load(); await refresh() }
    }

    private func load() { saved = model.global; selection = saved }

    private func save() async -> Bool {
        guard isDirty else { return true }
        guard await model.saveSelection(selection, for: .global, named: "skille globalne") else { error = model.message; return false }
        saved = selection
        return true
    }

    /// The preview follows the checkboxes, not the last saved choice.
    private func refresh() async {
        do { previews = try await model.previewGlobalSync(selection); error = "" }
        catch { previews = []; self.error = error.localizedDescription }
    }
}
