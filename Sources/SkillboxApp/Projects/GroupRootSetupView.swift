import SwiftUI
import SkillboxCore

/// Turns a folder that already holds projects into a parent folder with shared settings.
///
/// Adopting existing projects is not a neutral operation — a project that starts following the
/// folder synchronizes what the folder says, not what it said before. The form therefore starts
/// from everything the group already uses together and spells out, per project, what would change.
struct GroupRootSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let folderPath: String
    let projects: [Project]
    @State private var name = ""
    @State private var selection = AttachmentSelection()
    @State private var manageGitignore = false
    @State private var watchesNewFolders = true
    @State private var onlyFutureFolders = true
    @State private var following = Set<UUID>()
    @State private var loaded = false
    @State private var saving = false
    @State private var differingDocuments = false
    @State private var documentsConfirmed = false

    private var nameTaken: Bool { model.projectRoots.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var body: some View {
        // Actions stay pinned below the scrolling form: on a short display they used to
        // scroll out of reach, or sit under the Dock entirely.
        VStack(spacing: 0) {
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text("Wspólne ustawienia folderu").font(.title2.bold())
                Text(folderPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Skille, tagi i serwery MCP ustawione tutaj obowiązują wszystkie zaznaczone projekty. Późniejsza zmiana w folderze obejmuje je wszystkie naraz.").foregroundStyle(.secondary)
                TextField("Nazwa folderu", text: $name)
                if nameTaken { Label("Folder nadrzędny o tej nazwie już istnieje.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                GroupBox("Projekty w tym folderze") { VStack(alignment: .leading, spacing: 7) {
                    Text("Zaznaczone przechodzą na wspólne ustawienia. Odznaczone zostają w folderze, ale zachowują to, co mają dziś.").font(.caption).foregroundStyle(.secondary)
                    ForEach(projects) { project in
                        Toggle(isOn: setBinding(project.id, in: $following)) {
                            HStack {
                                Text(project.name)
                                Spacer()
                                Text(change(for: project)).font(.caption).foregroundStyle(following.contains(project.id) ? .secondary : .tertiary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    HStack { Button("Zaznacz wszystkie") { following = Set(projects.map(\.id)) }; Button("Wyczyść") { following.removeAll() } }
                }.padding(6) }
                GroupBox("Nowe podfoldery") { VStack(alignment: .leading, spacing: 6) {
                    Toggle("Pytaj, gdy w tym folderze pojawi się nowy podfolder", isOn: $watchesNewFolders).toggleStyle(.checkbox)
                    Text("Nowy podfolder — na przykład świeżo sklonowane repozytorium — pojawi się jako pytanie nad listą projektów oraz jako plakietka przy `Projekty`.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Pytaj tylko o podfoldery, które pojawią się od teraz", isOn: $onlyFutureFolders).toggleStyle(.checkbox).disabled(!watchesNewFolders)
                    Text(onlyFutureFolders
                         ? "Podfoldery, które są w tym folderze teraz i nie są projektami, zostają uznane za znane. Wrócą po kliknięciu `Przywróć pominięte` w ustawieniach folderu."
                         : "Agentbox zapyta także o podfoldery, które już tam leżą i nie są projektami.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6) }
                if differingDocuments {
                    GroupBox { VStack(alignment: .leading, spacing: 6) {
                        Label("Projekty używają różnych dokumentów, a folder może mieć tylko jeden. Wybierz go poniżej — przy każdym projekcie, który go zmieni, widać „inny dokument”.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Toggle("Rozumiem, że dokument części projektów się zmieni", isOn: $documentsConfirmed).toggleStyle(.checkbox)
                    }.padding(6) }
                }
                AttachmentPicker(skills: model.skills, servers: model.mcp.servers, docs: model.docs.docs, claudePlugins: model.claudePluginLibrary, selection: $selection, manageGitignore: $manageGitignore)
            }.padding(24) }
            SheetFooter {
                Button("Anuluj") { dismiss() }
                Button("Utwórz folder nadrzędny") { Task { saving = true; defer { saving = false }; if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || name.isEmpty || nameTaken || selection.tools.isEmpty || (differingDocuments && !documentsConfirmed))
            }
        }
        .sheetFrame(width: 760, height: 640)
        .onAppear { load() }
    }

    /// Starts from everything the projects in the folder already use together, so creating the
    /// folder does not quietly take anything away from any of them.
    private func load() {
        guard !loaded else { return }
        loaded = true
        name = URL(fileURLWithPath: folderPath).lastPathComponent
        following = Set(projects.map(\.id))
        // Everything the group already uses between them, unioned — one place now, where it used to
        // be eight assignments that had to agree with each other.
        let current = projects.map { model.selection(for: .project($0.id), resolvingInheritance: true) }
        selection.tools = Array(Set(current.flatMap(\.tools))).sorted { $0.rawValue < $1.rawValue }
        selection.skillIDs = Set(current.flatMap(\.skillIDs)).sorted()
        selection.skillTags = Set(current.flatMap(\.skillTags)).sorted()
        selection.serverIDs = Set(current.flatMap(\.serverIDs)).sorted { $0.uuidString < $1.uuidString }
        selection.serverTags = Set(current.flatMap(\.serverTags)).sorted()
        // One document per project: when the group uses different ones there is no union to take,
        // so nothing is picked on anyone's behalf — the form says so and waits for a choice.
        let documents = Set(current.map { resolvedDocs(ids: $0.docIDs, tags: $0.docTags) })
        if documents.count <= 1, let only = current.first {
            selection.docIDs = only.docIDs
            selection.docTags = only.docTags
        } else {
            differingDocuments = true
        }
        let plugins = Set(current.flatMap { $0.claudePluginIDs ?? [] })
        selection.claudePluginIDs = plugins.isEmpty ? nil : plugins.sorted { $0.uuidString < $1.uuidString }
        // Only what every project already excludes stays excluded; anything else would drop a skill
        // that one of them deliberately keeps.
        selection.excludedSkillIDs = projects.dropFirst()
            .reduce(Set(projects.first?.excludedSkillIDs ?? [])) { $0.intersection(Set($1.excludedSkillIDs ?? [])) }
            .sorted()
        manageGitignore = !projects.isEmpty && projects.allSatisfy { $0.manageGitignore == true }
    }

    /// What the project would gain or lose, counted the same way synchronization resolves it —
    /// every part of the selection, not only skills and servers.
    private func change(for project: Project) -> String {
        guard following.contains(project.id) else { return "zachowa własne" }
        let effective = model.selection(for: .project(project.id), resolvingInheritance: true)
        let before = resolvedSkills(ids: Set(effective.skillIDs), tags: Set(effective.skillTags), excluded: Set(effective.excludedSkillIDs))
        let after = resolvedSkills(ids: Set(selection.skillIDs), tags: Set(selection.skillTags), excluded: Set(selection.excludedSkillIDs))
        let beforeServers = resolvedServers(ids: Set(effective.serverIDs), tags: Set(effective.serverTags))
        let afterServers = resolvedServers(ids: Set(selection.serverIDs), tags: Set(selection.serverTags))
        var parts: [String] = []
        let addedSkills = after.subtracting(before).count, removedSkills = before.subtracting(after).count
        let addedServers = afterServers.subtracting(beforeServers).count, removedServers = beforeServers.subtracting(afterServers).count
        if addedSkills > 0 { parts.append("+\(addedSkills) skilli") }
        if removedSkills > 0 { parts.append("−\(removedSkills) skilli") }
        if addedServers > 0 { parts.append("+\(addedServers) MCP") }
        if removedServers > 0 { parts.append("−\(removedServers) MCP") }
        let addedTools = Set(selection.tools).subtracting(effective.tools).count, removedTools = Set(effective.tools).subtracting(selection.tools).count
        if addedTools > 0 { parts.append("+\(addedTools) narzędzi") }
        if removedTools > 0 { parts.append("−\(removedTools) narzędzi") }
        if resolvedDocs(ids: effective.docIDs, tags: effective.docTags) != resolvedDocs(ids: selection.docIDs, tags: selection.docTags) { parts.append("inny dokument") }
        let beforePlugins = Set(effective.claudePluginIDs ?? []), afterPlugins = Set(selection.claudePluginIDs ?? [])
        if afterPlugins.subtracting(beforePlugins).count > 0 { parts.append("+\(afterPlugins.subtracting(beforePlugins).count) pluginów") }
        if beforePlugins.subtracting(afterPlugins).count > 0 { parts.append("−\(beforePlugins.subtracting(afterPlugins).count) pluginów") }
        let shown = disabledGlobal(project.id).subtracting(sharedDisabledGlobal).count
        if shown > 0 { parts.append("+\(shown) globalnych MCP") }
        return parts.isEmpty ? "bez zmian" : parts.joined(separator: ", ")
    }

    private func resolvedDocs(ids: [String], tags: [String]) -> Set<String> {
        let wanted = Set(tags.map { $0.lowercased() })
        return Set(model.docs.docs.filter { ids.contains($0.id) || !wanted.isDisjoint(with: $0.tags.map { $0.lowercased() }) }.map(\.id))
    }

    /// Hidden global servers, as "tool:name", for one selection.
    private func disabledGlobal(_ id: UUID) -> Set<String> {
        Set((model.mcp.projectDisabledGlobalServers?[id.uuidString] ?? [:]).flatMap { tool, names in names.map { "\(tool):\($0)" } })
    }

    /// What the folder will keep hidden: only what every following project hides.
    private var sharedDisabledGlobal: Set<String> {
        let sets = projects.filter { following.contains($0.id) }.map { disabledGlobal($0.id) }
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }
    }

    private func resolvedSkills(ids: Set<String>, tags: Set<String>, excluded: Set<String>) -> Set<String> {
        let wanted = Set(tags.map { $0.lowercased() })
        return Set(model.skills.filter { skill in
            (ids.contains(skill.id) || !wanted.isDisjoint(with: skill.tags.map { $0.lowercased() })) && !excluded.contains(skill.id)
        }.map(\.id))
    }

    private func resolvedServers(ids: Set<UUID>, tags: Set<String>) -> Set<UUID> {
        let wanted = Set(tags.map { $0.lowercased() })
        return Set(model.mcp.servers.filter { server in
            server.enabled && (ids.contains(server.id) || !wanted.isDisjoint(with: (server.tags ?? []).map { $0.lowercased() }))
        }.map(\.id))
    }

    private func save() async -> Bool {
        let root = ProjectRoot(name: name, path: folderPath, tools: selection.tools, skillIDs: selection.skillIDs, tags: selection.skillTags, excludedSkillIDs: selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs, manageGitignore: manageGitignore, watchesNewFolders: watchesNewFolders)
        let followers = projects.map(\.id).filter { following.contains($0) }
        let owners = projects.map(\.id).filter { !following.contains($0) }
        return await model.adoptGroupIntoRoot(root, following: followers, keepingOwnSettings: owners, selection: selection, treatingExistingAsKnown: onlyFutureFolders)
    }
}
