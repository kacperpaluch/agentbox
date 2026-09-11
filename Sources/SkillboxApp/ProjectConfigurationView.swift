import SwiftUI
import SkillboxCore

struct ProjectConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let project: Project
    @State private var report: ProjectConfigurationReport?
    @State private var error = ""
    @State private var definition: ProjectConfigurationItem?
    @State private var editingSource = false
    @State private var showSync = false
    @State private var showAdoption = false
    @State private var showClientServers = false
    @State private var showGlobalSkills = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Konfiguracja · \(project.name)").font(.title2.bold())
            Text(project.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Co Agentbox wybrał dla tego projektu i dlaczego. Stan dotyczy plików i ustawień, a nie tego, co klient AI załadował w sesji.").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let report {
                HStack {
                    Text(report.inheritedRoot.map { "Ustawienia z folderu „\($0.name)”" } ?? "Własne ustawienia projektu").font(.callout)
                    Spacer()
                    Button("Edytuj źródło przypisań…") { editingSource = true }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(report.problems, id: \.self) { Text($0).foregroundStyle(.red).textSelection(.enabled) }
                        if report.items.isEmpty { Text("Brak wybranych elementów i zmian do usunięcia.").foregroundStyle(.secondary) }
                        ForEach(report.items) { item in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.name).font(.headline)
                                        Text(item.kind).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(item.state).font(.caption.weight(.medium))
                                        if item.reference != nil { Button("Definicja…") { definition = item }.controlSize(.small) }
                                    }
                                    Text(item.reason).font(.callout)
                                    ForEach(item.paths, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if !item.changes.isEmpty {
                                        DisclosureGroup("Różnice przed synchronizacją (\(item.changes.count))") {
                                            Text("Podgląd pokazuje jawną treść plików, która może zawierać prywatne dane.").font(.caption).foregroundStyle(.orange)
                                            SkillChangesView(changes: item.changes)
                                        }
                                    }
                                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !report.globalSkills.isEmpty {
                            GroupBox("Globalne skille wybrane w Agentbox") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(report.globalSkills, id: \.self) { Text($0).font(.caption) }
                                    Text("To osobny wybór dla tego Maca; ten ekran nie sprawdza jego synchronizacji ani globalnej konfiguracji innych aplikacji.").font(.caption).foregroundStyle(.secondary)
                                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else if error.isEmpty { ProgressView() }
            HStack {
                Button("Odśwież") { Task { await load() } }.disabled(model.isWorking)
                if report?.items.contains(where: { $0.state == "Zmiana w projekcie" }) == true {
                    Button("Przejmij z projektu…") { showAdoption = true }
                }
                Menu("Ustawienia globalne") {
                    Button("Skille we wszystkich sesjach…") { showGlobalSkills = true }
                    Button("Serwery klientów…") { showClientServers = true }
                }
                Spacer()
                Button("Zamknij") { dismiss() }
                Button("Podgląd synchronizacji…") { showSync = true }.buttonStyle(.borderedProminent).disabled(report == nil || model.isWorking)
            }
        }
        .padding(24).sheetFrame(width: 940, height: 720)
        .task { await load() }
        .sheet(item: $definition, onDismiss: refresh) { item in definitionView(item.reference) }
        .sheet(isPresented: $editingSource, onDismiss: refresh) { sourceEditor }
        .sheet(isPresented: $showSync, onDismiss: refresh) { MCPPreviewView(model: model, project: project) }
        .sheet(isPresented: $showClientServers, onDismiss: refresh) { ClientServersView(model: model) }
        .sheet(isPresented: $showGlobalSkills, onDismiss: refresh) { GlobalSelectionEditor(model: model) }
        .sheet(isPresented: $showAdoption, onDismiss: refresh) { AdoptSkillsView(model: model, project: project) }
    }

    private func refresh() { Task { await load() } }
    private func load() async {
        do { report = try await model.projectConfiguration(project); error = "" }
        catch { self.error = error.localizedDescription; model.reportError(error) }
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

    @ViewBuilder private var sourceEditor: some View {
        if let root = report?.inheritedRoot {
            ProjectRootEditor(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, root: root, followingProjects: model.storedProjects.filter { $0.rootID == root.id && $0.overridesRoot != true }.count, initialSelection: model.selection(for: .root(root.id))) { updated, selection in await model.saveRoot(updated, selection: selection) }
        } else {
            ProjectEditor(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, project: model.storedProject(id: project.id) ?? project, root: model.root(for: project), initialSelection: model.selection(for: .project(project.id), resolvingInheritance: true)) { updated, selection in await model.updateProject(updated, selection: selection) }
        }
    }
}

private struct ProjectSkillDefinition: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let skill: Skill
    var body: some View {
        VStack {
            HStack { Spacer(); Button("Zamknij") { dismiss() } }.padding()
            SkillDetail(model: model, skill: skill, showsUpdates: false)
        }.sheetFrame(width: 800, height: 650)
            .task { model.selection = skill.id; await model.loadMarkdown() }
    }
}
