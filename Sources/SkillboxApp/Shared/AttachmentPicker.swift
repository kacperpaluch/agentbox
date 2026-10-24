import SwiftUI
import SkillboxCore

struct AttachmentPicker: View {
    @Environment(\.enabledTools) private var enabledTools
    let skills: [Skill]
    let servers: [MCPServer]
    let docs: [AgentDoc]
    let claudePlugins: [ClaudePluginDefinition]
    @Binding var selection: AttachmentSelection
    /// A project property rather than an attachment, so it stays a separate binding — and the global
    /// target has no repository to write a `.gitignore` into, which is why it can be left out.
    var manageGitignore: Binding<Bool>?
    /// The Mac itself can only take skills: the files a global MCP server would live in are ones
    /// Agentbox deliberately never writes, and a global `AGENTS.md` has no defined location. Showing
    /// those pickers there would offer a choice nothing acts on.
    var includesServersAndDocs = true
    init(skills: [Skill], servers: [MCPServer], docs: [AgentDoc], claudePlugins: [ClaudePluginDefinition] = [], selection: Binding<AttachmentSelection>, manageGitignore: Binding<Bool>? = nil, includesServersAndDocs: Bool = true) {
        self.skills = skills; self.servers = servers; self.docs = docs; self.claudePlugins = claudePlugins
        self._selection = selection; self.manageGitignore = manageGitignore; self.includesServersAndDocs = includesServersAndDocs
    }

