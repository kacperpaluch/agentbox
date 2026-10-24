import SwiftUI
import SkillboxCore

/// The library's fourth kind of entry: a plugin definition, reusable across projects. It behaves
/// like the skill and MCP panes — list, search, correct, remove — because a definition that can
/// only be added is a definition a typo makes useless.
struct ClaudePluginLibraryPane: View {
    let model: AppModel
    let search: String
    @State private var editing: ClaudePluginDefinition?
    @State private var adding = false
    @State private var deleting: ClaudePluginDefinition?
    /// Read while the dialog is open, so the question says how far the deletion reaches.
    @State private var usageForDeletion: UsageReport?
    /// Return or a double click opens the definition, as in the other library lists.
    @State private var selected: UUID?
    var visible: [ClaudePluginDefinition] { model.claudePluginLibrary.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.plugin.localizedStandardContains(search) || $0.marketplace.localizedStandardContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            ActionBar { Button { adding = true } label: { Label("Dodaj plugin", systemImage: "plus") }.buttonStyle(.borderedProminent); Spacer(); Text("\(visible.count) w bibliotece").rowMetadata() }
            List(visible, selection: $selected) { item in
                HStack(alignment: .top, spacing: Space.row) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.row) { Text(item.name).rowTitle(); MetaBadge(text: item.scope.displayName) }
                        Text(item.plugin).rowMetadata()
                        Text(item.marketplace.isEmpty ? "bez marketplace’u" : item.marketplace).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RowMenu {
                        Button("Edytuj…") { editing = item }
                        Divider()
                        Button("Usuń z biblioteki…", role: .destructive) { deleting = item }
                    }
                }.padding(.vertical, 5)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let item = model.claudePluginLibrary.first(where: { ids.contains($0.id) }) {
                    Button("Edytuj…") { editing = item }
                    Divider()
                    Button("Usuń z biblioteki…", role: .destructive) { deleting = item }
                }
            } primaryAction: { ids in editing = ids.count == 1 ? model.claudePluginLibrary.first { ids.contains($0.id) } : nil }
        }
        .sheet(isPresented: $adding) { ClaudePluginEditor(model: model, definition: nil) }
        .sheet(item: $editing) { item in ClaudePluginEditor(model: model, definition: item) }
        .confirmationDialog("Usunąć plugin \(deleting?.name ?? "") z biblioteki?", item: $deleting) { deleting in
            Button("Usuń z biblioteki", role: .destructive) { Task { await model.deleteLibraryClaudePlugin(deleting) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("\((usageForDeletion?.summary).map { "Wybrany przez: \($0). " } ?? "")Definicja zniknie z biblioteki i z wyboru projektów. Zainstalowane kopie usuniesz w inspektorze projektu, w zakładce Pluginy.") }
        .task(id: deleting?.id) { usageForDeletion = deleting == nil ? nil : await model.usage(ofPlugin: deleting!.id) }
    }
}
