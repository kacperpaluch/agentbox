import SwiftUI
import SkillboxCore

/// The one place in the app where you say what lands somewhere: which clients, which skills, which
/// MCP servers, which document.
///
/// Every editor uses it — a project, a parent folder, a batch add, a folder being set up from
/// existing projects, and the Mac itself. They used to pass eight separate bindings each and keep
/// eight matching `@State` properties, four times over; a project and a folder could quietly drift
/// apart because adding a field meant remembering four call sites. Now they hold one
/// `AttachmentSelection` and hand it here.
struct AttachmentPicker: View {
    let skills: [Skill]
    let servers: [MCPServer]
    let docs: [AgentDoc]
    @Binding var selection: AttachmentSelection
    /// A project property rather than an attachment, so it stays a separate binding — and the global
    /// target has no repository to write a `.gitignore` into, which is why it can be left out.
    var manageGitignore: Binding<Bool>?
    /// The Mac itself can only take skills: the files a global MCP server would live in are ones
    /// Agentbox deliberately never writes, and a global `AGENTS.md` has no defined location. Showing
    /// those pickers there would offer a choice nothing acts on.
    var includesServersAndDocs = true

    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }
    private var docTags: [String] { Array(Set(docs.flatMap(\.tags))).sorted() }
    private var matchedDocs: [AgentDoc] { docs.filter { covered($0.tags, by: Set(selection.docTags)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Narzędzia") { HStack { ForEach(Tool.allCases, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: toolsBinding)).toggleStyle(.checkbox) } }.padding(6) }
            ScrollView { SkillCheckGrid(title: "Pojedyncze skille", skills: skills, selection: skillIDsBinding, locked: Set(tagMatched.map(\.id)), lockedHelp: "Wybrany przez tag — odznacz go w sekcji Wykluczenia, by pominąć") }.frame(height: 150)
            TagCheckGrid(title: "Tagi skilli", tags: availableTags, selection: skillTagsBinding)
            if includesServersAndDocs {
                GroupBox("Pojedyncze serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { server in serverToggle(server) } }.padding(6) }
                TagCheckGrid(title: "Tagi MCP", tags: mcpTags, selection: serverTagsBinding)
            }
            exclusionsBox
            if includesServersAndDocs { docSection }
            if let manageGitignore {
                GroupBox("Git") { VStack(alignment: .leading, spacing: 6) { Toggle("Dopisuj wygenerowane pliki MCP do .gitignore projektu", isOn: manageGitignore).toggleStyle(.checkbox); Text(".gitignore jedzie z repozytorium, więc chroni też zespół. Agentbox dopisuje tylko własny blok i nigdy nie usuwa istniejących wpisów.").font(.caption).foregroundStyle(.secondary) }.padding(6) }
            }
        }
    }

    // MARK: Bindings into the selection
    //
    // The grids below speak `Set`, the stored selection speaks sorted `Array` — sorted so that
    // ticking two boxes in a different order does not produce a different `mcp.json`, which would
    // show up as noise in the Git backup diff.

    private var toolsBinding: Binding<Set<Tool>> {
        Binding(get: { Set(selection.tools) }, set: { selection.tools = $0.sorted { $0.rawValue < $1.rawValue } })
    }
    private var skillIDsBinding: Binding<Set<String>> {
        Binding(get: { Set(selection.skillIDs) }, set: { selection.skillIDs = $0.sorted() })
    }
    private var skillTagsBinding: Binding<Set<String>> {
        Binding(get: { Set(selection.skillTags) }, set: { selection.skillTags = $0.sorted() })
    }
    private var serverIDsBinding: Binding<Set<UUID>> {
        Binding(get: { Set(selection.serverIDs) }, set: { selection.serverIDs = $0.sorted { $0.uuidString < $1.uuidString } })
    }
    private var serverTagsBinding: Binding<Set<String>> {
        Binding(get: { Set(selection.serverTags) }, set: { selection.serverTags = $0.sorted() })
    }
    private var docTagsBinding: Binding<Set<String>> {
        Binding(get: { Set(selection.docTags) }, set: { selection.docTags = $0.sorted() })
    }
    /// A project can hold exactly one `AGENTS.md`, so the stored list is at most one long.
    private var docBinding: Binding<String?> {
        Binding(get: { selection.docIDs.first }, set: { selection.docIDs = $0.map { [$0] } ?? [] })
    }

    /// A project can only ever have one `AGENTS.md`, so this is a single pick — not a checkbox grid
    /// like skills and MCP servers. Tags can still match more than one document; that is a conflict
    /// synchronization reports, so it is flagged here before it gets that far.
    @ViewBuilder private var docSection: some View {
        GroupBox("Dokument (AGENTS.md / CLAUDE.md)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ten sam tekst trafia jako AGENTS.md; CLAUDE.md jest generowany osobno jako import @AGENTS.md. Oba pliki zawsze idą razem.").font(.caption).foregroundStyle(.secondary)
                Picker("Dokument", selection: docBinding) {
                    Text("Brak").tag(String?.none)
                    ForEach(docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { doc in Text(doc.name).tag(Optional(doc.id)) }
                }
                TagCheckGrid(title: "Tagi dokumentów", tags: docTags, selection: docTagsBinding)
                if matchedDocs.count > 1 {
                    Label("Kilka dokumentów pasuje przez tagi naraz — synchronizacja zgłosi konflikt. Zostaw jeden pasujący tag albo wybierz dokument wprost.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(6)
        }
    }

    /// Every skill a tag pulls in can be excluded here, including one that was also ticked
    /// individually — the tag locks its checkbox, so this box is the only way to drop it.
    private var tagMatched: [Skill] { skills.filter { covered($0.tags, by: Set(selection.skillTags)) }.sorted { $0.name < $1.name } }
    /// Tags are compared case-insensitively, the same way the sync resolves them.
    private func covered(_ tags: [String], by wanted: Set<String>) -> Bool {
        let lowered = Set(wanted.map { $0.lowercased() })
        return !lowered.isDisjoint(with: tags.map { $0.lowercased() })
    }
    @ViewBuilder private var exclusionsBox: some View {
        GroupBox("Wykluczenia") {
            VStack(alignment: .leading, spacing: 6) {
                if tagMatched.isEmpty { Text("Wybierz tagi skilli, aby móc wykluczyć pojedyncze pozycje.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text("Te skille wchodzą przez tagi. Zaznaczone zostaną pominięte.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                        ForEach(tagMatched) { skill in
                            Toggle(skill.name, isOn: Binding(
                                get: { selection.excludedSkillIDs.contains(skill.id) },
                                set: { excluded in
                                    var ids = Set(selection.excludedSkillIDs)
                                    if excluded {
                                        ids.insert(skill.id)
                                        selection.skillIDs.removeAll { $0 == skill.id }
                                    } else {
                                        ids.remove(skill.id)
                                    }
                                    selection.excludedSkillIDs = ids.sorted()
                                }
                            )).toggleStyle(.checkbox)
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
        let tagCovered = covered(server.tags ?? [], by: Set(selection.serverTags))
        return Toggle(server.name, isOn: tagCovered ? .constant(true) : setBinding(server.id, in: serverIDsBinding)).toggleStyle(.checkbox)
            .disabled(tagCovered).help(tagCovered ? "Wybrany przez tag MCP" : "")
    }
}
