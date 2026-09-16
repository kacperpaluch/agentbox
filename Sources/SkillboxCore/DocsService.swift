import Foundation

extension SkillboxService {
    public func docsConfiguration() async throws -> DocsConfiguration { try await store.docsConfiguration() }

    @discardableResult
    public func createDoc(id: String, name: String = "", tags: [String] = [], content: String) async throws -> AgentDoc {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        guard id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw SkillboxError.invalidSkill("identyfikator dokumentu może zawierać tylko małe litery, cyfry i pojedyncze myślniki: \(id)")
        }
        var config = try await store.docsConfiguration()
        guard !config.docs.contains(where: { $0.id == id }) else { throw SkillboxError.duplicateSkill(id) }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = AgentDoc(id: id, name: displayName.isEmpty ? id : displayName, tags: SkillboxService.normalizedTags(tags), content: content)
        config.docs.append(doc)
        try await store.save(config)
        return doc
    }

    /// Saves edited content back into the library copy and bumps `updatedAt`, so every project that
    /// already has this document immediately reports as outdated — the document counterpart of
    /// `saveSkillMarkdown`.
    public func saveDocContent(docID: String, name: String, content: String) async throws {
        var config = try await store.docsConfiguration()
        guard let index = config.docs.firstIndex(where: { $0.id == docID }) else { throw SkillboxError.docNotFound(docID) }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty { config.docs[index].name = displayName }
        config.docs[index].content = content
        config.docs[index].updatedAt = .now
        try await store.save(config)
    }

    public func setDocTags(docID: String, tags: [String]) async throws {
        var config = try await store.docsConfiguration()
        guard let index = config.docs.firstIndex(where: { $0.id == docID }) else { throw SkillboxError.docNotFound(docID) }
        config.docs[index].tags = SkillboxService.normalizedTags(tags)
        try await store.save(config)
    }

    /// Adds tags to several documents at once, merging with whatever each one already has — the
    /// document counterpart of `addTags(skillIDs:tags:)` and `addMCPServerTags`.
    public func addDocTags(docIDs: [String], tags: [String]) async throws {
        var config = try await store.docsConfiguration()
        let normalized = SkillboxService.normalizedTags(tags)
        var found = Set<String>()
        for index in config.docs.indices where docIDs.contains(config.docs[index].id) {
            config.docs[index].tags = Array(Set(config.docs[index].tags + normalized)).sorted()
            found.insert(config.docs[index].id)
        }
        if let missing = docIDs.first(where: { !found.contains($0) }) { throw SkillboxError.docNotFound(missing) }
        try await store.save(config)
    }

    public func deleteDoc(id: String) async throws {
        var config = try await store.docsConfiguration()
        guard config.docs.contains(where: { $0.id == id }) else { throw SkillboxError.docNotFound(id) }
        config.docs.removeAll { $0.id == id }
        var local = try await store.configuration()
        for key in local.selections.keys { local.selections[key]?.docIDs.removeAll { $0 == id } }
        try await store.save(local, config)
    }

    public func setDocs(projectID: UUID, docIDs: [String], tags: [String]) async throws {
        let local = try await store.configuration()
        if let project = local.projects.first(where: { $0.id == projectID }), local.inheritsRoot(project) {
            throw SkillboxError.invalidSkill("projekt \(project.name) korzysta z ustawień folderu nadrzędnego — przypisz dokumenty do folderu albo nadaj projektowi własne ustawienia")
        }
        var config = local
        var selection = config.storedSelection(for: .project(projectID))
        selection.docIDs = Self.prunedDocIDs(Array(Set(docIDs)), tags: tags, docs: try await store.docsConfiguration().docs)
        selection.docTags = Self.normalizedTags(tags)
        config.selections[projectID.uuidString] = selection
        try await store.save(config)
    }

    static func prunedDocIDs(_ docIDs: [String], tags: [String], docs: [AgentDoc]) -> [String] {
        let tagsByID = Dictionary(docs.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
        return pruneRedundant(docIDs, coveredBy: tags) { tagsByID[$0] ?? [] }
    }

    /// The document assigned to a project, resolved through explicit ids and tag matches exactly
    /// like `previewMCP` resolves servers. More than one match is a conflict instead of an arbitrary
    /// pick — `AGENTS.md` can only ever hold one document's text.
    public func previewDocs(projectID: UUID) async throws -> [DocPreview] {
        let local = try await store.configuration()
        guard let project = local.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        let docsConfig = try await store.docsConfiguration()
        let selection = local.storedSelection(for: .project(local.selectionID(for: project)))
        let ids = Set(selection.docIDs)
        let tags = Set(selection.docTags.map { $0.lowercased() })
        let matches = docsConfig.docs.filter { ids.contains($0.id) || !tags.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
        guard matches.count <= 1 else {
            throw SkillboxError.docConflict("do projektu \(project.name) pasuje więcej niż jeden dokument: \(matches.map(\.id).sorted().joined(separator: ", ")) — AGENTS.md może mieć tylko jedną treść naraz")
        }
        return try DocsRenderer.preview(project: URL(fileURLWithPath: project.path), doc: matches.first)
    }

    /// `previews` is the preview a caller has already computed for this project — see `syncMCP`.
    public func syncDocs(projectID: UUID, previews suppliedPreviews: [DocPreview]? = nil) async throws -> [DocPreview] {
        let previews: [DocPreview]
        if let suppliedPreviews { previews = suppliedPreviews } else { previews = try await previewDocs(projectID: projectID) }
        let local = try await store.configuration()
        guard let project = local.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        try DocsRenderer.apply(previews: previews, project: URL(fileURLWithPath: project.path))
        return previews
    }
}

/// Renders and writes the one document a project has selected as `AGENTS.md`, plus the `CLAUDE.md`
/// that always accompanies it as a generated `@AGENTS.md` import — Claude Code's own documented way
/// to read the same instructions as other agents without duplicating the text. Both files always move
/// together: there is no way to synchronize one without the other.
enum DocsRenderer {
    /// Scratch copies a failed rollback deliberately left behind — see `RollbackReport`.
    nonisolated(unsafe) private static var keptBackups = Set<URL>()
    private struct ManifestFile: Codable { var docID: String? }

    private static func manifestURL(_ project: URL) -> URL { project.appending(path: ".skillbox/docs-manifest.json") }

    /// The managed document, or `nil` when there is no manifest. A manifest that exists but cannot
    /// be read is an error: taken as "nothing managed", it turned Agentbox's own files into
    /// conflicts and was then overwritten instead of reported.
    static func manifestDocID(_ project: URL) throws -> String? {
        let url = manifestURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url)).docID } catch {
            throw SkillboxError.docConflict("\(url.path) jest uszkodzony (\(error.localizedDescription)) — popraw lub usuń plik, zanim Agentbox zmieni dokumenty projektu")
        }
    }

    /// In the returned previews, empty `content` means the file should not exist: it is never
    /// created, and an existing managed copy is removed. `doc == nil` with nothing previously
    /// managed instead leaves an unrelated existing file alone — see `renderedFile`.
    static func preview(project: URL, doc: AgentDoc?) throws -> [DocPreview] {
        let previousID = try manifestDocID(project)
        let managed = previousID != nil
        let agents = project.appending(path: "AGENTS.md")
        let claude = project.appending(path: "CLAUDE.md")
        let agentsDesired = doc.map { $0.content.hasSuffix("\n") ? $0.content : $0.content + "\n" }
        let claudeDesired: String? = doc != nil ? "@AGENTS.md\n" : nil
        let added: [String] = (doc != nil && doc?.id != previousID) ? [doc!.id] : []
        let removed: [String] = (previousID != nil && previousID != doc?.id) ? [previousID!] : []
        let agentsContent = try renderedFile(file: agents, desired: agentsDesired, previouslyManaged: managed)
        let claudeContent = try renderedFile(file: claude, desired: claudeDesired, previouslyManaged: managed)
        return [
            DocPreview(file: agents.path, content: agentsContent ?? "", added: added, removed: removed, leaveAsIs: agentsContent == nil),
            DocPreview(file: claude.path, content: claudeContent ?? "", added: added, removed: removed, leaveAsIs: claudeContent == nil)
        ]
    }

    /// The full new content of one generated file, or "" meaning it should not exist.
    ///
    /// `desired == nil` means this project has no document selected. If Agentbox never managed the
    /// file either, an existing copy is the user's own — returned byte for byte so `apply` treats it
    /// as already up to date instead of deleting something it never wrote. If Agentbox does manage
    /// it, `desired == nil` means the project's selection was cleared and the copy should go away.
    ///
    /// A file that exists, is not yet managed, and holds something other than `desired` blocks the
    /// write — the same rule that already protects unmanaged skills and MCP entries.
    /// Returns `nil` when the file must be left exactly as it is — see `DocPreview.leaveAsIs`.
    private static func renderedFile(file: URL, desired: String?, previouslyManaged: Bool) throws -> String? {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: file.path) || (try? fm.attributesOfItem(atPath: file.path)) != nil
        guard let desired else {
            guard previouslyManaged else {
                guard exists else { return "" }
                // Unreadable as text and not ours: the only honest answer is to keep our hands off
                // it. Reading it as an empty string used to mean "this file should not exist", and
                // the write that followed deleted a document the user had written themselves.
                guard isRegularFile(file), let existing = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return existing
            }
            // The name was ours; whatever stands there now has to be the kind of thing we wrote
            // before it is removed. A directory under that name would go recursively.
            if exists { try requireOwnable(file) }
            return ""
        }
        if exists {
            try requireOwnable(file)
            if !previouslyManaged {
                guard try SkillboxService.existingText(at: file) == desired else {
                    throw SkillboxError.docConflict("\(file.lastPathComponent) istnieje w \(file.deletingLastPathComponent().path) i nie jest zarządzany przez Agentbox")
                }
            }
        }
        return desired
    }

    private static func isRegularFile(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// A plain file Agentbox can read — the only thing it ever writes under these names.
    private static func requireOwnable(_ file: URL) throws {
        guard isRegularFile(file) else {
            throw SkillboxError.docConflict("\(file.path) nie jest zwykłym plikiem — Agentbox go nie zastąpi ani nie usunie")
        }
        _ = try SkillboxService.existingText(at: file)
    }

    static func apply(previews: [DocPreview], project: URL) throws {
        let fm = FileManager.default
        // Scratch copies for this write only; removed whether it succeeds or fails.
        let backup = SkillboxService.scratchDirectory()
        defer { if !keptBackups.contains(backup) { try? fm.removeItem(at: backup) } }
        var currentID = try manifestDocID(project)
        var originals: [(file: URL, backup: URL?, existed: Bool)] = []
        do {
            for preview in previews where !preview.leaveAsIs {
                try writeManaged(preview.content, to: URL(fileURLWithPath: preview.file), backup: backup, originals: &originals)
            }
            if let added = previews.first?.added.first { currentID = added }
            else if let removed = previews.first?.removed.first, removed == currentID { currentID = nil }
            let url = manifestURL(project)
            if let currentID {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(ManifestFile(docID: currentID)).write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                let directory = url.deletingLastPathComponent()
                if let leftovers = try? fm.contentsOfDirectory(atPath: directory.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: directory)
                }
            }
        } catch {
            var report = RollbackReport()
            for original in originals.reversed() {
                report.attempt(original.file.lastPathComponent) {
                    if fm.fileExists(atPath: original.file.path) { try fm.removeItem(at: original.file) }
                    if original.existed, let saved = original.backup { try fm.copyItem(at: saved, to: original.file) }
                }
            }
            if !report.succeeded { keptBackups.insert(backup) }
            throw report.error(after: error, keeping: report.succeeded ? nil : backup.path)
        }
    }

    /// One managed file for `apply`: backed up first, skipped when already identical, removed when
    /// the content is empty — the document counterpart of `MCPRenderer.writeManaged`.
    private static func writeManaged(_ content: String, to file: URL, backup: URL, originals: inout [(file: URL, backup: URL?, existed: Bool)]) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: file.path)
        if existed, (try? String(contentsOf: file, encoding: .utf8)) == content { return }
        if !existed, content.isEmpty { return }
        var backupFile: URL?
        if existed {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            let copy = backup.appending(path: file.lastPathComponent)
            try fm.copyItem(at: file, to: copy); backupFile = copy
        }
        originals.append((file, backupFile, existed))
        if content.isEmpty {
            try fm.removeItem(at: file)
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = content.data(using: .utf8) else { throw SkillboxError.docConflict("nie można zakodować \(file.lastPathComponent)") }
            try data.write(to: file, options: .atomic)
        }
    }
}
