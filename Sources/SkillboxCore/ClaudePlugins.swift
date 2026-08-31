import Foundation

public enum ClaudePluginScope: String, CaseIterable, Identifiable, Sendable, Codable {
    case project, local
    public var id: String { rawValue }
    public var displayName: String { self == .project ? "Projekt — wspólne z zespołem" : "Tylko ten Mac" }
    /// Where Claude Code records an enabled plugin for this scope, relative to the project folder.
    public var settingsPath: String { self == .project ? ".claude/settings.json" : ".claude/settings.local.json" }
}

public struct ClaudePlugin: Identifiable, Hashable, Sendable {
    public var id: String
    public var scope: ClaudePluginScope
    public var enabled: Bool
    public init(id: String, scope: ClaudePluginScope, enabled: Bool) { self.id = id; self.scope = scope; self.enabled = enabled }
}

/// One selected library plugin, together with the answer synchronization needs: is it already
/// declared in this project? Project status counts the missing ones, so a plugin waiting to be
/// installed no longer hides behind a `synchronized` badge.
public struct ClaudePluginPreview: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var plugin: String
    public var scope: ClaudePluginScope
    public var isInstalled: Bool
    public init(id: UUID, name: String, plugin: String, scope: ClaudePluginScope, isInstalled: Bool) {
        self.id = id; self.name = name; self.plugin = plugin; self.scope = scope; self.isInstalled = isInstalled
    }
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
        let stored = try Self.validated(plugin, among: values)
        values.append(stored); catalog.claudePlugins = values
        try await store.save(catalog)
    }

    /// Corrects a definition in place. The identity stays the same, so every project that already
    /// selected this plugin follows the correction instead of silently keeping the old identifier.
    public func updateLibraryClaudePlugin(_ plugin: ClaudePluginDefinition) async throws {
        var catalog = try await store.catalog()
        var values = catalog.claudePlugins ?? []
        guard let index = values.firstIndex(where: { $0.id == plugin.id }) else {
            throw SkillboxError.skillNotFound(plugin.name)
        }
        values[index] = try Self.validated(plugin, among: values.filter { $0.id != plugin.id })
        catalog.claudePlugins = values
        try await store.save(catalog)
    }

    /// Removes the definition and every selection pointing at it. Plugins already installed by
    /// Claude Code stay where they are — Agentbox only stops asking for them — which is why the
    /// project panel keeps its own `Usuń` for what is actually on disk.
    public func deleteLibraryClaudePlugin(id: UUID) async throws {
        var catalog = try await store.catalog()
        var values = catalog.claudePlugins ?? []
        guard values.contains(where: { $0.id == id }) else { throw SkillboxError.skillNotFound(id.uuidString) }
        values.removeAll { $0.id == id }
        catalog.claudePlugins = values
        var config = try await store.configuration()
        for key in config.selections.keys {
            guard var ids = config.selections[key]?.claudePluginIDs, ids.contains(id) else { continue }
            ids.removeAll { $0 == id }
            config.selections[key]?.claudePluginIDs = ids
        }
        // One write for both files: a definition that vanished from the catalog while a project
        // still pointed at it would be a selection nothing can resolve.
        try await store.save(catalog, config)
    }

    /// A definition is only useful if Claude Code can act on it, so the identifier is checked here
    /// rather than at install time — an unusable entry never reaches the library in the first place.
    static func validated(_ plugin: ClaudePluginDefinition, among others: [ClaudePluginDefinition]) throws -> ClaudePluginDefinition {
        var stored = plugin
        stored.name = plugin.name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.plugin = plugin.plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.marketplace = plugin.marketplace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.name.isEmpty else { throw SkillboxError.invalidSkill("podaj nazwę pluginu") }
        guard !stored.plugin.isEmpty else { throw SkillboxError.invalidSkill("podaj identyfikator pluginu") }
        guard !others.contains(where: { $0.plugin == stored.plugin && $0.scope == stored.scope }) else {
            throw SkillboxError.duplicateSkill(stored.plugin)
        }
        guard !others.contains(where: { $0.name.caseInsensitiveCompare(stored.name) == .orderedSame }) else {
            throw SkillboxError.invalidSkill("plugin o nazwie \(stored.name) już jest w bibliotece")
        }
        return stored
    }

    /// Installs a project's selected plugins as one step. Claude Code writes its own
    /// `.claude/settings.json`, which the sync backup does not cover, so the two settings files are
    /// snapshotted here and put back if any plugin fails: a half-applied selection would otherwise
    /// survive a rolled-back synchronization. The CLI's own cache keeps the downloaded plugin, and
    /// installing again is idempotent, so a retry after the cause is fixed costs nothing.
    public func installLibraryClaudePlugins(projectPath: String, ids: [UUID]) async throws {
        let catalog = try await store.catalog()
        let selected = (catalog.claudePlugins ?? []).filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        let snapshot = Self.settingsSnapshot(project)
        do {
            for item in selected {
                try installClaudePlugin(projectPath: projectPath, marketplace: item.marketplace, plugin: item.plugin, scope: item.scope)
            }
        } catch {
            Self.restore(snapshot)
            throw error
        }
    }

    /// The two files Claude Code rewrites when a plugin is installed, as they are right now. A file
    /// that does not exist yet is recorded as `nil`, so restoring removes it again instead of
    /// leaving an empty one behind.
    static func settingsSnapshot(_ project: URL) -> [(URL, Data?)] {
        Self.claudeSettingsFiles(project).map { ($0, try? Data(contentsOf: $0)) }
    }

    static func restore(_ snapshot: [(URL, Data?)]) {
        for (url, data) in snapshot {
            if let data { try? data.write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func claudeSettingsFiles(_ project: URL) -> [URL] {
        ClaudePluginScope.allCases.map { project.appending(path: $0.settingsPath) }
    }

    /// Which of a project's selected plugins Claude Code already knows about. Used by the sync
    /// preview and by the project status, so both answer the question the same way.
    public func previewClaudePlugins(projectPath: String, ids: [UUID]) async throws -> [ClaudePluginPreview] {
        let selected = (try await store.catalog().claudePlugins ?? []).filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return [] }
        let installed = (try? claudePlugins(projectPath: projectPath)) ?? []
        return selected
            .map { ClaudePluginPreview(id: $0.id, name: $0.name, plugin: $0.plugin, scope: $0.scope, isInstalled: Self.isDeclared($0, among: installed)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Claude Code keys its settings by `plugin@marketplace`, but a definition may name only the
    /// plugin. Both spellings must resolve to the same entry, otherwise a project would report a
    /// pending install forever. A declared-but-disabled plugin counts as installed: reinstalling
    /// would not enable it, and reporting it as missing would never stop.
    static func isDeclared(_ definition: ClaudePluginDefinition, among installed: [ClaudePlugin]) -> Bool {
        let identifier = definition.plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        return installed.contains { entry in
            guard entry.scope == definition.scope else { return false }
            return entry.id == identifier || entry.id.split(separator: "@").first.map(String.init) == identifier
        }
    }

    /// A project following its parent folder shares that folder's selection, so writing here would
    /// change every sibling project at once. Refusing is the same answer the skill and MCP editors
    /// give: change the folder, or give the project its own settings first.
    public func setClaudePluginSelection(projectID: UUID, ids: [UUID]) async throws {
        var config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        try Self.assertOwnSettings(project, in: config)
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
            let file = project.appending(path: scope.settingsPath)
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = root["enabledPlugins"] as? [String: Any] else { continue }
            result += enabled.compactMap { name, value in
                guard let isEnabled = Self.enabledFlag(value) else { return nil }
                return ClaudePlugin(id: name, scope: scope, enabled: isEnabled)
            }
        }
        return result.sorted { ($0.scope.rawValue, $0.id) < ($1.scope.rawValue, $1.id) }
    }

    /// Claude Code writes `true`/`false` today, but the key is its own and richer forms exist in the
    /// wild — an object carrying configuration, or a string from a hand-edited file. Anything named
    /// under `enabledPlugins` is a plugin this project declares, so an unrecognized shape is listed
    /// as enabled rather than dropped without a word. Only an explicit null is skipped.
    static func enabledFlag(_ value: Any) -> Bool? {
        switch value {
        case is NSNull: return nil
        case let flag as Bool: return flag
        case let object as [String: Any]: return Self.enabledFlag(object["enabled"] ?? true) ?? true
        case let text as String: return !["false", "off", "no", "0", "disabled"].contains(text.lowercased())
        default: return true
        }
    }

    public func installClaudePlugin(projectPath: String, marketplace: String?, plugin: String, scope: ClaudePluginScope) throws {
        let source = marketplace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw SkillboxError.invalidSkill("podaj nazwę pluginu") }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: project.path) else { throw SkillboxError.projectNotFound(projectPath) }
        let executable = try Self.claudeExecutable()
        if !source.isEmpty { _ = try ProcessRunner.run(executable, ["plugin", "marketplace", "add", source, "--scope", scope.rawValue], cwd: project) }
        // `--yes` matters for a plugin whose marketplace installs it by running a command: the CLI
        // requires it whenever stdin is not a terminal, and Agentbox always runs it without one.
        _ = try ProcessRunner.run(executable, ["plugin", "install", identifier, "--scope", scope.rawValue, "--yes"], cwd: project)
    }

    /// Removing a plugin also drops it from the project's library selection. Without that the next
    /// synchronization would reinstall exactly what was just removed, which reads as the removal
    /// having silently failed. A project following its folder keeps the folder's selection: the
    /// removal applies to this folder on disk, and the shared choice is the folder's to change.
    @discardableResult
    public func uninstallClaudePlugin(projectPath: String, plugin: ClaudePlugin) async throws -> Bool {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        _ = try ProcessRunner.run(try Self.claudeExecutable(), ["plugin", "uninstall", plugin.id, "--scope", plugin.scope.rawValue, "--yes"], cwd: project)
        return try await deselectClaudePlugin(projectPath: projectPath, plugin: plugin)
    }

    /// The library half of a removal, separate from the CLI call so it can be exercised without one.
    @discardableResult
    func deselectClaudePlugin(projectPath: String, plugin: ClaudePlugin) async throws -> Bool {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        var config = try await store.configuration()
        guard let stored = config.projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == project.path }),
              !config.inheritsRoot(stored) else { return false }
        let definitions = (try await store.catalog().claudePlugins ?? []).filter { definition in
            Self.isDeclared(definition, among: [plugin])
        }
        let removed = Set(definitions.map(\.id))
        let key = config.selectionID(for: stored).uuidString
        guard var ids = config.selections[key]?.claudePluginIDs, ids.contains(where: { removed.contains($0) }) else { return false }
        ids.removeAll { removed.contains($0) }
        config.selections[key]?.claudePluginIDs = ids
        try await store.save(config)
        return true
    }
}
