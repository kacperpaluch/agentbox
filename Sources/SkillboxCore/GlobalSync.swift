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
        // Exclusions are offered in the same editor as the choices, so leaving them out here meant
        // the Mac quietly received a skill its owner had unticked.
        let current = try await selectedSkills(ids: chosen.skillIDs, tags: chosen.skillTags, excluding: chosen.excludedSkillIDs)
        let library = await store.skillsDirectory
        return try (chosen.tools + Self.abandonedGlobalTools(chosen: chosen, home: home)).map { tool in
            try Self.skillPreview(tool: tool, target: tool.globalSkillsURL(home: home), current: chosen.tools.contains(tool) ? current : [], library: library)
        }
    }

    /// Clients no longer ticked for this Mac whose user directory still holds an Agentbox manifest.
    /// Unticking one used to leave every skill it had received sitting there forever — the project
    /// path has answered this correctly for a long time; the global one never did.
    static func abandonedGlobalTools(chosen: AttachmentSelection, home: URL) -> [Tool] {
        Tool.allCases.filter { tool in
            guard !chosen.tools.contains(tool) else { return false }
            return FileManager.default.fileExists(atPath: tool.globalSkillsURL(home: home).appending(path: ".skillbox.json").path)
        }
    }

    /// Applies the stored selection. Every tool is previewed first, so an unmanaged skill directory
    /// in any target stops the run before the first write.
    @discardableResult
    public func syncGlobalSelection(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let previews = try await previewGlobalSync(home: home)
        let chosen = try await selection(for: .global)
        for tool in chosen.tools {
            _ = try await syncGlobal(tool: tool, skillIDs: chosen.skillIDs, tags: chosen.skillTags, excluding: chosen.excludedSkillIDs, home: home)
        }
        for tool in Self.abandonedGlobalTools(chosen: chosen, home: home) {
            _ = try await syncGlobal(tool: tool, skillIDs: [], tags: [], home: home)
        }
        return previews
    }
}
