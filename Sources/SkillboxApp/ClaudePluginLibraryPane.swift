import SwiftUI
import SkillboxCore

struct ClaudePluginLibraryPane: View {
    @ObservedObject var model: AppModel
    let search: String
    @State private var adding = false
    var visible: [ClaudePluginDefinition] { model.claudePluginLibrary.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.plugin.localizedCaseInsensitiveContains(search) || $0.marketplace.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            ActionBar { Button { adding = true } label: { Label("Dodaj plugin", systemImage: "plus") }.buttonStyle(.borderedProminent); Spacer(); Text("\(visible.count) w bibliotece").rowMetadata() }
            List(visible) { item in VStack(alignment: .leading, spacing: 3) { Text(item.name).rowTitle(); Text(item.plugin).rowMetadata(); Text(item.marketplace).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 5) }
        }
        .sheet(isPresented: $adding) { AddClaudePluginView(model: model) }
    }
}

private struct AddClaudePluginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var name = ""; @State private var marketplace = ""; @State private var plugin = ""; @State private var scope: ClaudePluginScope = .project
    var body: some View { VStack(alignment: .leading, spacing: 14) {
        Text("Dodaj plugin Claude").font(.title2.bold())
        Text("Definicja trafia do wspólnej biblioteki. Wybierzesz ją potem dla projektu.").font(.caption).foregroundStyle(.secondary)
        TextField("Nazwa", text: $name); TextField("Marketplace", text: $marketplace); TextField("Plugin", text: $plugin)
        Picker("Domyślny zakres", selection: $scope) { ForEach(ClaudePluginScope.allCases) { Text($0.displayName).tag($0) } }
        HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj") { Task { await model.addLibraryClaudePlugin(ClaudePluginDefinition(name: name, marketplace: marketplace, plugin: plugin, scope: scope)); dismiss() } }.buttonStyle(.borderedProminent).disabled(name.isEmpty || marketplace.isEmpty || plugin.isEmpty) }
    }.padding(24).sheetFrame(width: 560, height: 350) }
}
