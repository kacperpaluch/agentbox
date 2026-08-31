import Foundation

public enum ClaudePluginScope: String, CaseIterable, Identifiable, Sendable {
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
        if !source.isEmpty { _ = try ProcessRunner.run("/usr/bin/env", ["claude", "plugin", "marketplace", "add", source, "--scope", scope.rawValue], cwd: project) }
        _ = try ProcessRunner.run("/usr/bin/env", ["claude", "plugin", "install", identifier, "--scope", scope.rawValue], cwd: project)
    }

    public func uninstallClaudePlugin(projectPath: String, plugin: ClaudePlugin) throws {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        _ = try ProcessRunner.run("/usr/bin/env", ["claude", "plugin", "uninstall", plugin.id, "--scope", plugin.scope.rawValue], cwd: project)
    }
}
