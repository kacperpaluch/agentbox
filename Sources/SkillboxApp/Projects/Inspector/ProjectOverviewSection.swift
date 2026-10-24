import SwiftUI
import SkillboxCore

/// What Agentbox picked for the project and why — the report the old "Konfiguracja i pochodzenie"
/// sheet showed, read again whenever the library reloads.
struct ProjectOverviewSection: View {
    let model: AppModel
    let project: Project
    let adopt: () -> Void
    @State private var report: ProjectConfigurationReport?
    @State private var error = ""
    @State private var definition: ProjectConfigurationItem?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let report {
                ForEach(report.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if report.items.contains(where: { $0.state == "Zmiana w projekcie" }) {
                    Button("Przejmij zmiany z projektu…", action: adopt)
                }
                if report.items.isEmpty { Text("Nic nie jest wybrane. Ustaw to w zakładce Wybór.").foregroundStyle(.secondary) }
                ForEach(report.items) { item in row(item) }
            } else if error.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
        .task(id: [AnyHashable(project.id), AnyHashable(model.generation)]) { await load() }
        .sheet(item: $definition) { item in definitionView(item.reference) }
    }

    private func row(_ item: ProjectConfigurationItem) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Space.tight + 2) {
                Text(item.name).rowTitle().lineLimit(1)
                Text(item.kind).rowMetadata().lineLimit(1)
                Spacer()
                Text(item.state).font(.caption.weight(.medium)).lineLimit(1)
            }
            Text(item.reason).rowMetadata()
            ForEach(item.paths, id: \.self) { Text($0).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help($0) }
            HStack {
                if !item.changes.isEmpty {
                    DisclosureGroup("Różnice (\(item.changes.count))") {
                        Text("Podgląd pokazuje jawną treść plików, która może zawierać prywatne dane.").font(.caption).foregroundStyle(.orange)
                        SkillChangesView(changes: item.changes)
                    }
                }
                Spacer()
                if item.reference != nil { Button("Definicja…") { definition = item }.controlSize(.small).buttonStyle(.link) }
            }
            Divider()
        }
    }

    private func load() async {
        do { report = try await model.projectConfiguration(project); error = "" }
        catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private func definitionView(_ reference: LibraryItemReference?) -> some View {
        switch reference {
        case .skill(let id):
            if let skill = model.skills.first(where: { $0.id == id }) { ProjectSkillDefinition(model: model, skill: skill) }
        case .server(let id):
            if let server = model.mcp.servers.first(where: { $0.id == id }) { MCPServerEditor(model: model, server: server, existingTags: Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted()) }
        case .document(let id):
            if let doc = model.docs.docs.first(where: { $0.id == id }) { DocEditorView(model: model, doc: doc, existingTags: Array(Set(model.docs.docs.flatMap(\.tags))).sorted()) }
        case .plugin(let id):
            if let plugin = model.claudePluginLibrary.first(where: { $0.id == id }) { ClaudePluginEditor(model: model, definition: plugin) }
        case nil: EmptyView()
        }
    }
}
