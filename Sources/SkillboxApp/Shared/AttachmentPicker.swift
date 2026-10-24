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
    /// The rarely touched options start folded; the label still says what they are set to.
    @State private var showsMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Narzędzia") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) { ForEach(enabledTools, id: \.self) { tool in Toggle(tool.rawValue.capitalized, isOn: setBinding(tool, in: toolsBinding)).toggleStyle(.checkbox).fixedSize() } }.padding(6) }
            // Tags first: they decide which skills below arrive on their own.
            TagCheckGrid(title: "Tagi skilli", tags: availableTags, selection: skillTagsBinding)
            ScrollView { SkillCheckGrid(title: "Skille", skills: skills, selection: $selection) }.frame(height: 150)
            if includesServersAndDocs {
                TagCheckGrid(title: "Tagi MCP", tags: mcpTags, selection: serverTagsBinding)
                GroupBox("Serwery MCP") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { server in serverToggle(server) } }.padding(6) }
            }
            if !claudePlugins.isEmpty { pluginSection }
            if includesServersAndDocs || manageGitignore != nil {
                if matchedDocs.count > 1 { docConflict }
                DisclosureGroup(isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 14) {
                        if includesServersAndDocs { docSection }
                        if let manageGitignore {
                            GroupBox("Git") { Toggle("Dopisuj wygenerowane pliki MCP do .gitignore projektu", isOn: manageGitignore).toggleStyle(.checkbox).help("Agentbox dopisuje tylko własny blok i nigdy nie usuwa istniejących wpisów.").padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }.padding(.top, 6)
                } label: {
                    HStack { Text("Więcej opcji").sectionLabel(); Text(moreSummary).rowMetadata().lineLimit(1) }
                }
            }
        }
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
        GroupBox("Pluginy Claude") {
            VStack(alignment: .leading, spacing: 6) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) { ForEach(claudePlugins) { item in Toggle(item.name, isOn: setBinding(item.id, in: pluginIDsBinding)).toggleStyle(.checkbox).help(item.plugin) } }
            }.padding(6)
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
                TagCheckGrid(title: "Tagi dokumentów", tags: docTags, selection: docTagsBinding)
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