    private var availableTags: [String] { Array(Set(skills.flatMap(\.tags))).sorted() }
    private var mcpTags: [String] { Array(Set(servers.flatMap { $0.tags ?? [] })).sorted() }
    private var docTags: [String] { Array(Set(docs.flatMap(\.tags))).sorted() }
    private var matchedDocs: [AgentDoc] { docs.filter { covered($0.tags, by: Set(selection.docTags)) } }
    /// Folded sections, shared by every form that uses the picker and kept between launches. A long
    /// skill list folds away in one click and the servers below it come into view — the focus a tab
    /// per kind would give, without a second tab holding unsaved changes out of sight.
    /// `more` starts folded: the document and `.gitignore` are rarely touched, and its label says
    /// what they are set to.
    @AppStorage("AgentboxFoldedPickerSections") private var foldedStorage = "more"
    /// Narrows the skill and server lists, which run to dozens of entries. It only hides rows:
    /// a ticked skill that does not match stays ticked, and the counts in the headers still say so.
    @State private var query = ""
    private var shownSkills: [Skill] { skills.filter { libraryMatches(name: $0.name, id: $0.id, tags: $0.tags, search: query, selectedTag: "") } }
    private var shownServers: [MCPServer] { servers.filter { libraryMatches(name: $0.name, id: $0.name, tags: $0.tags ?? [], search: query, selectedTag: "") } }
    private var chosenSkills: Int { skills.count { SkillPick.isIncluded($0, in: selection) } }
    private var chosenServers: Int { servers.count { selection.serverIDs.contains($0.id) || covered($0.tags ?? [], by: Set(selection.serverTags)) } }
    private var chosenPlugins: Int { claudePlugins.count { selection.claudePluginIDs?.contains($0.id) == true } }
    private var noMatch: String { "Nic nie pasuje do „\(query)”." }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Narzędzia") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) { ForEach(enabledTools, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: toolsBinding)).toggleStyle(.checkbox).fixedSize() } }.padding(6) }
            TextField(includesServersAndDocs ? "Szukaj skilli i serwerów MCP" : "Szukaj skilli", text: $query)
                .textFieldStyle(.roundedBorder)
            section("skills", title: "Skille", summary: summary(chosenSkills, of: skills.count, tags: selection.skillTags)) {
                // Tags first: they decide which skills below arrive on their own.
                if !availableTags.isEmpty { TagCheckGrid(title: "Tagi", tags: availableTags, selection: skillTagsBinding) }
                SkillCheckGrid(title: "Lista", skills: shownSkills, selection: $selection, emptyText: query.isEmpty ? "Biblioteka jest pusta." : noMatch)
            }
            if includesServersAndDocs {
                section("mcp", title: "Serwery MCP", summary: summary(chosenServers, of: servers.count, tags: selection.serverTags)) {
                    if !mcpTags.isEmpty { TagCheckGrid(title: "Tagi", tags: mcpTags, selection: serverTagsBinding) }
                    GroupBox("Lista") {
                        if shownServers.isEmpty { Text(query.isEmpty ? "Brak serwerów w bibliotece." : noMatch).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                        else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(shownServers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { server in serverToggle(server) } }.padding(6) }
                    }
                }
            }
            if !claudePlugins.isEmpty {
                section("plugins", title: "Pluginy Claude", summary: summary(chosenPlugins, of: claudePlugins.count, tags: [])) { pluginSection }
            }
            if includesServersAndDocs || manageGitignore != nil {
                if matchedDocs.count > 1 { docConflict }
                section("more", title: "Więcej opcji", summary: moreSummary) {
                    if includesServersAndDocs { docSection }
                    if let manageGitignore {
                        GroupBox("Git") { Toggle("Dopisuj wygenerowane pliki MCP do .gitignore projektu", isOn: manageGitignore).toggleStyle(.checkbox).help("Agentbox dopisuje tylko własny blok i nigdy nie usuwa istniejących wpisów.").padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            }
        }
    }

    /// A foldable part of the form whose header still answers "how much is chosen here".
    private func section(_ key: String, title: String, summary: String, @ViewBuilder content: () -> some View) -> some View {
        let body = VStack(alignment: .leading, spacing: 14) { content() }.padding(.top, 6)
        return DisclosureGroup(isExpanded: expansion(key)) { body } label: {
            HStack(spacing: Space.row) { Text(title).sectionLabel(); Text(summary).rowMetadata().lineLimit(1) }
        }
    }
    private func expansion(_ key: String) -> Binding<Bool> {
        // A search opens the lists it filters: a match inside a folded section would look like no match.
        Binding(get: { (!query.isEmpty && key != "more") || !folded.contains(key) }, set: { open in
            var keys = folded
            if open { keys.remove(key) } else { keys.insert(key) }
            foldedStorage = keys.sorted().joined(separator: ",")
        })
    }
    private var folded: Set<String> { Set(foldedStorage.split(separator: ",").map(String.init)) }
    private func summary(_ chosen: Int, of total: Int, tags: [String]) -> String {
        "wybrane \(chosen) z \(total)" + (tags.isEmpty ? "" : " · " + tags.map { "#\($0)" }.joined(separator: " "))
    }

    private var moreSummary: String {
        var parts: [String] = []
        if includesServersAndDocs {
            let named = selection.docIDs.first.flatMap { id in docs.first { $0.id == id }?.name }
            parts.append("dokument: " + (named ?? (selection.docTags.isEmpty ? "brak" : selection.docTags.map { "#\($0)" }.joined(separator: " "))))
        }
        if let manageGitignore { parts.append(".gitignore: " + (manageGitignore.wrappedValue ? "tak" : "nie")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Bindings into the selection
    //
    // The grids below speak `Set`, the stored selection speaks sorted `Array` — sorted so that
    // ticking two boxes in a different order does not produce a different `mcp.json`, which would
    // show up as noise in the Git backup diff.

    private var toolsBinding: Binding<Set<Tool>> {
        Binding(get: { Set(selection.tools) }, set: { selection.tools = $0.sorted { $0.rawValue < $1.rawValue } })
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
    private var pluginIDsBinding: Binding<Set<UUID>> { Binding(get: { Set(selection.claudePluginIDs ?? []) }, set: { selection.claudePluginIDs = $0.sorted { $0.uuidString < $1.uuidString } }) }
    private var pluginSection: some View {
        GroupBox("Lista") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(claudePlugins) { item in Toggle(item.name, isOn: setBinding(item.id, in: pluginIDsBinding)).toggleStyle(.checkbox).help(item.plugin) } }.padding(6)
        }
    }
    /// A project can hold exactly one `AGENTS.md`, so the stored list is at most one long.
    private var docBinding: Binding<String?> {
        Binding(get: { selection.docIDs.first }, set: { selection.docIDs = $0.map { [$0] } ?? [] })
    }

    /// A project can only ever have one `AGENTS.md`, so this is a single pick — not a checkbox grid
    /// like skills and MCP servers. Tags can still match more than one document; that is a conflict
    /// synchronization reports, so it is flagged before it gets that far.
    @ViewBuilder private var docSection: some View {
        GroupBox("Dokument (AGENTS.md / CLAUDE.md)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Dokument", selection: docBinding) {
                    Text("Brak").tag(String?.none)
                    ForEach(docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { doc in Text(doc.name).tag(Optional(doc.id)) }
                }
                .help("Tekst trafia jako AGENTS.md; CLAUDE.md dostaje import @AGENTS.md.")
                if !docTags.isEmpty { TagCheckGrid(title: "Tagi dokumentów", tags: docTags, selection: docTagsBinding) }
            }.padding(6)
        }
    }
    private var docConflict: some View {
        Label("Kilka dokumentów pasuje przez tagi naraz. Zostaw jeden tag albo wybierz dokument wprost.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
    }

    /// Tags are compared case-insensitively, the same way the sync resolves them.
    private func covered(_ tags: [String], by wanted: Set<String>) -> Bool {
        let lowered = Set(wanted.map { $0.lowercased() })
        return !lowered.isDisjoint(with: tags.map { $0.lowercased() })
    }
    // A selected tag pulls the server in on its own; showing it checked-but-locked makes that visible.
    // Servers have no exclusions in the model, so unlike a skill a tag-covered one cannot be dropped.
    private func serverToggle(_ server: MCPServer) -> some View {
        let tagCovered = covered(server.tags ?? [], by: Set(selection.serverTags))
        return Toggle(server.name, isOn: tagCovered ? .constant(true) : setBinding(server.id, in: serverIDsBinding)).toggleStyle(.checkbox)
            .disabled(tagCovered).help(tagCovered ? "Wybrany przez tag MCP — odznacz tag, by go pominąć" : "")
    }
}
