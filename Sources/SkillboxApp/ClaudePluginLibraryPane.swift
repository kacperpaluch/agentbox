import SwiftUI
import SkillboxCore

/// The library's fourth kind of entry: a plugin definition, reusable across projects. It behaves
/// like the skill and MCP panes — list, search, correct, remove — because a definition that can
/// only be added is a definition a typo makes useless.
struct ClaudePluginLibraryPane: View {
    @ObservedObject var model: AppModel
    let search: String
    @State private var editing: ClaudePluginDefinition?
    @State private var adding = false
    @State private var deleting: ClaudePluginDefinition?
    var visible: [ClaudePluginDefinition] { model.claudePluginLibrary.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.plugin.localizedCaseInsensitiveContains(search) || $0.marketplace.localizedCaseInsensitiveContains(search) } }
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
        .confirmationDialog("Usunąć plugin \(deleting?.name ?? "") z biblioteki?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Usuń z biblioteki", role: .destructive) { if let deleting { Task { await model.deleteLibraryClaudePlugin(deleting) } }; deleting = nil }
            Button("Anuluj", role: .cancel) { deleting = nil }
        } message: { Text("Definicja zniknie z biblioteki i z wyboru wszystkich projektów, więc synchronizacja przestanie go instalować. Pluginy już zainstalowane przez Claude Code zostają na dysku — usuń je w `Projekty → … → Pluginy Claude…`.") }
    }
}

/// One form for both adding and correcting. Editing keeps the definition's identity, so every
/// project that already selected this plugin follows the correction instead of quietly keeping the
/// old identifier.
private struct ClaudePluginEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let definition: ClaudePluginDefinition?
    @State private var name = ""
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var scope: ClaudePluginScope = .project
    @State private var error = ""

    private var isEditing: Bool { definition != nil }
    private var trimmed: (name: String, marketplace: String, plugin: String) {
        (name.trimmingCharacters(in: .whitespacesAndNewlines),
         marketplace.trimmingCharacters(in: .whitespacesAndNewlines),
         plugin.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edytuj plugin Claude" : "Dodaj plugin Claude").font(.title2.bold())
            Text(isEditing
                 ? "Poprawka obowiązuje wszystkie projekty, które mają ten plugin zaznaczony."
                 : "Definicja trafia do wspólnej biblioteki. Wybierzesz ją potem dla projektu.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Nazwa", text: $name)
            TextField("Marketplace, np. AgriciDaniel/claude-seo (opcjonalnie)", text: $marketplace)
            TextField("Plugin, np. claude-seo@agricidaniel-claude-seo", text: $plugin)
            Picker("Domyślny zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                Button(isEditing ? "Zapisz" : "Dodaj") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.name.isEmpty || trimmed.plugin.isEmpty || model.isWorking)
            }
        }
        .padding(24).sheetFrame(width: 560, height: 380)
        .onAppear { load() }
    }

    private func load() {
        guard let definition else { return }
        name = definition.name; marketplace = definition.marketplace; plugin = definition.plugin; scope = definition.scope
    }

    /// The sheet stays open when the library refuses the values, so the reason sits next to the
    /// fields that caused it instead of only in the status bar.
    private func save() async {
        error = ""
        let values = trimmed
        let edited = ClaudePluginDefinition(id: definition?.id ?? UUID(), name: values.name, marketplace: values.marketplace, plugin: values.plugin, scope: scope)
        let saved = isEditing
            ? await model.updateLibraryClaudePlugin(edited)
            : await model.addLibraryClaudePlugin(edited)
        if saved { dismiss() } else { error = model.message }
    }
}
