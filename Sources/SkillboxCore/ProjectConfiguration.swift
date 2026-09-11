import Foundation

public enum LibraryItemReference: Hashable, Sendable {
    case skill(String), server(UUID), document(String), plugin(UUID)
}

public struct ProjectConfigurationItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let reason: String
    public let state: String
    public let paths: [String]
    public let reference: LibraryItemReference?
    public let changes: [SkillFileChange]
}

public struct ProjectConfigurationReport: Sendable {
    public let project: Project
    public let inheritedRoot: ProjectRoot?
    public let items: [ProjectConfigurationItem]
    public let globalSkills: [String]
    public let problems: [String]
}

extension SkillboxService {
    /// Explains the same effective selection used by synchronization, without changing the project.
    public func projectConfiguration(projectID: UUID) async throws -> ProjectConfigurationReport {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let selection = Self.selection(for: .project(projectID), config: config, resolvingInheritance: true)
        let inheritedRoot = config.inheritsRoot(project) ? config.roots.first { $0.id == project.rootID } : nil
        let source = inheritedRoot.map { "Folder „\($0.name)”" } ?? "Projekt „\(project.name)”"
        let catalog = try await store.catalog(), mcp = try await store.mcpConfiguration(), docs = try await store.docsConfiguration()
        var problems: [String] = [], items: [ProjectConfigurationItem] = []
        var preview: ProjectSyncPreview?
        do { preview = try await previewProjectSync(projectID: projectID) }
        catch { problems.append(error.localizedDescription) }
        func reason(direct: Bool, tags: [String], chosen: [String]) -> String? {
            let matches = tags.filter { tag in chosen.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.sorted()
            let causes = (direct ? ["wybór bezpośredni"] : []) + matches.map { "tag #\($0)" }
            return causes.isEmpty ? nil : source + " → " + causes.joined(separator: ", ")
        }
        let selected = Set(Self.selectedSkills(in: catalog, for: project).map(\.id))
        var drifted = Set<String>()
        if preview != nil {
            do { drifted = Set(try await driftedSkills(projectID: projectID).map { "\($0.tool.rawValue)/\($0.skillID)" }) }
            catch { problems.append(error.localizedDescription) }
        }
        for skill in catalog.skills.sorted(by: { $0.name < $1.name }) {
            let excluded = selection.excludedSkillIDs.contains(skill.id)
            guard let why = reason(direct: selection.skillIDs.contains(skill.id), tags: skill.tags, chosen: selection.skillTags) ?? (excluded ? source + " → wykluczenie" : nil) else { continue }
            if excluded || project.tools.isEmpty {
                items.append(ProjectConfigurationItem(id: "skill/\(skill.id)", name: skill.name, kind: "Skill", reason: why, state: excluded ? "Wykluczony" : "Brak wybranego klienta", paths: [], reference: .skill(skill.id), changes: []))
                continue
            }
            guard selected.contains(skill.id) else { continue }
            for tool in project.tools {
                let path = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath).appending(path: skill.id)
                var state = "Zablokowany — zobacz problem powyżej", changes: [SkillFileChange] = []
                if let plan = preview?.skills.first(where: { $0.tool == tool }) {
                    do {
                        guard Self.isSafeSkillID(skill.id) else { throw SkillboxError.unsafePath(skill.id) }
                        let desired = try SkillTree.read(try await skillDirectory(skill.id))
                        let exists = FileManager.default.fileExists(atPath: path.path)
                        let current = exists ? try SkillTree.read(path) : SkillTree(entries: [:])
                        changes = current.changes(to: desired)
                        if plan.added.contains(skill.id) { state = "Do dodania" }
                        else if drifted.contains("\(tool.rawValue)/\(skill.id)") { state = "Zmiana w projekcie" }
                        else { state = changes.isEmpty ? "Aktualny" : "Do aktualizacji" }
                    } catch { state = "Nie można porównać"; problems.append(error.localizedDescription) }
                }
                items.append(ProjectConfigurationItem(id: "skill/\(tool.rawValue)/\(skill.id)", name: skill.name, kind: "Skill · \(tool.rawValue)", reason: why, state: state, paths: [path.path], reference: .skill(skill.id), changes: changes))
            }
        }
        // MCP state describes its shared file, not a claim that a particular server changed.
        for server in mcp.servers.sorted(by: { $0.name < $1.name }) {
            guard let why = reason(direct: selection.serverIDs.contains(server.id), tags: server.tags ?? [], chosen: selection.serverTags) else { continue }
            let plans = preview?.mcp.filter { project.tools.contains($0.tool) } ?? []
            let state: String
            if !server.enabled { state = "Wyłączony w bibliotece" }
            else if project.tools.isEmpty { state = "Brak wybranego klienta" }
            else if preview == nil { state = "Zablokowany — zobacz problem powyżej" }
            else if plans.contains(where: { $0.added.contains(server.name) }) { state = "Do dodania" }
            else { state = plans.allSatisfy { Self.fileMatches($0.file, content: $0.content) } ? "Aktualny" : "Plik MCP wymaga synchronizacji" }
            items.append(ProjectConfigurationItem(id: "mcp/\(server.id)", name: server.name, kind: "MCP", reason: why, state: state, paths: plans.map(\.file), reference: .server(server.id), changes: []))
        }
        let globalDisabled = mcp.projectDisabledGlobalServers?[config.selectionID(for: project).uuidString] ?? [:]
        for tool in project.tools {
            for name in (globalDisabled[tool.rawValue] ?? []).sorted() {
                let plan = preview?.mcp.first { $0.tool == tool }
                let state: String
                if let plan {
                    let file = plan.disabledGlobalFile ?? plan.file
                    let content = plan.disabledGlobalContent ?? plan.content
                    state = Self.fileMatches(file, content: content) ? "Wyłączenie zapisane" : "Wyłączenie do synchronizacji"
                } else { state = "Nie można sprawdzić" }
                items.append(ProjectConfigurationItem(id: "global-mcp/\(tool)/\(name)", name: name, kind: "Globalny MCP · \(tool.rawValue)", reason: source + " → wyłączenie serwera globalnego w tym projekcie", state: state, paths: plan.map { [$0.disabledGlobalFile ?? $0.file] } ?? [], reference: nil, changes: []))
            }
        }
        for doc in docs.docs.sorted(by: { $0.name < $1.name }) {
            guard let why = reason(direct: selection.docIDs.contains(doc.id), tags: doc.tags, chosen: selection.docTags) else { continue }
            let plans = preview?.docs ?? []
            let state = preview == nil ? "Zablokowany — zobacz problem powyżej" : plans.allSatisfy { Self.fileMatches($0.file, content: $0.content) } ? "Aktualny" : "Do synchronizacji"
            items.append(ProjectConfigurationItem(id: "doc/\(doc.id)", name: doc.name, kind: "Dokument", reason: why, state: state, paths: plans.map(\.file), reference: .document(doc.id), changes: []))
        }
        for plugin in catalog.claudePlugins ?? [] where (selection.claudePluginIDs ?? []).contains(plugin.id) {
            let status = preview?.plugins.first { $0.id == plugin.id }
            items.append(ProjectConfigurationItem(id: "plugin/\(plugin.id)", name: plugin.name, kind: "Plugin Claude", reason: source + " → wybór bezpośredni", state: status.map { $0.isInstalled ? "Zapisany w ustawieniach Claude" : "Do instalacji" } ?? "Nie można sprawdzić", paths: [URL(fileURLWithPath: project.path).appending(path: plugin.scope.settingsPath).path], reference: .plugin(plugin.id), changes: []))
        }
        if let preview {
            for plan in preview.skills {
                for id in plan.removed {
                    items.append(ProjectConfigurationItem(id: "remove/\(plan.tool)/\(id)", name: id, kind: "Skill · \(plan.tool.rawValue)", reason: "Poprzedni manifest Agentbox; brak w obecnym wyborze tego klienta", state: "Do usunięcia", paths: [URL(fileURLWithPath: plan.target).appending(path: id).path], reference: catalog.skills.contains { $0.id == id } ? .skill(id) : nil, changes: []))
                }
            }
            for plan in preview.mcp {
                for name in plan.removed {
                    items.append(ProjectConfigurationItem(id: "remove-mcp/\(plan.tool)/\(name)", name: name, kind: "MCP · \(plan.tool.rawValue)", reason: "Poprzedni manifest Agentbox; brak w obecnym wyborze tego klienta", state: "Do usunięcia", paths: [plan.file], reference: nil, changes: []))
                }
            }
            for plan in preview.docs where !plan.removed.isEmpty {
                items.append(ProjectConfigurationItem(id: "remove-doc/\(plan.file)", name: plan.removed.joined(separator: ", "), kind: "Dokument", reason: "Poprzedni manifest Agentbox", state: "Do usunięcia lub zastąpienia", paths: [plan.file], reference: nil, changes: []))
            }
        }
        let global = config.storedSelection(for: .global)
        let globalSkills = try await selectedSkills(ids: global.skillIDs, tags: global.skillTags, excluding: global.excludedSkillIDs)
        return ProjectConfigurationReport(project: project, inheritedRoot: inheritedRoot, items: items, globalSkills: global.tools.isEmpty ? [] : globalSkills.map { "\($0.name) · \(global.tools.map(\.rawValue).joined(separator: ", "))" }, problems: Array(Set(problems)).sorted())
    }
}
