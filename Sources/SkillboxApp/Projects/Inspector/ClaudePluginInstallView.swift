import SwiftUI
import SkillboxCore

/// Installs one Claude plugin by hand, without a definition in the library. Rare enough to live in
/// the inspector's "⋯" menu; a plugin used in more projects belongs in `Biblioteka → Pluginy`.
struct ClaudePluginInstallView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let project: Project
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var scope: ClaudePluginScope = .project
    @State private var confirming = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.section) {
                Text("Zainstaluj plugin Claude").font(.title2.bold())
                Text(project.path).rowMetadata().lineLimit(1).truncationMode(.middle)
                Label("Pluginy mogą dodawać hooki, MCP i programy wykonywalne. Instaluj tylko źródła, którym ufasz.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                TextField("Marketplace (opcjonalnie)", text: $marketplace).help("Np. AgriciDaniel/claude-seo")
                TextField("Plugin", text: $plugin).help("Np. claude-seo@agricidaniel-claude-seo")
                Picker("Zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Spacer()
            }
            .padding(24)
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Zainstaluj…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }
        }
        .sheetFrame(width: 520, height: 340)
        .confirmationDialog("Zainstalować plugin w projekcie?", isPresented: $confirming) {
            Button("Zainstaluj", role: .destructive) {
                let requested = marketplace.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    // The sheet stays open on failure, with the reason next to the fields.
                    if await model.installClaudePlugin(project: project, marketplace: requested.isEmpty ? nil : requested, plugin: plugin, scope: scope) { dismiss() }
                    else { error = model.message }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Claude Code pobierze „\(plugin)” i może aktywować jego hooki, MCP i pliki wykonywalne. Zakres: \(scope.displayName).") }
    }
}
