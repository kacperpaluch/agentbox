import SwiftUI
import SkillboxCore

/// Subfolders that showed up in a watched parent folder. Each one is a yes/no question, and both
/// answers are remembered: adding makes it a project, skipping stops it from being offered again.
struct DetectedFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var selected = Set<String>()

    private var groups: [(name: String, folders: [DetectedProjectFolder])] {
        Dictionary(grouping: model.detectedFolders, by: \.rootName)
            .map { (name: $0.key, folders: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var chosen: [DetectedProjectFolder] { model.detectedFolders.filter { selected.contains($0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nowe podfoldery").font(.title2.bold())
            Text("Te foldery pojawiły się w folderach nadrzędnych i nie są jeszcze projektami. Dodane projekty korzystają z ustawień swojego folderu.").foregroundStyle(.secondary)
            HStack { Button("Zaznacz wszystkie") { selected = Set(model.detectedFolders.map(\.path)) }; Button("Wyczyść") { selected.removeAll() }; Spacer(); Text("Wybrano \(selected.count)").foregroundStyle(.secondary) }
            List {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.folders) { folder in
                            Toggle(isOn: setBinding(folder.path, in: $selected)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.name)
                                    Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(folder.path)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                // The sheet closes only once the action reported success; a failure stays visible here.
                Button("Pomijaj zaznaczone") { let folders = chosen; Task { if await model.ignoreDetected(folders) { dismiss() } } }.disabled(selected.isEmpty || model.isWorking)
                Spacer()
                Button("Później") { dismiss() }
                Button("Dodaj bez synchronizacji") { let folders = chosen; Task { if await model.addDetected(folders, synchronizing: false) { dismiss() } } }.disabled(selected.isEmpty || model.isWorking)
                Button("Dodaj i synchronizuj") { let folders = chosen; Task { if await model.addDetected(folders, synchronizing: true) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || model.isWorking)
            }
        }
        .padding(24)
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .sheetFrame(width: 680, height: 520)
        .onAppear { selected = Set(model.detectedFolders.map(\.path)) }
    }
}
