import SwiftUI
import SkillboxCore

/// The MCP-server half of the library. Search and the tag filter come from `LibraryView`.
struct MCPPane: View {
    let model: AppModel
    let search: String
    let selectedTag: String
    @State private var editingServer: MCPServer?
    @State private var serverToDuplicate: MCPServer?
    @State private var serverToDelete: MCPServer?
    /// Read while the dialog is open, so the question says how far the deletion reaches.
    @State private var usageForDeletion: UsageReport?
    @State private var showAdd = false
    @State private var bulkJSON: IdentifiableString?
    @State private var checked = Set<UUID>()
    /// The highlighted row. Return or a double click opens it, as in Finder; a tap gesture reached
    /// neither the keyboard nor VoiceOver.
    @State private var selected: UUID?
    @State private var showBatchTags = false
    private var existingTags: [String] { Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted() }
    private var filtered: [MCPServer] {
        model.mcp.servers
            .filter { libraryMatches(name: $0.name, id: $0.name, tags: $0.tags ?? [], search: search, selectedTag: selectedTag) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if model.mcp.servers.isEmpty {
                ContentUnavailableView("Brak serwerów MCP", systemImage: "network", description: Text("Zaimportuj konfigurację z JSON albo dodaj serwer ręcznie."))
            } else if filtered.isEmpty {
                ContentUnavailableView("Nic nie pasuje", systemImage: "magnifyingglass", description: Text("Zmień wyszukiwanie albo wybrany tag."))
            } else {
                List(selection: $selected) {
                    ForEach(filtered) { server in
                        HStack(alignment: .top, spacing: Space.row + 1) {
                            Toggle("Zaznacz \(server.name)", isOn: checkBinding(server.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
                            MCPServerRow(server: server, usageKey: AnyHashable([AnyHashable(server.id), AnyHashable(server.tags), AnyHashable(model.selections)]), usage: { await model.usage(ofServer: server.id) }, onDetails: { editingServer = server }, onDuplicate: { serverToDuplicate = server }, onDelete: { serverToDelete = server })
                        }
                        .tag(server.id)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let server = server(in: ids) {
                        Button("Szczegóły…") { editingServer = server }
                        Button("Duplikuj…") { serverToDuplicate = server }
                        Divider()
                        Button("Usuń…", role: .destructive) { serverToDelete = server }
                    }
                } primaryAction: { ids in editingServer = server(in: ids) }
            }
        }
        .sheet(isPresented: $showAdd) {
            MCPImportView(model: model) {
                editingServer = MCPServer(name: "", transport: .stdio)
            }
        }
        .sheet(item: $editingServer) { server in MCPServerEditor(model: model, server: server, existingTags: existingTags) }
        .sheet(item: $serverToDuplicate) { server in MCPDuplicateView(model: model, server: server) }
        .sheet(item: $bulkJSON) { text in MCPBulkJSONView(model: model, text: text.value) }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: existingTags, noun: .server) { text in let ok = await model.addMCPServerTags(checked, text: text); if ok { checked.removeAll() }; return ok } }
        .confirmationDialog("Usunąć serwer \(serverToDelete?.name ?? "")?", item: $serverToDelete) { serverToDelete in Button("Usuń", role: .destructive) { Task { await model.deleteMCPServer(serverToDelete.id) } }; Button("Anuluj", role: .cancel) {} } message: { _ in Text(serverToDelete.map { server in
            (usageForDeletion?.summary).map { "Używany przez: \($0). Serwer zostanie usunięty także z przypisań projektów." }
                ?? "Serwer \(server.name) nie jest przypisany do żadnego projektu."
        } ?? "Serwer zostanie usunięty także z bezpośrednich przypisań projektów.") }
        .task(id: serverToDelete?.id) { usageForDeletion = serverToDelete.map { _ in UsageReport() }; if let serverToDelete { usageForDeletion = await model.usage(ofServer: serverToDelete.id) } }
    }

    // Same contextual-bar pattern as the Library: add actions when nothing is checked, a selection
    // bar the moment something is.
    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { showAdd = true } label: { Label("Dodaj serwer", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { Task { bulkJSON = IdentifiableString(value: await model.exportMCPConfigurationJSON()) } } label: {
                    Label("Edytuj całą konfigurację", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
                .disabled(model.mcp.servers.isEmpty)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            Text(filtered.count == model.mcp.servers.count ? PolishNoun.server(model.mcp.servers.count) : "\(filtered.count) z \(model.mcp.servers.count)").rowMetadata()
        }
    }

    private func server(in ids: Set<UUID>) -> MCPServer? { ids.count == 1 ? model.mcp.servers.first { ids.contains($0.id) } : nil }
    private func checkBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }

}
