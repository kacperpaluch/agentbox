import SwiftUI
import SkillboxCore

/// Codex CLI, the Codex IDE extension and the ChatGPT desktop app share one file
/// (`~/.codex/config.toml`); Claude Code has an equivalent "user" scope in `~/.claude.json`. A
/// server declared there loads in every project automatically — Agentbox only reads those files and
/// lets each folder or standalone project opt one server out, without ever touching the global file
/// itself.
///
/// This tab lists it from the server's side, one row per (tool, server name) with a toggle per
/// place that can see it — the natural way to answer "where is this server active", instead of
/// hunting through Projekty one folder at a time for the same information.
struct GlobalMCPView: View {
    @ObservedObject var model: AppModel
    @State private var showAllSync = false

    var body: some View {
        VStack(spacing: 0) {
            ActionBar {
                Button { showAllSync = true } label: { Label("Synchronizuj wszystkie projekty", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.projects.isEmpty || model.isWorking)
                    .help("Zapisuje na dysku każdą zmianę zrobioną na tej liście — nie tylko globalne serwery")
                Spacer()
            }
            List {
                explanation
                toolSection(.codex, title: "Codex", source: "~/.codex/config.toml — dzielony z aplikacją ChatGPT Desktop i wtyczką IDE")
                toolSection(.claude, title: "Claude Code", source: "zasięg „user” w ~/.claude.json")
            }
        }
        .navigationTitle("MCP globalne")
        .sheet(isPresented: $showAllSync) { AllProjectsSyncPreviewView(model: model) }
    }

    private var explanation: some View {
        Text("Serwery poniżej nie są zarządzane przez Agentbox — Codex albo Claude Code same je ładują w każdym projekcie. Odznaczenie folderu albo projektu przy serwerze dopisuje dla niego lokalny override (bez zmiany globalnego pliku); przełącznik zapisuje tylko wybór — kliknij „Synchronizuj”, żeby zmiana trafiła na dysk.")
            .font(.caption).foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func toolSection(_ tool: Tool, title: String, source: String) -> some View {
        let names = model.globalMCPServerNames(tool: tool)
        let selections = model.mcpSelections.filter { $0.tools.contains(tool) }
        Section {
            if names.isEmpty {
                Text("Nie znaleziono żadnych globalnych serwerów.").font(.caption).foregroundStyle(.secondary)
            } else if selections.isEmpty {
                Text("Znaleziono \(names.count), ale żaden projekt ani folder nie ma zaznaczonego \(title) — nie ma tu więc czego wyłączać.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in GlobalServerRow(model: model, tool: tool, name: name, selections: selections) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(source).font(.caption2).foregroundStyle(.tertiary).textCase(nil)
            }
        }
    }
}

/// One global server, expandable into the folders/projects it reaches — each with its own opt-out
/// toggle. Collapsed by default so a long project list does not turn this into a wall of checkboxes.
private struct GlobalServerRow: View {
    @ObservedObject var model: AppModel
    let tool: Tool
    let name: String
    let selections: [AppModel.MCPSelection]
    @State private var expanded = false

    /// Same grouping Projekty shows: a folder with shared settings collapses to its one selection,
    /// projects sharing a parent path (no formal shared folder) cluster under it for scanning.
    private var groups: [(key: String, name: String, isRoot: Bool, items: [AppModel.MCPSelection])] {
        var order: [String] = []
        var buckets: [String: [AppModel.MCPSelection]] = [:]
        for selection in selections {
            if buckets[selection.groupKey] == nil { order.append(selection.groupKey) }
            buckets[selection.groupKey, default: []].append(selection)
        }
        return order.map { key in
            let items = buckets[key] ?? []
            return (key, items.first?.groupName ?? key, items.first?.isRoot ?? false, items)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var disabledCount: Int { selections.filter { model.isGlobalServerDisabled(selectionID: $0.id, tool: tool, name: name) }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(groups, id: \.key) { group in
                if group.isRoot, let only = group.items.first, group.items.count == 1 {
                    // A shared folder is itself a single selection — no sub-list needed, just name it
                    // like Projekty does for the same folder.
                    row(for: only, label: Label(group.name, systemImage: "folder.badge.gearshape"))
                        .padding(.leading, Space.row)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(group.name, systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(group.items) { selection in
                            row(for: selection, label: Text(selection.name))
                                .padding(.leading, Space.row + 12)
                        }
                    }.padding(.leading, Space.row).padding(.top, 2)
                }
            }
        } label: {
            HStack(spacing: Space.tight + 2) {
                Text(name).fontWeight(.medium)
                if disabledCount > 0 { MetaBadge(text: "wyłączony w \(disabledCount)/\(selections.count)", tint: .orange) }
            }
        }
    }

    /// `true` means inherited (the default — Codex/Claude keep using their global definition);
    /// `false` records this selection's opt-out. Same "dziedziczony"/"wyłączony" wording as the CLI.
    private func binding(for selection: AppModel.MCPSelection) -> Binding<Bool> {
        Binding(
            get: { !model.isGlobalServerDisabled(selectionID: selection.id, tool: tool, name: name) },
            set: { inherited in Task { await model.setGlobalServerDisabled(selectionID: selection.id, tool: tool, name: name, disabled: !inherited) } }
        )
    }

    /// One toggle plus an inline "Synchronizuj" so a single opt-out can be pushed to
    /// `.codex/config.toml` / `.claude/settings.local.json` right here, without a trip to Projekty.
    @ViewBuilder
    private func row(for selection: AppModel.MCPSelection, label: some View) -> some View {
        HStack {
            Toggle(isOn: binding(for: selection)) { label }.toggleStyle(.checkbox)
            Spacer()
            Button("Synchronizuj") { sync(selection) }.controlSize(.mini).disabled(model.isWorking)
        }
    }

    private func sync(_ selection: AppModel.MCPSelection) {
        Task {
            if selection.isRoot, let root = model.projectRoots.first(where: { $0.id == selection.id }) { await model.syncRoot(root) }
            else if let project = model.projects.first(where: { $0.id == selection.id }) { await model.syncEverything(project) }
        }
    }
}
