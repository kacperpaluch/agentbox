import Foundation

/// Skills shared by every session of a tool, written to the per-user skill directory
/// (`~/.claude/skills`, `~/.codex/skills`, `~/.config/opencode/skills`).
///
/// The Mac itself is just another place attachments land, so it has no selection type of its own —
/// it is `SelectionTarget.global`, read and written like a project or a folder. The choice still
/// lives in `projects.local.json`, because it describes this Mac rather than the library.
///
/// Only skills are synchronized globally today: `~/.codex/config.toml` and Claude Code's user scope
/// are files Agentbox deliberately never writes (see `ClientServersView`), and a global `AGENTS.md` has
/// no defined location. The server and document fields of a global selection are therefore ignored
/// here rather than silently half-applied.
extension SkillboxService {
    public func previewGlobalSync(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let chosen = try await selection(for: .global)
        let current = try await selectedSkills(ids: chosen.skillIDs, tags: chosen.skillTags)
        let library = await store.skillsDirectory
        return try chosen.tools.map { try Self.skillPreview(tool: $0, target: $0.globalSkillsURL(home: home), current: current, library: library) }
    }

    /// Applies the stored selection. Every tool is previewed first, so an unmanaged skill directory
    /// in any target stops the run before the first write.
    @discardableResult
    public func syncGlobalSelection(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let previews = try await previewGlobalSync(home: home)
        let chosen = try await selection(for: .global)
        for tool in chosen.tools {
            _ = try await syncGlobal(tool: tool, skillIDs: chosen.skillIDs, tags: chosen.skillTags, home: home)
        }
        return previews
    }
}
