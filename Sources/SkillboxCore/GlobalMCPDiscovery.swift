import Foundation

/// Read-only discovery of MCP servers a tool considers global — declared once outside any project,
/// so they load in every project automatically. Agentbox never edits the files here; it only reads
/// server *names* so a project can list them and choose to opt out locally (see `GlobalMCPServerRef`
/// and `SkillboxService.globalMCPServers`).
public enum GlobalMCPDiscovery {
    /// Names of `[mcp_servers.*]` tables in `~/.codex/config.toml` — the file Codex CLI, the Codex
    /// IDE extension and the ChatGPT desktop app all share, so anything added there (through any of
    /// them) loads in every Codex project.
    public static func codexGlobalServerNames(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let file = home.appending(path: ".codex/config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return tableNames(in: text, table: "mcp_servers")
    }

    /// Names of Claude Code's user-scope `mcpServers`, stored at the top level of `~/.claude.json`
    /// — as opposed to the per-project entries nested under `projects.<path>.mcpServers`, which are
    /// already project-scoped and not this tool's concern.
    public static func claudeGlobalServerNames(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let file = home.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return Array(servers.keys)
    }

    /// Matches `[table.name]` and `[table."name"]` TOML table headers and returns the unquoted names.
    private static func tableNames(in text: String, table: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: table)
        let pattern = "(?m)^[ \t]*\\[[ \t]*\(escaped)[ \t]*\\.[ \t]*(?:\"([^\"]+)\"|([A-Za-z0-9_-]+))[ \t]*\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            for group in [1, 2] {
                let groupRange = match.range(at: group)
                if groupRange.location != NSNotFound, let r = Range(groupRange, in: text) { return String(text[r]) }
            }
            return nil
        }
    }
}
