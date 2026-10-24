import SwiftUI
import Sparkle
import SkillboxCore

struct SettingsView: View {
    let model: AppModel
    let updater: SPUUpdater
    @State private var section: SettingsSection = .general
    @State private var editingDefaults = false

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "Ogólne"
        case recovery = "Backup i odzyskiwanie"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sekcja ustawień", selection: $section) {
                ForEach(SettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .padding(Space.page)
            Divider()

            switch section {
            case .general: generalSettings
            case .recovery: BackupView(model: model, embedded: true)
            }
        }
        .navigationTitle("Ustawienia")
        .sheet(isPresented: $editingDefaults) { ProjectDefaultsEditor(model: model) }
    }

    /// The template a new project starts from. It sat above the project table as a permanent strip,
    /// next to folder inheritance that works the opposite way; here it is one setting among others.
    private var defaultsSummary: String {
        let defaults = model.projectDefaults
        let tools = defaults.tools.filter(model.enabledTools.contains)
        let clients = tools.isEmpty ? "bez klientów" : tools.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let skills = defaults.skillIDs.count + defaults.skillTags.count
        let servers = defaults.serverIDs.count + defaults.serverTags.count
        let docs = defaults.docIDs.count + defaults.docTags.count
        return "\(clients) · \(skills) skilli · \(servers) MCP · \(docs) dokumentów"
    }

    private var generalSettings: some View {
        // The title above and the section picker already say where this is; a third heading only pushed
        // the settings down. A fixed reading width keeps descriptions from running 200 characters wide.
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            UpdateSettingsCard(updater: updater)
            CLISettingsCard()
            GroupBox("Używane narzędzia") { VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) { ForEach(Tool.allCases, id: \.self) { tool in
                    let isOn = model.enabledTools.contains(tool)
                    Toggle(tool.rawValue.capitalized, isOn: Binding(get: { isOn }, set: { on in
                        Task { await model.setEnabledTools(on ? model.enabledTools + [tool] : model.enabledTools.filter { $0 != tool }) }
                    }))
                    .toggleStyle(.checkbox)
                    // At least one client has to stay on, or no synchronization would do anything.
                    .disabled(model.isWorking || (isOn && model.enabledTools.count == 1))
                } }
                Text("Synchronizacja pomija wyłączone narzędzia i nie rusza ich plików.").font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Domyślne dla nowych projektów") { HStack(alignment: .firstTextBaseline, spacing: Space.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(defaultsSummary)
                    Text("Kopiowane do formularza nowego projektu; nie zmienia istniejących.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edytuj…") { editingDefaults = true }
            }.padding(8) }
            GroupBox("Folder biblioteki") { VStack(alignment: .leading, spacing: 12) {
                Text(model.rootPath).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: Space.section) {
                    Button("Wybierz nowy folder…") { chooseFolder() }
                        .help("Istniejąca biblioteka zostanie podłączona bez kopiowania; do pustego folderu obecna zostanie skopiowana.")
                    Text("Skille, konfiguracja projektów i lokalne kopie zapasowe.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8) }
            Spacer()
        }.frame(maxWidth: 760, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Wybierz"; if panel.runModal() == .OK, let url = panel.url { Task { await model.moveLibrary(to: url) } } }
}
