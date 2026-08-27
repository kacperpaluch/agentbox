import SwiftUI
import AppKit
import Combine
import Sparkle
import SkillboxCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Label("Ustawienia", systemImage: "gearshape").font(.largeTitle.bold())
            UpdateSettingsCard(updater: updater)
            CLISettingsCard()
            GroupBox("Folder biblioteki") { VStack(alignment: .leading, spacing: 12) { Text(model.rootPath).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Text("Tutaj Agentbox przechowuje skille, katalog, konfigurację projektów i repozytorium backupu Git.").font(.caption).foregroundStyle(.secondary); Button("Wybierz nowy folder…") { chooseFolder() } }.padding(8) }
            Text("Istniejąca biblioteka Agentbox/Skillbox zostanie podłączona bez kopiowania. Jeśli wskażesz pusty folder, obecna biblioteka zostanie do niego skopiowana.").foregroundStyle(.secondary)
            Spacer()
        }.padding(28) }.navigationTitle("Ustawienia")
    }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Wybierz"; if panel.runModal() == .OK, let url = panel.url { Task { await model.moveLibrary(to: url) } } }
}
/// The settings a project and a parent folder share. Both edit them through this one view, so a
/// folder can never offer less than a project — including the rule that a tag owns everything it
/// pulls in.
struct SharedSettingsForm: View {
    let skills: [Skill]
    let servers: [MCPServer]
    let docs: [AgentDoc]
    @Binding var tools: Set<Tool>
    @Binding var selectedSkills: Set<String>
    @Binding var selectedTags: Set<String>
    @Binding var selectedServers: Set<UUID>
    @Binding var selectedMCPtags: Set<String>
    @Binding var selectedDoc: String?
    @Binding var selectedDocTags: Set<String>
    @Binding var excluded: Set<String>
    @Binding var manageGitignore: Bool

    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }
    private var docTags: [String] { Array(Set(docs.flatMap(\.tags))).sorted() }
    private var matchedDocs: [AgentDoc] { docs.filter { covered($0.tags, by: selectedDocTags) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: $tools)).toggleStyle(.checkbox) } }.padding(6) }
            ScrollView { SkillCheckGrid(title: "Pojedyncze skille", skills: skills, selection: $selectedSkills, locked: Set(tagMatched.map(\.id)), lockedHelp: "Wybrany przez tag — odznacz go w sekcji Wykluczenia, by pominąć") }.frame(height: 150)
            TagCheckGrid(title: "Tagi skilli", tags: availableTags, selection: $selectedTags)
            GroupBox("Pojedyncze serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { server in serverToggle(server) } }.padding(6) }
            TagCheckGrid(title: "Tagi MCP", tags: mcpTags, selection: $selectedMCPtags)
            exclusionsBox
            docSection
            GroupBox("Git") { VStack(alignment: .leading, spacing: 6) { Toggle("Dopisuj wygenerowane pliki MCP do .gitignore projektu", isOn: $manageGitignore).toggleStyle(.checkbox); Text(".gitignore jedzie z repozytorium, więc chroni też zespół. Agentbox dopisuje tylko własny blok i nigdy nie usuwa istniejących wpisów.").font(.caption).foregroundStyle(.secondary) }.padding(6) }
        }
    }

    /// A project can only ever have one `AGENTS.md`, so this is a single pick — not a checkbox grid
    /// like skills and MCP servers. Tags can still match more than one document; that is a conflict
    /// synchronization reports, so it is flagged here before it gets that far.
    @ViewBuilder private var docSection: some View {
        GroupBox("Dokument (AGENTS.md / CLAUDE.md)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ten sam tekst trafia jako AGENTS.md; CLAUDE.md jest generowany osobno jako import @AGENTS.md. Oba pliki zawsze idą razem.").font(.caption).foregroundStyle(.secondary)
                Picker("Dokument", selection: $selectedDoc) {
                    Text("Brak").tag(String?.none)
                    ForEach(docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { doc in Text(doc.name).tag(Optional(doc.id)) }
                }
                TagCheckGrid(title: "Tagi dokumentów", tags: docTags, selection: $selectedDocTags)
                if matchedDocs.count > 1 {
                    Label("Kilka dokumentów pasuje przez tagi naraz — synchronizacja zgłosi konflikt. Zostaw jeden pasujący tag albo wybierz dokument wprost.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(6)
        }
    }

    /// Every skill a tag pulls in can be excluded here, including one that was also ticked
    /// individually — the tag locks its checkbox, so this box is the only way to drop it.
    private var tagMatched: [Skill] { skills.filter { covered($0.tags, by: selectedTags) }.sorted { $0.name < $1.name } }
    /// Tags are compared case-insensitively, the same way the sync resolves them.
    private func covered(_ tags: [String], by selection: Set<String>) -> Bool {
        let wanted = Set(selection.map { $0.lowercased() })
        return !wanted.isDisjoint(with: tags.map { $0.lowercased() })
    }
    @ViewBuilder private var exclusionsBox: some View {
        GroupBox("Wykluczenia") {
            VStack(alignment: .leading, spacing: 6) {
                if tagMatched.isEmpty { Text("Wybierz tagi skilli, aby móc wykluczyć pojedyncze pozycje.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text("Te skille wchodzą przez tagi. Zaznaczone zostaną pominięte.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                        ForEach(tagMatched) { skill in
                            Toggle(skill.name, isOn: Binding(get: { excluded.contains(skill.id) }, set: { if $0 { excluded.insert(skill.id); selectedSkills.remove(skill.id) } else { excluded.remove(skill.id) } })).toggleStyle(.checkbox)
                        }
                    }
                }
            }.padding(6)
        }
    }
    // A selected tag pulls the server in on its own; showing it checked-but-locked here makes that
    // visible right on the list. Skills get the same treatment via `SkillCheckGrid`'s `locked` set —
    // servers have no exclusions box, so there is nowhere else a tag-covered one could be dropped.
    private func serverToggle(_ server: MCPServer) -> some View {
        let tagCovered = covered(server.tags ?? [], by: selectedMCPtags)
        return Toggle(server.name, isOn: tagCovered ? .constant(true) : setBinding(server.id, in: $selectedServers)).toggleStyle(.checkbox)
            .disabled(tagCovered).help(tagCovered ? "Wybrany przez tag MCP" : "")
    }
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
