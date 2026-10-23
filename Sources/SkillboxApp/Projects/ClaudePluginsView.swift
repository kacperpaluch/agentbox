import SwiftUI
import SkillboxCore

struct ClaudePluginsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let project: Project
    @State private var plugins: [ClaudePlugin]?
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var scope: ClaudePluginScope = .project
    @State private var installConfirmation = false
    @State private var uninstalling: ClaudePlugin?
    @State private var error = ""
    @State private var selectedLibraryPlugins = Set<UUID>()
    /// Set when the stored choice could not be read. Saving is blocked then: the checkboxes would
    /// show nothing selected, and saving that would clear the real selection.
    @State private var selectionError = ""
    private var inheritsRoot: Bool { model.inheritsRoot(project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pluginy Claude").font(.title2.bold())
            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            Text("Pluginy mogą dodawać skille, agentów, hooki, MCP i programy wykonywalne. Instaluj wyłącznie źródła, którym ufasz. Agentbox przekazuje instalację do Claude Code, aby zachować jego zależności i cache.").font(.caption).foregroundStyle(.orange)
            GroupBox("Z biblioteki Agentbox") {
                if model.claudePluginLibrary.isEmpty { Text("Dodaj definicję w Biblioteka → Pluginy.").font(.caption).foregroundStyle(.secondary).padding(6) }
                else { VStack(alignment: .leading, spacing: 5) {
                    // A project following its folder shares one selection with every other project
                    // there, so saving here would change all of them at once. The choice is shown —
                    // it is what this project gets — but it stays the folder's to change.
                    if inheritsRoot {
                        Label("Wybór pochodzi z folderu nadrzędnego i obowiązuje wszystkie projekty w nim. Zmień go w ustawieniach folderu albo nadaj projektowi własne ustawienia.", systemImage: "arrow.down.right.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.claudePluginLibrary) { item in Toggle(item.name, isOn: Binding(get: { selectedLibraryPlugins.contains(item.id) }, set: { enabled in if enabled { selectedLibraryPlugins.insert(item.id) } else { selectedLibraryPlugins.remove(item.id) } })).toggleStyle(.checkbox).help(item.plugin).disabled(inheritsRoot) }
                    if !selectionError.isEmpty { Label("Nie udało się wczytać wyboru: \(selectionError)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    HStack { Spacer(); Button("Zapisz wybór") { Task { await model.saveClaudePluginSelection(project: project, ids: Array(selectedLibraryPlugins)); await reloadSelection() } }.buttonStyle(.bordered).disabled(model.isWorking || inheritsRoot || !selectionError.isEmpty) }
                }.padding(6) }
            }
            GroupBox("Zainstaluj plugin") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Marketplace, np. AgriciDaniel/claude-seo (opcjonalnie)", text: $marketplace)
                    TextField("Plugin, np. claude-seo@agricidaniel-claude-seo", text: $plugin)
                    Picker("Zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
                    HStack { Spacer(); Button("Zainstaluj…") { installConfirmation = true }.buttonStyle(.borderedProminent).disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking) }
                }.padding(6)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("Aktywne w tym projekcie") {
                if plugins == nil { ProgressView().padding(8) }
                else if plugins?.isEmpty == true { Text("Brak pluginów Claude w zakresie projektu lub lokalnym.").font(.caption).foregroundStyle(.secondary).padding(8) }
                else { List(plugins ?? []) { item in
                    HStack { VStack(alignment: .leading, spacing: 2) { Text(item.id).fontWeight(.medium); Text(item.scope.displayName).font(.caption).foregroundStyle(.secondary) }; Spacer(); if !item.enabled { MetaBadge(text: "wyłączony", tint: .secondary) }; Button("Usuń", role: .destructive) { uninstalling = item }.buttonStyle(.bordered).controlSize(.small).disabled(model.isWorking) }.padding(.vertical, 2)
                }.frame(minHeight: 120) }
            }
            HStack { Spacer(); Button("Zamknij") { dismiss() } }
        }
        .padding(24).sheetFrame(width: 680, height: 590)
        .task { await reload(); await reloadSelection() }
        .confirmationDialog("Zainstalować plugin w projekcie?", isPresented: $installConfirmation) {
            Button("Zainstaluj", role: .destructive) { let requestedMarketplace = marketplace.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.installClaudePlugin(project: project, marketplace: requestedMarketplace.isEmpty ? nil : requestedMarketplace, plugin: plugin, scope: scope); await reload() } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Claude Code pobierze plugin „\(plugin)” i może aktywować jego hooki, MCP oraz pliki wykonywalne. Zakres: \(scope.displayName).") }
        .confirmationDialog("Usunąć plugin \(uninstalling?.id ?? "")?", item: $uninstalling) { uninstalling in
            Button("Usuń plugin", role: .destructive) { Task { await model.uninstallClaudePlugin(project: project, plugin: uninstalling); self.uninstalling = nil; await reload(); await reloadSelection() } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text(inheritsRoot
            ? "Plugin zostanie wyłączony w tym zakresie projektu przez Claude Code. Wybór z biblioteki należy do folderu nadrzędnego, więc kolejna synchronizacja może go przywrócić."
            : "Plugin zostanie wyłączony w tym zakresie projektu przez Claude Code i zniknie z wyboru dla tego projektu, więc synchronizacja go nie przywróci.") }
    }

    private func reload() async {
        do { plugins = try await model.claudePlugins(for: project); error = "" }
        catch let loadError { plugins = []; error = loadError.localizedDescription }
    }

    /// Read back instead of assumed: removing a plugin also drops it from the selection, and the
    /// checkboxes have to show what is actually stored.
    private func reloadSelection() async {
        do { selectedLibraryPlugins = Set(try await model.selectedClaudePluginIDs(for: project)); selectionError = "" }
        catch { selectedLibraryPlugins = []; selectionError = error.localizedDescription }
    }
}
