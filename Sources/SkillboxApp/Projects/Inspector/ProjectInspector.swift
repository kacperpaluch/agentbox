import SwiftUI
import SkillboxCore

/// One project, in one place. It used to take four sheets — the configuration report, the editor,
/// Claude plugins and the folder switch inside the editor — each opened from the row's menu. Now
/// selecting the row answers what the project gets, lets the choice be changed next to that answer,
/// and keeps synchronization one click away, behind the same preview as before.
struct ProjectInspector: View {
    let model: AppModel
    let project: Project
    @AppStorage("AgentboxInspectorTab") private var tab: InspectorTab = .overview
    @State private var syncing = false
    @State private var adopting = false
    @State private var confirmingFollow = false

    private var state: ProjectStatus.State? { model.statuses[project.id]?.state }
    private var root: ProjectRoot? { model.root(for: project) }
    private var tabs: [InspectorTab] { model.enabledTools.contains(.claude) ? InspectorTab.allCases : [.overview, .attachments] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Space.page)
            Divider()
            Picker("Widok", selection: $tab) { ForEach(tabs) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, Space.page).padding(.vertical, Space.row)
            Divider()
            switch tabs.contains(tab) ? tab : .overview {
            case .overview: scrolling { ProjectOverviewSection(model: model, project: project) { adopting = true } }
            // Scrolls itself, so its save bar can stay pinned below the form.
            case .attachments: ProjectAttachmentsSection(model: model, project: project)
            case .plugins: scrolling { ClaudePluginsSection(model: model, project: project) }
            }
        }
        .sheet(isPresented: $syncing) { MCPPreviewView(model: model, project: project) }
        .sheet(isPresented: $adopting) { AdoptSkillsView(model: model, project: project) }
        .confirmationDialog("Przełączyć \(project.name) na ustawienia folderu?", isPresented: $confirmingFollow) {
            Button("Przełącz na ustawienia folderu", role: .destructive) { Task { await model.followRoot([model.storedProject(id: project.id) ?? project]) } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Własny wybór projektu zostanie usunięty. Pliki zmienią się przy synchronizacji.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.title3.bold()).lineLimit(1)
                Spacer()
                if isPending {
                    Button("Synchronizuj…") { syncing = true }.buttonStyle(.borderedProminent).disabled(model.isWorking)
                } else {
                    Button("Synchronizuj…") { syncing = true }.disabled(model.isWorking || state == .missing)
                }
            }
            Text(project.path).rowMetadata().lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(project.path)
            ProjectStatusBadge(state: state)
            if case .blocked(let reason)? = state { Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let root { sourcePicker(root) }
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView { content().padding(Space.page).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var isPending: Bool { if case .pending? = state { true } else { false } }

    /// Where the choice comes from, switched in place. Leaving the folder keeps what the project gets
    /// today; returning to it drops the project's own choice, so that direction asks first.
    private func sourcePicker(_ root: ProjectRoot) -> some View {
        let inherits = model.inheritsRoot(project)
        return VStack(alignment: .leading, spacing: Space.tight) {
            Picker("Ustawienia", selection: Binding(get: { inherits }, set: { follow in
                guard follow != inherits else { return }
                if follow { confirmingFollow = true } else { Task { await model.promoteToOwnSettings(model.storedProject(id: project.id) ?? project) } }
            })) {
                Text("Z folderu „\(root.name)”").tag(true)
                Text("Własne").tag(false)
            }
            .pickerStyle(.segmented).disabled(model.isWorking)
            if inherits { Text("Zmiana wyboru obejmie \(PolishNoun.project(model.followers(of: root))) w tym folderze.").rowMetadata() }
        }
    }
}
