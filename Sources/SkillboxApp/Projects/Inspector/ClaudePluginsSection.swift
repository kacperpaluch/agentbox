import SwiftUI
import SkillboxCore

/// What Claude Code itself reports as installed in the project, and a way to install one plugin by
/// hand. Choosing plugins from the library is part of the project's choice (the `Wybór` tab), so it
/// is no longer repeated here.
struct ClaudePluginsSection: View {
    let model: AppModel
    let project: Project
    @State private var plugins: [ClaudePlugin]?
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var scope: ClaudePluginScope = .project
    @State private var installConfirmation = false
    @State private var uninstalling: ClaudePlugin?
    @State private var error = ""
    private var inheritsRoot: Bool { model.inheritsRoot(project) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Label("Pluginy mogą dodawać hooki, MCP i programy wykonywalne. Instaluj tylko źródła, którym ufasz.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            GroupBox("Zainstalowane w projekcie") {
                VStack(alignment: .leading, spacing: Space.row) {
                    if plugins == nil { ProgressView() }
                    else if plugins?.isEmpty == true { Text("Brak pluginów w zakresie projektu ani lokalnym.").rowMetadata() }
                    else {
                        ForEach(plugins ?? []) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) { Text(item.id).rowTitle(); Text(item.scope.displayName).rowMetadata() }
                                Spacer()
                                if !item.enabled { MetaBadge(text: "wyłączony") }
                                Button("Usuń", role: .destructive) { uninstalling = item }.controlSize(.small).disabled(model.isWorking)
                            }
                        }
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("Zainstaluj ręcznie") {
                VStack(alignment: .leading, spacing: Space.row) {
                    TextField("Marketplace (opcjonalnie)", text: $marketplace).help("Np. AgriciDaniel/claude-seo")
                    TextField("Plugin", text: $plugin).help("Np. claude-seo@agricidaniel-claude-seo")
                    Picker("Zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
                    HStack { Spacer(); Button("Zainstaluj…") { installConfirmation = true }.disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking) }
                }.padding(6)
            }
        }
        .task(id: project.id) { await reload() }
        .confirmationDialog("Zainstalować plugin w projekcie?", isPresented: $installConfirmation) {
            Button("Zainstaluj", role: .destructive) { let requestedMarketplace = marketplace.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.installClaudePlugin(project: project, marketplace: requestedMarketplace.isEmpty ? nil : requestedMarketplace, plugin: plugin, scope: scope); await reload() } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Claude Code pobierze „\(plugin)” i może aktywować jego hooki, MCP i pliki wykonywalne. Zakres: \(scope.displayName).") }
        .confirmationDialog("Usunąć plugin \(uninstalling?.id ?? "")?", item: $uninstalling) { uninstalling in
            Button("Usuń plugin", role: .destructive) { Task { await model.uninstallClaudePlugin(project: project, plugin: uninstalling); self.uninstalling = nil; await reload() } }
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
