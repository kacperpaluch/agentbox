import SwiftUI
import AppKit
import Combine
import Sparkle
import SkillboxCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @State private var section: SettingsSection = .general

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
    }

    private var generalSettings: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Label("Ustawienia aplikacji", systemImage: "gearshape").font(.largeTitle.bold())
            UpdateSettingsCard(updater: updater)
            CLISettingsCard()
            GroupBox("Folder biblioteki") { VStack(alignment: .leading, spacing: 12) { Text(model.rootPath).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Text("Tutaj Agentbox przechowuje skille, katalog, konfigurację projektów i repozytorium backupu Git.").font(.caption).foregroundStyle(.secondary); Button("Wybierz nowy folder…") { chooseFolder() } }.padding(8) }
            Text("Istniejąca biblioteka Agentbox/Skillbox zostanie podłączona bez kopiowania. Jeśli wskażesz pusty folder, obecna biblioteka zostanie do niego skopiowana.").foregroundStyle(.secondary)
            Spacer()
        }.padding(28) }
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Wybierz"; if panel.runModal() == .OK, let url = panel.url { Task { await model.moveLibrary(to: url) } } }
}
func setBinding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
    Binding(get: { set.wrappedValue.contains(value) }, set: { enabled in if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
}
/// Titled grid of "pick a skill" checkboxes — the same visual language everywhere skills are
/// selected: Projects, folders, batch add, and Global. A skill whose id is in `locked` shows fixed
/// as checked, because something else (a tag) already pulls it in, with `lockedHelp` as its tooltip.
struct SkillCheckGrid: View {
    let title: String
    let skills: [Skill]
    @Binding var selection: Set<String>
    var locked: Set<String> = []
    var lockedHelp: String = ""
    var body: some View {
        GroupBox(title) {
            if skills.isEmpty { Text("Biblioteka jest pusta.").foregroundStyle(.secondary).padding(6) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                    ForEach(skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { skill in
                        let isLocked = locked.contains(skill.id)
                        Toggle(skill.name, isOn: isLocked ? .constant(true) : setBinding(skill.id, in: $selection))
                            .toggleStyle(.checkbox).disabled(isLocked).help(isLocked ? lockedHelp : "")
                    }
                }.padding(6)
            }
        }
    }
}
/// Titled grid of `#tag` checkboxes — shared by every "select by tag" section in the app.
struct TagCheckGrid: View {
    let title: String
    let tags: [String]
    @Binding var selection: Set<String>
    var body: some View {
        GroupBox(title) {
            if tags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                    ForEach(tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { tag in Toggle("#\(tag)", isOn: setBinding(tag, in: $selection)).toggleStyle(.checkbox) }
                }.padding(6)
            }
        }
    }
}
