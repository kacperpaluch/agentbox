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
    var visible: [ClaudePluginDefinition] { model.claudePluginLibrary.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.plugin.localizedStandardContains(search) || $0.marketplace.localizedStandardContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            ActionBar { Button { adding = true } label: { Label("Dodaj plugin", systemImage: "plus") }.buttonStyle(.borderedProminent); Spacer(); Text("\(visible.count) w bibliotece").rowMetadata() }
            List(visible) { item in
                HStack(alignment: .top, spacing: Space.row) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.row) { Text(item.name).rowTitle(); MetaBadge(text: item.scope.displayName) }
                        Text(item.plugin).rowMetadata()
                        Text(item.marketplace.isEmpty ? "bez marketplace’u" : item.marketplace).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edytuj", action: { editing = item }).controlSize(.small)
                    RowMenu {
                        Button("Edytuj…") { editing = item }
                        Divider()
                        Button("Usuń z biblioteki…", role: .destructive) { deleting = item }
                    }
                }.padding(.vertical, 5)
            }
        }
        .sheet(isPresented: $adding) { ClaudePluginEditor(model: model, definition: nil) }
        .sheet(item: $editing) { item in ClaudePluginEditor(model: model, definition: item) }
        .confirmationDialog("Usunąć plugin \(deleting?.name ?? "") z biblioteki?", item: $deleting) { deleting in
            Button("Usuń z biblioteki", role: .destructive) { Task { await model.deleteLibraryClaudePlugin(deleting) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("\((usageForDeletion?.summary).map { "Wybrany przez: \($0). " } ?? "")Definicja zniknie z biblioteki i z wyboru wszystkich projektów, więc synchronizacja przestanie go instalować. Pluginy już zainstalowane przez Claude Code zostają na dysku — usuń je w `Projekty → … → Pluginy Claude…`.") }
        .task(id: deleting?.id) { usageForDeletion = deleting == nil ? nil : await model.usage(ofPlugin: deleting!.id) }
    }
}
