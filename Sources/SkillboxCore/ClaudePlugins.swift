import Foundation

public enum ClaudePluginScope: String, CaseIterable, Identifiable, Sendable, Codable {
    case project, local
    public var id: String { rawValue }
    public var displayName: String { self == .project ? "Projekt — wspólne z zespołem" : "Tylko ten Mac" }
}

public struct ClaudePlugin: Identifiable, Hashable, Sendable {
    public var id: String
    public var scope: ClaudePluginScope
    public var enabled: Bool
    public init(id: String, scope: ClaudePluginScope, enabled: Bool) { self.id = id; self.scope = scope; self.enabled = enabled }
}

extension SkillboxService {
    private static func claudeExecutable() throws -> String {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        if let path = ProcessInfo.processInfo.environment["PATH"] { candidates += path.split(separator: ":").map { "\($0)/claude" } }
        if let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return executable }
        throw SkillboxError.commandFailed("Nie znaleziono Claude Code. Zainstaluj go lub upewnij się, że istnieje /opt/homebrew/bin/claude albo /usr/local/bin/claude.")
    }
    public func libraryClaudePlugins() async throws -> [ClaudePluginDefinition] {
        (try await store.catalog().claudePlugins ?? []).sorted { $0.name < $1.name }
    }

    public func addLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async throws {
        var catalog = try await store.catalog()
        var values = catalog.claudePlugins ?? []
        guard !values.contains(where: { $0.plugin == plugin.plugin }) else { throw SkillboxError.duplicateSkill(plugin.plugin) }
        values.append(plugin); catalog.claudePlugins = values
        try await store.save(catalog)
    }

    public func installLibraryClaudePlugins(projectPath: String, ids: [UUID]) async throws {
        let catalog = try await store.catalog()
        let selected = (catalog.claudePlugins ?? []).filter { ids.contains($0.id) }
        for item in selected { try installClaudePlugin(projectPath: projectPath, marketplace: item.marketplace, plugin: item.plugin, scope: item.scope) }
    }

    public func setClaudePluginSelection(projectID: UUID, ids: [UUID]) async throws {
        var config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let known = Set((try await store.catalog().claudePlugins ?? []).map(\.id))
        let selected = Array(Set(ids).intersection(known)).sorted { $0.uuidString < $1.uuidString }
        let target = config.selectionID(for: project).uuidString
        var selection = config.selections[target] ?? AttachmentSelection()
        selection.claudePluginIDs = selected
        config.selections[target] = selection
        try await store.save(config)
    }

    public func selectedClaudePluginIDs(projectID: UUID) async throws -> [UUID] {
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        return config.selections[config.selectionID(for: project).uuidString]?.claudePluginIDs ?? []
    }
    /// Claude Code owns these settings. Agentbox reads them directly for the project view but asks
    /// Claude's CLI to install, enable or remove plugins so its cache and dependency graph remain
    /// authoritative.
    public func claudePlugins(projectPath: String) throws -> [ClaudePlugin] {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        var result: [ClaudePlugin] = []
        for scope in ClaudePluginScope.allCases {
            let file = project.appending(path: scope == .project ? ".claude/settings.json" : ".claude/settings.local.json")
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = root["enabledPlugins"] as? [String: Any] else { continue }
            result += enabled.compactMap { name, value in
                guard let isEnabled = value as? Bool else { return nil }
                return ClaudePlugin(id: name, scope: scope, enabled: isEnabled)
            }
        }
        return result.sorted { ($0.scope.rawValue, $0.id) < ($1.scope.rawValue, $1.id) }
    }

    public func installClaudePlugin(projectPath: String, marketplace: String?, plugin: String, scope: ClaudePluginScope) throws {
        let source = marketplace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw SkillboxError.invalidSkill("podaj nazwę pluginu") }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: project.path) else { throw SkillboxError.projectNotFound(projectPath) }
        let executable = try Self.claudeExecutable()
        if !source.isEmpty { _ = try ProcessRunner.run(executable, ["plugin", "marketplace", "add", source, "--scope", scope.rawValue], cwd: project) }
        _ = try ProcessRunner.run(executable, ["plugin", "install", identifier, "--scope", scope.rawValue], cwd: project)
    }

    public func uninstallClaudePlugin(projectPath: String, plugin: ClaudePlugin) throws {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        _ = try ProcessRunner.run(try Self.claudeExecutable(), ["plugin", "uninstall", plugin.id, "--scope", plugin.scope.rawValue], cwd: project)
    }
}
