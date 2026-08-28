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
        let groups = model.globalMCPGroups(tool: tool)
        Section {
            if names.isEmpty {
                Text("Nie znaleziono żadnych globalnych serwerów.").font(.caption).foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text("Znaleziono \(names.count), ale żaden projekt nie ma zaznaczonego \(title) — nie ma tu więc czego wyłączać.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in GlobalServerRow(model: model, tool: tool, name: name, groups: groups) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(source).font(.caption2).foregroundStyle(.tertiary).textCase(nil)
            }
        }
    }
}

/// One global server, expandable into every project that can see it — each with its own opt-out
/// toggle, grouped by folder the way Projekty groups them. Collapsed by default so a long project
/// list does not turn this into a wall of checkboxes.
private struct GlobalServerRow: View {
    @ObservedObject var model: AppModel
    let tool: Tool
    let name: String
    let groups: [AppModel.GlobalMCPGroup]
    @State private var expanded = false
    /// Set when a checkbox for a project that still follows its folder was clicked — confirmed before
    /// actually splitting it off, since that also detaches its skills, MCP and doc from the folder,
    /// not only this one server.
    @State private var pendingPromotion: (row: AppModel.GlobalMCPRow, folderName: String, disabled: Bool)?

    private var rows: [AppModel.GlobalMCPRow] { groups.flatMap(\.rows) }
    /// Counted in projects, not in selections: one folder stands for several projects, and a badge
    /// whose denominator disagreed with the number of visible checkboxes only read as a bug.
    private var disabledCount: Int { rows.filter { model.isGlobalServerDisabled(selectionID: $0.selectionID, tool: tool, name: name) }.count }
    /// Where the opt-outs actually live. Setting a folder once covers every project following it,
    /// so "wszędzie" never splits projects off one by one.
    private var selectionIDs: [UUID] { Array(Set(rows.map(\.selectionID))) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Label(group.name, systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.rows) { row in
                        projectRow(row, folderName: group.name).padding(.leading, Space.row + 12)
                    }
                }.padding(.leading, Space.row).padding(.top, 2)
            }
        } label: {
            HStack(spacing: Space.tight + 2) {
                Text(name).fontWeight(.medium)
                if disabledCount > 0 { MetaBadge(text: "wyłączony w \(disabledCount)/\(rows.count)", tint: .orange) }
                Spacer()
                // Whichever direction still does something: hidden once every project already
                // agrees, so this never offers a no-op click.
                if disabledCount < rows.count {
                    Button("Wyłącz wszędzie") { Task { await model.setGlobalServerDisabledEverywhere(tool: tool, name: name, disabled: true, selectionIDs: selectionIDs) } }
                        .buttonStyle(.link).controlSize(.small).disabled(model.isWorking)
                }
                if disabledCount > 0 {
                    Button("Włącz wszędzie") { Task { await model.setGlobalServerDisabledEverywhere(tool: tool, name: name, disabled: false, selectionIDs: selectionIDs) } }
                        .buttonStyle(.link).controlSize(.small).disabled(model.isWorking)
                }
            }
        }
        .confirmationDialog(
            pendingPromotion.map { "Dać „\($0.row.project.name)” własne ustawienia?" } ?? "",
            isPresented: Binding(get: { pendingPromotion != nil }, set: { if !$0 { pendingPromotion = nil } })
        ) {
            Button("Tak, przełącz \(name) tylko dla tego projektu") {
                if let pending = pendingPromotion { Task { await model.setGlobalServerDisabled(row: pending.row, tool: tool, name: name, disabled: pending.disabled) } }
                pendingPromotion = nil
            }
            Button("Anuluj", role: .cancel) { pendingPromotion = nil }
        } message: {
            Text("Ten projekt dziś dziedziczy skille, serwery MCP i dokument z folderu „\(pendingPromotion?.folderName ?? "")”. Zacznie od dokładnie tego, co ma teraz, ale przestanie automatycznie dostawać przyszłe zmiany folderu — to samo co przełącznik „Własne ustawienia” w edytorze projektu.")
        }
    }

    /// A single project. One still following its folder shows a badge and a checkbox reflecting the
    /// folder's shared decision; changing it asks to split the project off first (see
    /// `pendingPromotion`) instead of silently forking the folder's other settings for it.
    @ViewBuilder
    private func projectRow(_ row: AppModel.GlobalMCPRow, folderName: String) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { !model.isGlobalServerDisabled(selectionID: row.selectionID, tool: tool, name: name) },
                set: { inherited in
                    if row.inherits { pendingPromotion = (row, folderName, !inherited) }
                    else { Task { await model.setGlobalServerDisabled(selectionID: row.selectionID, tool: tool, name: name, disabled: !inherited) } }
                }
            )) {
                HStack(spacing: Space.tight) {
                    Text(row.project.name)
                    if row.inherits { MetaBadge(text: "dziedziczy z folderu") }
                }
            }.toggleStyle(.checkbox)
            .help(row.inherits ? "Dziś dzieli ustawienia z resztą folderu. Zmiana tego przełącznika da mu własne ustawienia." : "")
            Spacer()
            Button("Synchronizuj") { Task { await model.syncEverything(row.project) } }.controlSize(.mini).disabled(model.isWorking)
        }
    }
}
