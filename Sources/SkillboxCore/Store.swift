import Foundation

public actor SkillboxStore {
    public let root: URL
    public var skillsDirectory: URL { root.appending(path: "skills") }
    private var catalogURL: URL { root.appending(path: "catalog.json") }
    private var localURL: URL { root.appending(path: "projects.local.json") }
    nonisolated private var mcpURL: URL { root.appending(path: "mcp.json") }
    nonisolated private var docsURL: URL { root.appending(path: "docs.json") }
    nonisolated private var selectionsURL: URL { root.appending(path: "selections.json") }
    nonisolated private var secretsURL: URL { root.appending(path: "mcp-secrets.json") }
    private var snapshotsDirectory: URL { root.appending(path: ".agentbox-snapshots") }
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Skillbox")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: self.root.appending(path: "skills"), withIntermediateDirectories: true)
    }

    public func catalog() throws -> Catalog { try read(catalogURL, fallback: Catalog()) }
    /// `projects.local.json` and `selections.json` are read as one value.
    ///
    /// They are separate files because they answer different questions: the first is this Mac's own
    /// record — where each project lives on disk — while the second says only what is attached
    /// where, in bare ids that mean nothing outside the library. Nothing above this line has any
    /// reason to know they are two files; every `save` overload writes both together.
    public func configuration() throws -> LocalConfiguration {
        var config: LocalConfiguration = try read(localURL, fallback: LocalConfiguration())
        config.selections = try read(selectionsURL, fallback: SelectionsConfiguration()).selections
        config.selections = try Self.withLegacyAttachments(config.selections, local: localURL, mcp: mcpURL, docs: docsURL, persisted: selectionsURL, fm: fm)
        return config
    }

    /// Attachments as they were stored before 0.17.0, when every project and folder carried its own
    /// `tools`, `skillIDs`, `tags` and `excludedSkillIDs` inside `projects.local.json`.
    ///
    /// `Project.CodingKeys` deliberately ignores those keys now, so without this a library written
    /// by an older version opened with every project attached to nothing — and the first
    /// synchronization then treated the skills already installed in the user's repositories as
    /// entries to remove. Reading them back is the whole migration: the values are merged only
    /// where `selections.json` has nothing to say, so a half-migrated library is repaired too, and
    /// the first save writes them out in the current shape.
    static func withLegacyAttachments(_ selections: [String: AttachmentSelection], local: URL, mcp: URL, docs: URL, persisted: URL, fm: FileManager) throws -> [String: AttachmentSelection] {
        func object(_ url: URL) throws -> [String: Any]? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            // Refusing to read a broken file is deliberate — proceeding as if it held nothing would
            // tell a pre-0.17 library it has no assignments, which is how skills got deleted from
            // projects in the first place. The message has to name the file, because this is now on
            // the path that lists projects: without it the user sees a raw parser error and no clue
            // which file to restore from `Kopie zapasowe`.
            guard let data = try? Data(contentsOf: url),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw SkillboxError.invalidSkill("nie można odczytać \(url.lastPathComponent) — plik nie jest poprawnym JSON-em. Przywróć go w `Kopie zapasowe`, zanim Agentbox zmieni cokolwiek w projektach")
            }
            return value
        }
        let fields = (try object(persisted)?["selections"] as? [String: [String: Any]]) ?? [:]
        // Missing and deliberately empty are different. Once a field has been saved in the
        // current format, even [] wins over stale legacy data left in another file.
        func missing(_ id: String, _ field: String) -> Bool { fields[id]?[field] == nil }
        var merged = selections
        // Merged field by field, never whole selections: a library half-migrated by an upgrade that
        // only rewrote some of the files must come out complete, not with the first source winning.
        func fill(_ id: String, _ apply: (inout AttachmentSelection) -> Void) {
            var selection = merged[id] ?? AttachmentSelection()
            apply(&selection)
            merged[id] = selection
        }
        if let root = try object(local) {
            for key in ["projects", "projectRoots"] {
                for entry in (root[key] as? [[String: Any]]) ?? [] {
                    guard let id = entry["id"] as? String else { continue }
                    let tools = ((entry["tools"] as? [String]) ?? []).compactMap(Tool.init(rawValue:))
                    let skillIDs = (entry["skillIDs"] as? [String]) ?? []
                    let tags = (entry["tags"] as? [String]) ?? []
                    let excluded = (entry["excludedSkillIDs"] as? [String]) ?? []
                    guard !tools.isEmpty || !skillIDs.isEmpty || !tags.isEmpty || !excluded.isEmpty else { continue }
                    fill(id) { selection in
                        if missing(id, "tools") { selection.tools = tools }
                        if missing(id, "skillIDs") { selection.skillIDs = skillIDs }
                        if missing(id, "skillTags") { selection.skillTags = tags }
                        if missing(id, "excludedSkillIDs") { selection.excludedSkillIDs = excluded }
                    }
                }
            }
            // This Mac's own choice lived on the configuration itself, not on any project.
            let globalTools = ((root["globalTools"] as? [String]) ?? []).compactMap(Tool.init(rawValue:))
            let globalSkills = (root["globalSkillIDs"] as? [String]) ?? []
            let globalTags = (root["globalTags"] as? [String]) ?? []
            if !globalTools.isEmpty || !globalSkills.isEmpty || !globalTags.isEmpty {
                fill(SelectionTarget.global.storageKey) { selection in
                    if missing(SelectionTarget.global.storageKey, "tools") { selection.tools = globalTools }
                    if missing(SelectionTarget.global.storageKey, "skillIDs") { selection.skillIDs = globalSkills }
                    if missing(SelectionTarget.global.storageKey, "skillTags") { selection.skillTags = globalTags }
                }
            }
        }
        // Server and document assignments lived in their own files, keyed by the same selection id.
        if let root = try object(mcp) {
            for (id, values) in (root["projectServerIDs"] as? [String: [String]]) ?? [:] {
                let ids = values.compactMap(UUID.init(uuidString:))
                if !ids.isEmpty { fill(id) { if missing(id, "serverIDs") { $0.serverIDs = ids } } }
            }
            for (id, tags) in (root["projectServerTags"] as? [String: [String]]) ?? [:] where !tags.isEmpty {
                fill(id) { if missing(id, "serverTags") { $0.serverTags = tags } }
            }
        }
        if let root = try object(docs) {
            for (id, values) in (root["projectDocIDs"] as? [String: [String]]) ?? [:] where !values.isEmpty {
                fill(id) { if missing(id, "docIDs") { $0.docIDs = values } }
            }
            for (id, tags) in (root["projectDocTags"] as? [String: [String]]) ?? [:] where !tags.isEmpty {
                fill(id) { if missing(id, "docTags") { $0.docTags = tags } }
            }
        }
        return merged
    }
    public func mcpConfiguration() throws -> MCPConfiguration { try read(mcpURL, fallback: MCPConfiguration()) }
    public func docsConfiguration() throws -> DocsConfiguration { try read(docsURL, fallback: DocsConfiguration()) }

    public func save(_ catalog: Catalog) throws { try snapshotLibrary(); try atomicWrite(catalog, to: catalogURL) }
    public func save(_ config: LocalConfiguration) throws { try snapshotLibrary(); try writeTogether(localWrites(config)) }

    /// The two halves of a `LocalConfiguration`, encoded. Split out so every overload below writes
    /// both files and no caller can accidentally persist the projects without their attachments.
    private func localWrites(_ config: LocalConfiguration) throws -> [(data: Data, url: URL)] {
        var selections = SelectionsConfiguration()
        selections.selections = config.selections
        return [(try encoder.encode(config), localURL), (try encoder.encode(selections), selectionsURL)]
    }
    public func save(_ config: MCPConfiguration) throws { try save(configuration(), config) }
    public func save(_ config: DocsConfiguration) throws { try save(configuration(), config) }

    /// One user action that touches two files takes one snapshot and either applies both writes
    /// or neither. Saving them separately burned two of the ten snapshot slots and could leave the
    /// catalog and the project list disagreeing when the second write failed.
    public func save(_ catalog: Catalog, _ config: LocalConfiguration) throws {
        try snapshotLibrary()
        try writeTogether([(try encoder.encode(catalog), catalogURL)] + (try localWrites(config)))
    }

    public func save(_ config: LocalConfiguration, _ mcp: MCPConfiguration) throws {
        try snapshotLibrary()
        try writeTogether((try localWrites(config)) + [(try encoder.encode(mcp), mcpURL)])
    }

    public func save(_ config: LocalConfiguration, _ docs: DocsConfiguration) throws {
        try snapshotLibrary()
        try writeTogether((try localWrites(config)) + [(try encoder.encode(docs), docsURL)])
    }

    /// Used where one user action touches a project's own record plus both side-table assignments
    /// (MCP servers and docs) — same one-snapshot reasoning as the two-file overloads above.
    public func save(_ config: LocalConfiguration, _ mcp: MCPConfiguration, _ docs: DocsConfiguration) throws {
        try snapshotLibrary()
        try writeTogether((try localWrites(config)) + [(try encoder.encode(mcp), mcpURL), (try encoder.encode(docs), docsURL)])
    }

    private func writeTogether(_ writes: [(data: Data, url: URL)]) throws {
        let rollback = try FileRollback(files: writes.map(\.url))
        try rollback.perform {
            for write in writes {
                try Self.writeData(write.data, to: write.url)
            }
        }
    }
    public func secrets() throws -> [String: String] { try read(secretsURL, fallback: [:]) }
    public func replaceSecrets(_ values: [String: String]) throws { try writeSecrets(values) }
    private func writeSecrets(_ values: [String: String]) throws {
        try Self.writeData(encoder.encode(values), to: secretsURL)
    }

    public func snapshots() throws -> [LibrarySnapshot] {
        guard fm.fileExists(atPath: snapshotsDirectory.path) else { return [] }
        return try fm.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .compactMap { directory in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .map(\.lastPathComponent).filter { ["catalog.json", "projects.local.json", "selections.json", "mcp.json", "docs.json"].contains($0) }.sorted()
                guard !files.isEmpty else { return nil }
                let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return LibrarySnapshot(name: directory.lastPathComponent, date: date, files: files)
            }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    public func restoreSnapshot(named name: String) throws -> [String] {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw SkillboxError.unsafePath(name) }
        let directory = snapshotsDirectory.appending(path: name).standardizedFileURL
        guard directory.deletingLastPathComponent() == snapshotsDirectory.standardizedFileURL else { throw SkillboxError.unsafePath(directory.path) }
        let targets = ["catalog.json": catalogURL, "projects.local.json": localURL, "selections.json": selectionsURL, "mcp.json": mcpURL, "docs.json": docsURL]
        var replacements: [URL: Data] = [:]
        for (filename, target) in targets {
            let source = directory.appending(path: filename)
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            switch filename {
            case "catalog.json": _ = try decoder.decode(Catalog.self, from: data)
            case "projects.local.json": _ = try decoder.decode(LocalConfiguration.self, from: data)
            case "selections.json": _ = try decoder.decode(SelectionsConfiguration.self, from: data)
            case "mcp.json": _ = try decoder.decode(MCPConfiguration.self, from: data)
            case "docs.json": _ = try decoder.decode(DocsConfiguration.self, from: data)
            default: break
            }
            replacements[target] = data
        }
        guard !replacements.isEmpty else { throw SkillboxError.invalidSkill("snapshot nie zawiera danych do przywrócenia") }
        // Written in a fixed order. Dictionary order is arbitrary, so a restore that failed halfway
        // used to leave a different set of files behind on every run — impossible to reason about
        // from a bug report, and impossible to test.
        let ordered = replacements.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
        try snapshotLibrary()
        try writeTogether(ordered.map { (data: $0.value, url: $0.key) })
        return replacements.keys.map(\.lastPathComponent).sorted()
    }

    public func fullBackups() throws -> [FullBackupInfo] {
        let directory = root.appending(path: "backups/full")
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { item in
            guard let metadata = try? decoder.decode(FullBackupMetadata.self, from: Data(contentsOf: item.appending(path: "backup.json"))) else { return nil }
            return FullBackupInfo(name: item.lastPathComponent, createdAt: metadata.createdAt, applicationVersion: metadata.applicationVersion)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult public func createFullBackup(applicationVersion: String) throws -> FullBackupInfo {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let directory = root.appending(path: "backups/full")
        let target = directory.appending(path: name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appending(path: "backups").path)
        let stage = directory.appending(path: ".\(name).tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try atomicWrite(try catalog(), to: stage.appending(path: "catalog.json"))
        // Both halves come from the same, already migrated read. Writing the raw `selections.json`
        // next to a re-encoded `projects.local.json` meant a backup of a pre-0.17 library saved the
        // projects *without* their old attachment fields and *without* the recovered selections —
        // so restoring it produced exactly the empty library the migration exists to prevent.
        let configuration = try configuration()
        var selections = SelectionsConfiguration()
        selections.selections = configuration.selections
        try atomicWrite(configuration, to: stage.appending(path: "projects.local.json"))
        try atomicWrite(selections, to: stage.appending(path: "selections.json"))
        try atomicWrite(try mcpConfiguration(), to: stage.appending(path: "mcp.json"))
        // Since 0.18.0 a local value — including a token — lives in `mcp.json` itself, so its copy
        // in a backup carries the same weight as the legacy secrets file next to it.
        try Self.restrictIfSensitive(stage.appending(path: "mcp.json"), fm: fm)
        try atomicWrite(try docsConfiguration(), to: stage.appending(path: "docs.json"))
        // New MCP entries keep all local values directly in mcp.json. Preserve a legacy secrets
        // file only when it actually still has values, so fresh backups do not create an empty,
        // misleading mcp-secrets.json.
        let legacySecrets = try secrets()
        if !legacySecrets.isEmpty {
            try atomicWrite(legacySecrets, to: stage.appending(path: "mcp-secrets.json"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appending(path: "mcp-secrets.json").path)
        }
        try atomicWrite(FullBackupMetadata(applicationVersion: applicationVersion), to: stage.appending(path: "backup.json"))
        if fm.fileExists(atPath: skillsDirectory.path) { try fm.copyItem(at: skillsDirectory, to: stage.appending(path: "skills")) } else { try fm.createDirectory(at: stage.appending(path: "skills"), withIntermediateDirectories: true) }
        try fm.moveItem(at: stage, to: target)
        // Manual backups used to accumulate forever — the only cleanup was the user remembering to
        // delete old ones by hand. Now that a daily one is created automatically, an unbounded list
        // would just grow silently; capped the same way snapshots and restore rollbacks already are.
        try pruneFullRestoreBackups(at: directory, keeping: 14)
        return FullBackupInfo(name: name, createdAt: .now, applicationVersion: applicationVersion)
    }

    public func restoreFullBackup(named name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw SkillboxError.unsafePath(name) }
        let package = root.appending(path: "backups/full/\(name)").standardizedFileURL
        guard package.deletingLastPathComponent() == root.appending(path: "backups/full").standardizedFileURL else { throw SkillboxError.unsafePath(name) }
        let metadata = try decoder.decode(FullBackupMetadata.self, from: Data(contentsOf: package.appending(path: "backup.json")))
        guard metadata.formatVersion == 1 else { throw SkillboxError.invalidSkill("nieobsługiwana wersja pełnego backupu") }
        _ = try decoder.decode(Catalog.self, from: Data(contentsOf: package.appending(path: "catalog.json")))
        _ = try decoder.decode(LocalConfiguration.self, from: Data(contentsOf: package.appending(path: "projects.local.json")))
        _ = try decoder.decode(MCPConfiguration.self, from: Data(contentsOf: package.appending(path: "mcp.json")))
        let legacySecretsURL = package.appending(path: "mcp-secrets.json")
        let backupHasLegacySecrets = fm.fileExists(atPath: legacySecretsURL.path)
        if backupHasLegacySecrets {
            _ = try decoder.decode([String: String].self, from: Data(contentsOf: legacySecretsURL))
        }
        // Backups made before documents, or before selections moved into their own file, lack those
        // names — that is not corruption, just an older backup, so each is validated only when
        // present instead of failing the whole restore.
        if fm.fileExists(atPath: package.appending(path: "docs.json").path) {
            _ = try decoder.decode(DocsConfiguration.self, from: Data(contentsOf: package.appending(path: "docs.json")))
        }
        if fm.fileExists(atPath: package.appending(path: "selections.json").path) {
            _ = try decoder.decode(SelectionsConfiguration.self, from: Data(contentsOf: package.appending(path: "selections.json")))
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: package.appending(path: "skills").path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.invalidSkill("backup nie zawiera katalogu skills") }
        let rollbackRoot = root.appending(path: "backups/restore-rollbacks")
        let rollback = rollbackRoot.appending(path: UUID().uuidString)
        try fm.createDirectory(at: rollback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appending(path: "backups").path)
        let names = ["catalog.json", "projects.local.json", "selections.json", "mcp.json", "mcp-secrets.json", "docs.json", "skills"]
        for name in names {
            let current = root.appending(path: name), copy = rollback.appending(path: name)
            if fm.fileExists(atPath: current.path) {
                try fm.copyItem(at: current, to: copy)
                try Self.restrictIfSensitive(copy, fm: fm)
            }
        }
        do {
            for name in names {
                let target = root.appending(path: name); let backupItem = package.appending(path: name)
                // "docs.json" and "selections.json" are the names that can legitimately be missing
                // from an older backup.
                guard fm.fileExists(atPath: backupItem.path) else { continue }
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: backupItem, to: target)
            }
            if !backupHasLegacySecrets, fm.fileExists(atPath: secretsURL.path) { try fm.removeItem(at: secretsURL) }
            // Restored copies carry the permissions the backup had, which for a backup taken before
            // 0.24.1 means the defaults. The protection is re-applied from the current rule instead
            // of being inherited from the archive.
            for name in ["mcp.json", "mcp-secrets.json"] { try Self.restrictIfSensitive(root.appending(path: name), fm: fm) }
        } catch {
            var report = RollbackReport()
            for name in names {
                let target = root.appending(path: name), saved = rollback.appending(path: name)
                report.attempt(name) {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: target); try Self.restrictIfSensitive(target, fm: fm) }
                }
            }
            // `restore-rollbacks/` is pruned to three entries, so this copy survives long enough to
            // be useful — and the message says where it is.
            throw report.error(after: error, keeping: report.succeeded ? nil : rollback.path)
        }
        try pruneFullRestoreBackups(at: rollbackRoot, keeping: 3)
    }

    public func deleteFullBackup(named name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw SkillboxError.unsafePath(name) }
        let target = root.appending(path: "backups/full/\(name)").standardizedFileURL
        guard target.deletingLastPathComponent() == root.appending(path: "backups/full").standardizedFileURL else { throw SkillboxError.unsafePath(name) }
        try fm.removeItem(at: target)
    }

    private func pruneFullRestoreBackups(at directory: URL, keeping limit: Int) throws {
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for item in sorted.dropFirst(limit) { try fm.removeItem(at: item) }
    }

    private func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        guard fm.fileExists(atPath: url.path) else { return fallback }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.writeData(encoder.encode(value), to: url)
    }

    private static let sensitiveFiles = ["mcp.json", "mcp-secrets.json"]

    /// Sensitive data is private from the first byte, including when recovery creates a lost file.
    static func writeData(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        guard sensitiveFiles.contains(url.lastPathComponent) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let temporary = url.deletingLastPathComponent().appending(path: ".agentbox-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            throw SkillboxError.commandFailed("nie można zapisać \(url.lastPathComponent)")
        }
    }

    /// Files that can hold a value the user typed as a secret are readable only by their owner.
    ///
    /// Since 0.18.0 an imported token is stored as a literal value in `mcp.json` rather than in the
    /// separate secrets file, which quietly moved secret material into a file created with default
    /// permissions — and into every snapshot copy of it.
    static func restrictIfSensitive(_ url: URL, fm: FileManager) throws {
        guard sensitiveFiles.contains(url.lastPathComponent), fm.fileExists(atPath: url.path) else { return }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func snapshotLibrary() throws {
        // `selections.json` belongs here as much as the rest: since attachments moved out of
        // `projects.local.json` it is the only file saying which skills, servers, documents and
        // plugins a project uses. Leaving it out made every restore a silent half-restore — the
        // catalog came back while the assignments stayed as the mistake had left them.
        let sources = [catalogURL, localURL, selectionsURL, mcpURL, docsURL].filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let snapshot = snapshotsDirectory.appending(path: name)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotsDirectory.path)
        for source in sources {
            let copy = snapshot.appending(path: source.lastPathComponent)
            try fm.copyItem(at: source, to: copy)
            // A snapshot of `mcp.json` is a copy of whatever secrets it holds.
            try Self.restrictIfSensitive(copy, fm: fm)
        }
        try pruneSnapshots(keeping: 10)
    }

    private func pruneSnapshots(keeping limit: Int) throws {
        guard fm.fileExists(atPath: snapshotsDirectory.path) else { return }
        let items = try fm.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for item in sorted.dropFirst(limit) { try fm.removeItem(at: item) }
    }
}
