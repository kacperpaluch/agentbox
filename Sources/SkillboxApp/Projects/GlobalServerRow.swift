import SwiftUI
import SkillboxCore

/// One global server, expandable into every project that can see it — each with its own opt-out
/// toggle, grouped by folder the way Projekty groups them. Collapsed by default so a long project
/// list does not turn this into a wall of checkboxes.
struct GlobalServerRow: View {
    let model: AppModel
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
            // Opting out is per project, so a project added next month would silently get this
            // server back. This is where that is decided once, instead of by remembering to click
            // "Wyłącz wszędzie" again.
            Toggle(isOn: Binding(
                get: { model.isGlobalServerDisabledByDefault(tool: tool, name: name) },
                set: { on in Task { await model.setGlobalServerDisabledByDefault(tool: tool, name: name, disabled: on) } }
            )) {
                Text("Wyłączaj w nowych projektach i folderach").font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(model.isWorking)
            .help("Nie zmienia projektów, które już istnieją — decyduje tylko, z czym startuje następny")
            .padding(.leading, Space.row)
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
            item: $pendingPromotion
        ) { pending in
            Button("Tak, przełącz \(name) tylko dla tego projektu") {
                Task { await model.setGlobalServerDisabled(row: pending.row, tool: tool, name: name, disabled: pending.disabled) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
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
