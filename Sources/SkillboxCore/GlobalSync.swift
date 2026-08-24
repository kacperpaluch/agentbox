import Foundation

/// Skills shared by every session of a tool, written to the per-user skill directory
/// (`~/.claude/skills`, `~/.codex/skills`, `~/.config/opencode/skills`).
///
/// The selection lives in `projects.local.json` because it describes this Mac, not the library.
public struct GlobalSkillSelection: Sendable, Equatable {
    public var tools: [Tool]
    public var skillIDs: [String]
    public var tags: [String]
    public init(tools: [Tool] = [], skillIDs: [String] = [], tags: [String] = []) {
        self.tools = tools; self.skillIDs = skillIDs; self.tags = tags
    }
}

extension SkillboxService {
    public func globalSelection() async throws -> GlobalSkillSelection {
        let config = try await store.configuration()
        return GlobalSkillSelection(tools: config.globalTools ?? [], skillIDs: config.globalSkillIDs ?? [], tags: config.globalTags ?? [])
    }

    public func setGlobalSelection(_ selection: GlobalSkillSelection) async throws {
        var config = try await store.configuration()
        config.globalTools = selection.tools
        config.globalSkillIDs = selection.skillIDs
        config.globalTags = Array(Set(selection.tags.map { $0.lowercased() })).sorted()
        try await store.save(config)
    }

    public func previewGlobalSync(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let selection = try await globalSelection()
        let current = Set(try await selectedSkills(ids: selection.skillIDs, tags: selection.tags).map(\.id))
        return try selection.tools.map { try Self.skillPreview(tool: $0, target: $0.globalSkillsURL(home: home), current: current) }
    }

    /// Applies the stored selection. Every tool is previewed first, so an unmanaged skill directory
    /// in any target stops the run before the first write.
    @discardableResult
    public func syncGlobalSelection(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let previews = try await previewGlobalSync(home: home)
        let selection = try await globalSelection()
        for tool in selection.tools {
            _ = try await syncGlobal(tool: tool, skillIDs: selection.skillIDs, tags: selection.tags, home: home)
        }
        return previews
    }
}
