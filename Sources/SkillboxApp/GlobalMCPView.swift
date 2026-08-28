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

    /// Same grouping Projekty shows — one bucket per physical folder, root and standalone siblings
    /// together, since a root's `groupKey` is its own folder path. A project that opted out of the
    /// folder's shared settings (Projekty's "Własne ustawienia") lands in the same group as the
    /// folder's single row instead of a separately-named one that only looks unrelated.
    private var groups: [(key: String, name: String, items: [AppModel.MCPSelection])] {
        var order: [String] = []
        var buckets: [String: [AppModel.MCPSelection]] = [:]
        for selection in selections {
            if buckets[selection.groupKey] == nil { order.append(selection.groupKey) }
            buckets[selection.groupKey, default: []].append(selection)
        }
        return order.map { key in (key, buckets[key]?.first?.groupName ?? key, buckets[key] ?? []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var disabledCount: Int { selections.filter { model.isGlobalServerDisabled(selectionID: $0.id, tool: tool, name: name) }.count }
    /// Set when a checkbox for a project that still follows its folder was clicked — confirmed before
    /// actually splitting it off, since that also detaches its skills, MCP and doc from the folder,
    /// not only this one server.
    @State private var pendingPromotion: (project: Project, disabled: Bool)?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(groups, id: \.key) { group in
                if let rootItem = group.items.first(where: \.isRoot) {
                    // Every actual project in the folder, individually — not the folder's one
                    // collapsed default — so any single one of them can be picked out.
                    VStack(alignment: .leading, spacing: 4) {
                        Label(group.name, systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.projects(inRoot: rootItem.id)) { member in
                            memberRow(member, rootID: rootItem.id).padding(.leading, Space.row + 12)
                        }
                    }.padding(.leading, Space.row).padding(.top, 2)
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
                Spacer()
                // Whichever direction still does something: hidden once every selection already
                // agrees, so this never offers a no-op click.
                if disabledCount < selections.count {
                    Button("Wyłącz wszędzie") { Task { await model.setGlobalServerDisabledEverywhere(tool: tool, name: name, disabled: true, selections: selections) } }
                        .buttonStyle(.link).controlSize(.small).disabled(model.isWorking)
                }
                if disabledCount > 0 {
                    Button("Włącz wszędzie") { Task { await model.setGlobalServerDisabledEverywhere(tool: tool, name: name, disabled: false, selections: selections) } }
                        .buttonStyle(.link).controlSize(.small).disabled(model.isWorking)
                }
            }
        }
        .confirmationDialog(
            pendingPromotion.map { "Dać „\($0.project.name)” własne ustawienia?" } ?? "",
            isPresented: Binding(get: { pendingPromotion != nil }, set: { if !$0 { pendingPromotion = nil } })
        ) {
            Button("Tak, przełącz \(name) tylko dla tego projektu") {
                if let pending = pendingPromotion { Task { await model.setGlobalServerDisabled(project: pending.project, tool: tool, name: name, disabled: pending.disabled) } }
                pendingPromotion = nil
            }
            Button("Anuluj", role: .cancel) { pendingPromotion = nil }
        } message: {
            Text("Ten projekt dziś dziedziczy skille, serwery MCP i dokument z folderu „\(pendingPromotion?.project.name ?? "")”. Zacznie od dokładnie tego, co ma teraz, ale przestanie automatycznie dostawać przyszłe zmiany folderu — to samo co przełącznik „Własne ustawienia” w edytorze projektu.")
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

    /// A single project inside a shared folder. One still following the folder shows a badge and a
    /// checkbox bound to the folder's current state; unchecking it asks to split it off first (see
    /// `pendingPromotion`) instead of silently forking the whole folder's other settings for it.
    @ViewBuilder
    private func memberRow(_ member: AppModel.FolderProject, rootID: UUID) -> some View {
        let effectiveID = member.inherits ? rootID : member.project.id
        HStack {
            Toggle(isOn: Binding(
                get: { !model.isGlobalServerDisabled(selectionID: effectiveID, tool: tool, name: name) },
                set: { inherited in
                    if member.inherits { pendingPromotion = (member.project, !inherited) }
                    else { Task { await model.setGlobalServerDisabled(selectionID: member.project.id, tool: tool, name: name, disabled: !inherited) } }
                }
            )) {
                HStack(spacing: Space.tight) {
                    Text(member.project.name)
                    if member.inherits { MetaBadge(text: "dziedziczy z folderu") }
                }
            }.toggleStyle(.checkbox)
            .help(member.inherits ? "Dziś dzieli ustawienia z resztą folderu. Zmiana tego przełącznika da mu własne ustawienia." : "")
            Spacer()
            Button("Synchronizuj") { Task { await model.syncEverything(member.project) } }.controlSize(.mini).disabled(model.isWorking)
        }
    }

    private func sync(_ selection: AppModel.MCPSelection) {
        Task {
            if selection.isRoot, let root = model.projectRoots.first(where: { $0.id == selection.id }) { await model.syncRoot(root) }
            else if let project = model.projects.first(where: { $0.id == selection.id }) { await model.syncEverything(project) }
        }
    }
}
