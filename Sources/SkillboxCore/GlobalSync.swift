import Foundation

/// Skills and the instructions document shared by every session of a tool, written to the
/// per-user skill directory (`Tool.globalSkillsURL`) and instructions file (`Tool.globalDocURL`).
///
/// The Mac itself is just another place attachments land, so it has no selection type of its own —
/// it is `SelectionTarget.global`, read and written like a project or a folder. The choice still
/// lives in `projects.local.json`, because it describes this Mac rather than the library.
///
/// MCP servers are not synchronized globally: `~/.codex/config.toml` and Claude Code's user scope
/// are files Agentbox deliberately never writes (see `ClientServersView`). The server fields of a
/// global selection are therefore ignored here rather than silently half-applied.
extension SkillboxService {
    /// `selection` previews a choice that is not saved yet — the CLI's `--dry-run` and the editor's
    /// unsaved checkboxes. Without it the stored choice is previewed.
    public func previewGlobalSync(selection draft: AttachmentSelection? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [SkillSyncPreview] {
        let chosen = try await globalSelectionForSync(draft)
        // Exclusions are offered in the same editor as the choices, so leaving them out here meant
        // the Mac quietly received a skill its owner had unticked.
        let current = try await selectedSkills(ids: chosen.skillIDs, tags: chosen.skillTags, excluding: chosen.excludedSkillIDs)
        let library = await store.skillsDirectory
        return try (chosen.tools + Self.abandonedGlobalTools(chosen: chosen, among: try await enabledTools(), home: home)).map { tool in
            try Self.skillPreview(tool: tool, target: tool.globalSkillsURL(home: home), current: chosen.tools.contains(tool) ? current : [], library: library)
        }
    }

    /// One entry per client whose user-level instructions file the Mac's document reaches: the
    /// ticked clients when a document is chosen, plus any client still holding a document Agentbox
    /// wrote there before. A client with neither is not read at all.
    public func previewGlobalDocs(selection draft: AttachmentSelection? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [GlobalDocPreview] {
        try await globalDocPlans(draft, home: home).map { plan in
            GlobalDocPreview(tool: plan.tool, file: plan.preview.file, docID: plan.docID, added: plan.preview.added, removed: plan.preview.removed, changed: Self.changes(plan.preview))
        }
    }

    private func globalDocPlans(_ draft: AttachmentSelection?, home: URL) async throws -> [(tool: Tool, preview: DocPreview, docID: String?)] {
        let chosen = try await globalSelectionForSync(draft)
        let doc = try Self.resolvedDoc(chosen, docs: try await store.docsConfiguration().docs, place: "Tego Maca")
        var plans: [(tool: Tool, preview: DocPreview, docID: String?)] = []
        for tool in try await enabledTools() {
            let file = tool.globalDocURL(home: home)
            let wanted = chosen.tools.contains(tool) ? doc : nil
            guard wanted != nil || DocsRenderer.hasManifest(file.deletingLastPathComponent()) else { continue }
            plans.append((tool, try DocsRenderer.preview(globalFile: file, doc: wanted), wanted?.id))
        }
        return plans
    }

    /// Whether writing `preview` would change anything on disk, the manifest included.
    static func changes(_ preview: DocPreview) -> Bool {
        guard !preview.leaveAsIs else { return false }
        if !preview.added.isEmpty || !preview.removed.isEmpty { return true }
        let path = preview.file
        guard FileManager.default.fileExists(atPath: path) else { return !preview.content.isEmpty }
        return preview.content.isEmpty || (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) != preview.content
    }

    /// The global choice limited to the clients this Mac uses, like `resolved(_ project:)` does for
    /// a project. A switched-off client's user directory is left exactly as it is.
    private func globalSelectionForSync(_ draft: AttachmentSelection?) async throws -> AttachmentSelection {
        var chosen: AttachmentSelection
        if let draft { chosen = draft } else { chosen = try await selection(for: .global) }
        let enabled = try await enabledTools()
        chosen.tools = chosen.tools.filter(enabled.contains)
        return chosen
    }

    /// Clients no longer ticked for this Mac whose user directory still holds an Agentbox manifest.
    /// Unticking one used to leave every skill it had received sitting there forever — the project
    /// path has answered this correctly for a long time; the global one never did.
    static func abandonedGlobalTools(chosen: AttachmentSelection, among tools: [Tool], home: URL) -> [Tool] {
        tools.filter { tool in
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
        // Planned before the first write, so a conflicting instructions file stops the skills too.
        let docPlans = try await globalDocPlans(nil, home: home)
        let chosen = try await globalSelectionForSync(nil)
        let abandoned = Self.abandonedGlobalTools(chosen: chosen, among: try await enabledTools(), home: home)
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
        for (offset, plan) in docPlans.enumerated() {
            let file = URL(fileURLWithPath: plan.preview.file)
            let target = file.deletingLastPathComponent()
            var entries: [(name: String, copy: URL?)] = []
            // The file itself and the folder holding its manifest.
            for name in [file.lastPathComponent, ".skillbox"] {
                let item = target.appending(path: name)
                guard (try? fm.attributesOfItem(atPath: item.path)) != nil else { entries.append((name, nil)); continue }
                let copy = scratch.appending(path: "doc-\(offset)/\(name)")
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
            for plan in docPlans {
                try Self.injectedFailure?("global-doc:\(plan.tool.rawValue)")
                try DocsRenderer.apply(previews: [plan.preview], project: URL(fileURLWithPath: plan.preview.file).deletingLastPathComponent())
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
