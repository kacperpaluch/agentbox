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
    /// `selection` previews a choice that is not saved yet — the CLI's `--dry-run` and the editor's
    /// unsaved checkboxes. Without it the stored choice is previewed.
    public func previewGlobalSync(selection draft: AttachmentSelection? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let chosen: AttachmentSelection
        if let draft { chosen = draft } else { chosen = try await selection(for: .global) }
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
    /// in any target stops the run before the first write — and every target is copied aside
    /// first, so a client that refuses the write puts the ones already written back.
    @discardableResult
    public func syncGlobalSelection(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let previews = try await previewGlobalSync(home: home)
        let chosen = try await selection(for: .global)
        let abandoned = Self.abandonedGlobalTools(chosen: chosen, home: home)
        let current = try await selectedSkills(ids: chosen.skillIDs, tags: chosen.skillTags, excluding: chosen.excludedSkillIDs).map(\.id)
        let fm = FileManager.default
        let scratch = Self.scratchDirectory()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? fm.removeItem(at: scratch) } }
        var saved: [(target: URL, existed: Bool, entries: [(name: String, copy: URL?)])] = []
        for (index, tool) in (chosen.tools + abandoned).enumerated() {
            let target = tool.globalSkillsURL(home: home)
            let names = Set(try Self.managedSkillIDs(at: target)).union(current).union([".skillbox.json"])
            var entries: [(name: String, copy: URL?)] = []
            for name in names.sorted() {
                let item = target.appending(path: name)
                guard fm.fileExists(atPath: item.path) else { entries.append((name, nil)); continue }
                let copy = scratch.appending(path: "\(index)/\(name)")
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: copy)
                entries.append((name, copy))
            }
            saved.append((target, fm.fileExists(atPath: target.path), entries))
        }
        do {
            for tool in chosen.tools {
                try Self.injectedFailure?("global:\(tool.rawValue)")
                _ = try await syncGlobal(tool: tool, skillIDs: chosen.skillIDs, tags: chosen.skillTags, excluding: chosen.excludedSkillIDs, home: home)
            }
            for tool in abandoned {
                try Self.injectedFailure?("global:\(tool.rawValue)")
                _ = try await syncGlobal(tool: tool, skillIDs: [], tags: [], home: home)
            }
        } catch {
            var report = RollbackReport()
            for target in saved.reversed() {
                for entry in target.entries {
                    let item = target.target.appending(path: entry.name)
                    report.attempt(item.path) {
                        if (try? fm.attributesOfItem(atPath: item.path)) != nil { try fm.removeItem(at: item) }
                        if let copy = entry.copy {
                            try fm.createDirectory(at: target.target, withIntermediateDirectories: true)
                            try fm.copyItem(at: copy, to: item)
                        }
                    }
                }
                if !target.existed, let leftovers = try? fm.contentsOfDirectory(atPath: target.target.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: target.target)
                }
            }
            keep = !report.succeeded
            throw report.error(after: error, keeping: keep ? scratch.path : nil)
        }
        return previews
    }
}
