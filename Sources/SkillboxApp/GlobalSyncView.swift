import SwiftUI
import AppKit
import Combine
import SkillboxCore

struct GlobalSyncView: View {
    @ObservedObject var model: AppModel
    @State private var tools = Set<Tool>()
    @State private var skillIDs = Set<String>()
    @State private var tags = Set<String>()
    @State private var previews: [SkillSyncPreview] = []
    @State private var error = ""
    @State private var loaded = false
    private var availableTags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    private var selection: GlobalSkillSelection { GlobalSkillSelection(tools: Array(tools), skillIDs: Array(skillIDs), tags: Array(tags)) }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("Skille globalne", systemImage: "person.crop.circle").font(.largeTitle.bold())
            Text("Te skille trafiają do katalogu użytkownika i są widoczne we wszystkich sesjach wybranego klienta, niezależnie od projektu.").foregroundStyle(.secondary)
            GroupBox("Narzędzia") { VStack(alignment: .leading, spacing: 6) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Toggle(isOn: setBinding(tool, in: $tools)) {
                        HStack { Text(tool.rawValue.capitalized); Text(tool.globalSkillsURL().path).font(.caption).foregroundStyle(.secondary) }
                    }.toggleStyle(.checkbox)
                }
            }.padding(6) }
            SkillCheckGrid(title: "Pojedyncze skille", skills: model.skills, selection: $skillIDs)
            TagCheckGrid(title: "Tagi dynamiczne", tags: availableTags, selection: $tags)
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
            if !previews.isEmpty {
                GroupBox("Podgląd") { VStack(alignment: .leading, spacing: 10) { ForEach(previews, id: \.tool) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.target).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                    }
                } }.padding(6) }
            }
        }.padding(28) }
        .safeAreaInset(edge: .top, spacing: 0) {
            ActionBar {
                Button { Task { await model.saveGlobalSelection(selection); if await model.syncGlobal() { await refresh() } } } label: { Label("Synchronizuj globalnie", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent).disabled(tools.isEmpty || model.isWorking)
                Button { Task { await model.saveGlobalSelection(selection); await refresh() } } label: { Label("Zapisz wybór", systemImage: "tray.and.arrow.down") }.buttonStyle(.bordered)
                Button { Task { await refresh() } } label: { Label("Odśwież podgląd", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                Spacer()
            }.background(.bar)
        }
        .navigationTitle("Globalne")
        .task { guard !loaded else { return }; loaded = true; let saved = await model.globalSelection(); tools = Set(saved.tools); skillIDs = Set(saved.skillIDs); tags = Set(saved.tags); await refresh() }
    }

    private func refresh() async {
        do { previews = try await model.previewGlobalSync(); error = "" }
        catch { previews = []; self.error = error.localizedDescription }
    }
}
