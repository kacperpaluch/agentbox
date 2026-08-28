import SwiftUI
import SkillboxCore

/// The three things Agentbox can attach to a place. They were three sidebar sections doing the same
/// four operations — list, search, tag, delete — which made the sidebar look like it held three
/// unrelated features instead of one library with three kinds of entry in it.
enum LibraryKind: String, CaseIterable, Identifiable {
    case skills = "Skille", mcp = "MCP", docs = "Dokumenty"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .skills: "square.grid.2x2"
        case .mcp: "network"
        case .docs: "doc.text"
        }
    }
}

/// One library, three kinds of entry.
///
/// The search field and the tag filter live here rather than in each pane, so switching kinds keeps
/// the question you were asking ("everything tagged `web`") instead of resetting it — and MCP servers
/// and documents gain the search and tag filtering that only skills used to have.
///
/// The detail side stays per-kind on purpose: a `SKILL.md` preview, an MCP server form and a document
/// editor are genuinely different things, and merging them would cost clarity to save nothing.
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var showGit: Bool
    @State private var kind: LibraryKind = .skills
    @State private var search = ""
    @State private var selectedTag = ""

    /// Every tag in use by the kind on screen. Kept per-kind: offering an MCP tag while browsing
    /// documents would only ever filter the list down to nothing.
    private var tags: [String] {
        switch kind {
        case .skills: Array(Set(model.skills.flatMap(\.tags))).sorted()
        case .mcp: Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted()
        case .docs: Array(Set(model.docs.docs.flatMap(\.tags))).sorted()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            kindPicker
            Divider()
            switch kind {
            case .skills: SkillsPane(model: model, showGit: $showGit, search: search, selectedTag: selectedTag)
            case .mcp: MCPPane(model: model, search: search, selectedTag: selectedTag)
            case .docs: DocsPane(model: model, search: search, selectedTag: selectedTag)
            }
        }
        .navigationTitle("Biblioteka")
        .searchable(text: $search, prompt: searchPrompt)
        .onChange(of: kind) { selectedTag = "" }
    }

    private var searchPrompt: String {
        switch kind {
        case .skills: "Nazwa lub tag skilla"
        case .mcp: "Nazwa lub tag serwera"
        case .docs: "Nazwa lub tag dokumentu"
        }
    }

    private var kindPicker: some View {
        HStack(spacing: Space.row) {
            Picker("", selection: $kind) {
                ForEach(LibraryKind.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)

            if !tags.isEmpty {
                Picker("Tag", selection: $selectedTag) {
                    Text("Wszystkie tagi").tag("")
                    ForEach(tags, id: \.self) { Text("#\($0)").tag($0) }
                }
                .frame(maxWidth: 210)
            }
            Spacer()
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.row)
    }
}

/// Shared by all three panes: does this entry match what the user typed and the tag they picked?
func libraryMatches(name: String, id: String, tags: [String], search: String, selectedTag: String) -> Bool {
    let tagOK = selectedTag.isEmpty || tags.contains { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }
    guard tagOK else { return false }
    guard !search.isEmpty else { return true }
    return name.localizedCaseInsensitiveContains(search)
        || id.localizedCaseInsensitiveContains(search)
        || tags.contains { $0.localizedCaseInsensitiveContains(search) }
}
