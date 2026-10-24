import SwiftUI
import SkillboxCore

/// What Claude Code itself reports as installed in the project, at the end of the overview. Silent
/// when there is nothing: a heading over an empty box for almost every project was noise.
struct ClaudeInstalledPluginsSection: View {
    let model: AppModel
    let project: Project
    @State private var plugins: [ClaudePlugin] = []
    @State private var error = ""
    @State private var uninstalling: ClaudePlugin?
    private var inheritsRoot: Bool { model.inheritsRoot(project) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            if !plugins.isEmpty || !error.isEmpty {
                Text("Zainstalowane przez Claude Code").sectionLabel().padding(.top, Space.row)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(plugins) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(item.id).rowTitle(); Text(item.scope.displayName).rowMetadata() }
                    Spacer()
                    if !item.enabled { MetaBadge(text: "wyłączony") }
                    Button("Usuń", role: .destructive) { uninstalling = item }.controlSize(.small).disabled(model.isWorking)
                }
                Divider()
            }
        }
        .task(id: [AnyHashable(project.id), AnyHashable(model.generation)]) { await reload() }
        .confirmationDialog("Usunąć plugin \(uninstalling?.id ?? "")?", item: $uninstalling) { uninstalling in
            Button("Usuń plugin", role: .destructive) { Task { await model.uninstallClaudePlugin(project: project, plugin: uninstalling); self.uninstalling = nil } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text(inheritsRoot
            ? "Wybór należy do folderu nadrzędnego, więc kolejna synchronizacja może go przywrócić."
            : "Plugin zniknie też z wyboru projektu, więc synchronizacja go nie przywróci.") }
    }

    private func reload() async {
        do { plugins = try await model.claudePlugins(for: project); error = "" }
        catch let loadError { plugins = []; error = loadError.localizedDescription }
    }
}
