import CryptoKit
import Foundation

extension SkillboxService {
    public func docsConfiguration() async throws -> DocsConfiguration { try await store.docsConfiguration() }

    @discardableResult
    public func createDoc(id: String, name: String = "", tags: [String] = [], content: String) async throws -> AgentDoc {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        guard id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw SkillboxError.invalidInput("identyfikator dokumentu może zawierać tylko małe litery, cyfry i pojedyncze myślniki: \(id)")
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
            throw SkillboxError.invalidInput("projekt \(project.name) korzysta z ustawień folderu nadrzędnego — przypisz dokumenty do folderu albo nadaj projektowi własne ustawienia")
        }
        let docs = try await store.docsConfiguration().docs
        try Self.requireKnown(docIDs, among: docs.map(\.id), kind: "dokumenty")
        var config = local
        var selection = config.storedSelection(for: .project(projectID))
        selection.docIDs = Self.prunedDocIDs(Array(Set(docIDs)), tags: tags, docs: docs)
        selection.docTags = Self.normalizedTags(tags)
        config.selections[projectID.uuidString] = selection
        try await store.save(config)
    }

    /// An assignment replaces what was there, so a mistyped id must stop it rather than quietly
    /// become "nothing assigned" — the rule `mcp assign` already follows.
    static func requireKnown(_ ids: [String], among known: [String], kind: String) throws {
        let unknown = Set(ids).subtracting(known)
        guard unknown.isEmpty else { throw SkillboxError.invalidInput("nieznane \(kind): \(unknown.sorted().joined(separator: ", ")) — nic nie zmieniono") }
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
        let doc = try Self.resolvedDoc(selection, docs: docsConfig.docs, place: "projektu \(project.name)")
        return try DocsRenderer.preview(project: URL(fileURLWithPath: project.path), doc: doc)
    }

    /// The one document a selection names, through explicit ids and tag matches. `place` completes
    /// "do … pasuje" in the conflict message.
    static func resolvedDoc(_ selection: AttachmentSelection, docs: [AgentDoc], place: String) throws -> AgentDoc? {
        let ids = Set(selection.docIDs)
        let tags = Set(selection.docTags.map { $0.lowercased() })
        let matches = docs.filter { ids.contains($0.id) || !tags.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
        guard matches.count <= 1 else {
            throw SkillboxError.docConflict("do \(place) pasuje więcej niż jeden dokument: \(matches.map(\.id).sorted().joined(separator: ", ")) — AGENTS.md może mieć tylko jedną treść naraz")
        }
        return matches.first
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
    /// `contentDigest` is what Agentbox last wrote as the document itself (`AGENTS.md`, or the one
    /// file of a global target). Optional: manifests written before it existed have none.
    private struct ManifestFile: Codable { var docID: String?; var contentDigest: String? }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestURL(_ project: URL) -> URL { project.appending(path: ".skillbox/docs-manifest.json") }

    /// The managed document, or `nil` when there is no manifest. A manifest that exists but cannot
    /// be read is an error: taken as "nothing managed", it turned Agentbox's own files into
    /// conflicts and was then overwritten instead of reported.
    static func manifestDocID(_ project: URL) throws -> String? { try manifest(project)?.docID }

    private static func manifest(_ project: URL) throws -> ManifestFile? {
        let url = manifestURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url)) } catch {
            throw SkillboxError.docConflict("\(url.path) jest uszkodzony (\(error.localizedDescription)) — popraw lub usuń plik, zanim Agentbox zmieni dokumenty projektu")
        }
    }

    /// In the returned previews, empty `content` means the file should not exist: it is never
    /// created, and an existing managed copy is removed. `doc == nil` with nothing previously
    /// managed instead leaves an unrelated existing file alone — see `renderedFile`.
    static func preview(project: URL, doc: AgentDoc?) throws -> [DocPreview] {
        let stored = try manifest(project)
        let previousID = stored?.docID
        let managed = previousID != nil
        let agents = project.appending(path: "AGENTS.md")
        let claude = project.appending(path: "CLAUDE.md")
        let agentsDesired = doc.map { $0.content.hasSuffix("\n") ? $0.content : $0.content + "\n" }
        let added: [String] = (doc != nil && doc?.id != previousID) ? [doc!.id] : []
        let removed: [String] = (previousID != nil && previousID != doc?.id) ? [previousID!] : []
        let agentsContent = try renderedFile(file: agents, desired: agentsDesired, previouslyManaged: managed, written: stored?.contentDigest)
        let claudeContent = try renderedClaudeImport(file: claude, document: agentsDesired, previouslyManaged: managed)
        return [
            DocPreview(file: agents.path, content: agentsContent ?? "", added: added, removed: removed, leaveAsIs: agentsContent == nil),
            DocPreview(file: claude.path, content: claudeContent ?? "", added: added, removed: removed, leaveAsIs: claudeContent == nil)
        ]
    }

    /// One client's user-level instructions file (`Tool.globalDocURL`), holding the document's full
    /// text and nothing else. Its manifest sits next to it, as a project's sits next to `AGENTS.md`,
    /// so `apply(previews:project:)` takes the file's folder as its `project`.
    static func preview(globalFile file: URL, doc: AgentDoc?) throws -> DocPreview {
        let stored = try manifest(file.deletingLastPathComponent())
        let previousID = stored?.docID
        let desired = doc.map { $0.content.hasSuffix("\n") ? $0.content : $0.content + "\n" }
        let added: [String] = (doc != nil && doc?.id != previousID) ? [doc!.id] : []
        let removed: [String] = (previousID != nil && previousID != doc?.id) ? [previousID!] : []
        let content = try renderedFile(file: file, desired: desired, previouslyManaged: previousID != nil, written: stored?.contentDigest)
        return DocPreview(file: file.path, content: content ?? "", added: added, removed: removed, leaveAsIs: content == nil)
    }

    /// Whether the folder holds an Agentbox document manifest, readable or not.
    static func hasManifest(_ base: URL) -> Bool { FileManager.default.fileExists(atPath: manifestURL(base).path) }

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
    ///
    /// `written` is the digest of what Agentbox last put there. A managed file that holds neither
    /// that nor `desired` was edited in place — agents append to `AGENTS.md` all the time — and
    /// replacing or removing it would throw that work away without a word.
    private static func renderedFile(file: URL, desired: String?, previouslyManaged: Bool, written: String? = nil) throws -> String? {
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
            if exists { try requireOwnable(file); try requireUnedited(file, written: written, desired: nil) }
            return ""
        }
        if exists {
            try requireOwnable(file)
            if !previouslyManaged {
                // An empty file holds nothing to lose: `~/.codex/AGENTS.md` is often left as one.
                let existing = try SkillboxService.existingText(at: file)
                guard existing == desired || existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SkillboxError.docConflict("\(file.lastPathComponent) istnieje w \(file.deletingLastPathComponent().path) i nie jest zarządzany przez Agentbox")
                }
            } else { try requireUnedited(file, written: written, desired: desired) }
        }
        return desired
    }

    /// Without a recorded digest (a manifest older than this check) there is nothing to compare
    /// with, and the file is replaced as it always was; the next write records one.
    private static func requireUnedited(_ file: URL, written: String?, desired: String?) throws {
        guard let written else { return }
        let existing = try SkillboxService.existingText(at: file)
        guard existing != desired, digest(existing) != written else { return }
        throw SkillboxError.docConflict("\(file.path) został zmieniony od ostatniej synchronizacji — przenieś zmiany do dokumentu w bibliotece (plik o treści identycznej z dokumentem nie blokuje) albo usuń plik, a Agentbox zapisze go ponownie")
    }

    static let claudeImport = "@AGENTS.md\n"
    /// The block Agentbox appends to a `CLAUDE.md` the user wrote. Claude Code strips HTML comments
    /// before loading the file, so the marker costs no context.
    static let claudeImportBlock = "<!-- Agentbox: import dokumentu projektu -->\n@AGENTS.md\n"

    /// `CLAUDE.md` exists only to make Claude Code read `AGENTS.md`: it reads `AGENTS.md` on its own
    /// only while no `CLAUDE.md` exists, so a project with one of its own needs the import in it.
    ///
    /// Blocking the whole synchronization over a `CLAUDE.md` the user wrote — what this used to do —
    /// left the project without its skills and servers too, and simply not writing it would have
    /// left `AGENTS.md` unread. So a user's file gets a marked import block appended and keeps every
    /// other byte; a file that already imports `AGENTS.md` is left as it is. A file that holds only
    /// the document's own text (with or without that block) becomes the plain import instead: that
    /// is what moving a `CLAUDE.md` into the library leaves behind, and appending to it made Claude
    /// Code read the same text twice. When the document goes away, only what Agentbox wrote goes
    /// with it: the whole file if it is exactly the generated import, just the block otherwise.
    /// Returns `nil` for a file to leave alone entirely.
    private static func renderedClaudeImport(file: URL, document: String?, previouslyManaged: Bool) throws -> String? {
        let importing = document != nil
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: file.path) || (try? fm.attributesOfItem(atPath: file.path)) != nil
        guard exists else { return importing ? claudeImport : "" }
        guard importing || previouslyManaged else {
            // Not ours and nothing to add: the unmanaged-file rule `renderedFile` applies.
            guard isRegularFile(file), let existing = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return existing
        }
        try requireOwnable(file)
        let existing = try SkillboxService.existingText(at: file)
        if let document {
            let ownText = existing.replacingOccurrences(of: claudeImportBlock, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ownText == document.trimmingCharacters(in: .whitespacesAndNewlines) { return claudeImport }
            guard !importsAgents(existing) else { return existing }
            let separator = existing.isEmpty ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + claudeImportBlock
        }
        if existing == claudeImport { return "" }
        guard let range = existing.range(of: claudeImportBlock) else { return existing }
        var stripped = existing
        stripped.removeSubrange(range)
        // The blank line that separated the block goes with it.
        while stripped.hasSuffix("\n\n") { stripped.removeLast() }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : stripped
    }

    /// Whether a line of the file already is the `@AGENTS.md` import, written by anyone.
    private static func importsAgents(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "@AGENTS.md" }
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
        defer { if !KeptScratch.contains(backup) { try? fm.removeItem(at: backup) } }
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
                // The document itself is always the first preview; `CLAUDE.md` only imports it.
                let content = previews.first.flatMap { $0.leaveAsIs || $0.content.isEmpty ? nil : $0.content }
                let data = try JSONEncoder().encode(ManifestFile(docID: currentID, contentDigest: content.map(digest)))
                // Also called for a project whose files are already current, so an unchanged
                // manifest is left alone instead of being rewritten on every synchronization.
                if (try? Data(contentsOf: url)) != data {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
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
            if !report.succeeded { KeptScratch.keep(backup) }
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
