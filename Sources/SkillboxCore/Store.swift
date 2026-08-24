import Foundation

public actor SkillboxStore {
    public let root: URL
    public var skillsDirectory: URL { root.appending(path: "skills") }
    private var catalogURL: URL { root.appending(path: "catalog.json") }
    private var localURL: URL { root.appending(path: "projects.local.json") }
    private var mcpURL: URL { root.appending(path: "mcp.json") }
    private var secretsURL: URL { root.appending(path: "mcp-secrets.json") }
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
    public func configuration() throws -> LocalConfiguration { try read(localURL, fallback: LocalConfiguration()) }
    public func mcpConfiguration() throws -> MCPConfiguration { try read(mcpURL, fallback: MCPConfiguration()) }

    public func save(_ catalog: Catalog) throws { try snapshotLibrary(); try atomicWrite(catalog, to: catalogURL) }
    public func save(_ config: LocalConfiguration) throws { try snapshotLibrary(); try atomicWrite(config, to: localURL) }
    public func save(_ config: MCPConfiguration) throws { try snapshotLibrary(); try atomicWrite(config, to: mcpURL) }
    public func save(_ config: MCPConfiguration, replacingSecrets secrets: [String: String]) throws {
        let oldMCP = try? Data(contentsOf: mcpURL)
        let oldSecrets = try? Data(contentsOf: secretsURL)
        try snapshotLibrary()
        do {
            try writeSecrets(secrets)
            try atomicWrite(config, to: mcpURL)
        } catch {
            if let oldSecrets { try? oldSecrets.write(to: secretsURL, options: .atomic) } else { try? fm.removeItem(at: secretsURL) }
            if let oldMCP { try? oldMCP.write(to: mcpURL, options: .atomic) } else { try? fm.removeItem(at: mcpURL) }
            throw error
        }
    }
    public func secrets() throws -> [String: String] { try read(secretsURL, fallback: [:]) }
    public func saveSecrets(_ additions: [String: String]) throws {
        var values: [String: String] = try read(secretsURL, fallback: [:])
        values.merge(additions) { _, new in new }
        try writeSecrets(values)
    }
    public func replaceSecrets(_ values: [String: String]) throws { try writeSecrets(values) }
    public func deleteSecrets(accounts: [String]) throws {
        var values: [String: String] = try read(secretsURL, fallback: [:])
        accounts.forEach { values.removeValue(forKey: $0) }
        try writeSecrets(values)
    }
    private func writeSecrets(_ values: [String: String]) throws {
        try atomicWrite(values, to: secretsURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
    }

    public func snapshots() throws -> [LibrarySnapshot] {
        guard fm.fileExists(atPath: snapshotsDirectory.path) else { return [] }
        return try fm.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .compactMap { directory in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .map(\.lastPathComponent).filter { ["catalog.json", "projects.local.json", "mcp.json"].contains($0) }.sorted()
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
        let targets = ["catalog.json": catalogURL, "projects.local.json": localURL, "mcp.json": mcpURL]
        var replacements: [URL: Data] = [:]
        for (filename, target) in targets {
            let source = directory.appending(path: filename)
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            switch filename {
            case "catalog.json": _ = try decoder.decode(Catalog.self, from: data)
            case "projects.local.json": _ = try decoder.decode(LocalConfiguration.self, from: data)
            case "mcp.json": _ = try decoder.decode(MCPConfiguration.self, from: data)
            default: break
            }
            replacements[target] = data
        }
        guard !replacements.isEmpty else { throw SkillboxError.invalidSkill("snapshot nie zawiera danych do przywrócenia") }
        let originals = Dictionary(uniqueKeysWithValues: replacements.keys.compactMap { target in (try? Data(contentsOf: target)).map { (target, $0) } })
        try snapshotLibrary()
        do {
            for (target, data) in replacements { try data.write(to: target, options: .atomic) }
        } catch {
            for (target, data) in originals { try? data.write(to: target, options: .atomic) }
            throw error
        }
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
        try atomicWrite(try configuration(), to: stage.appending(path: "projects.local.json"))
        try atomicWrite(try mcpConfiguration(), to: stage.appending(path: "mcp.json"))
        try atomicWrite(try secrets(), to: stage.appending(path: "mcp-secrets.json"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appending(path: "mcp-secrets.json").path)
        try atomicWrite(FullBackupMetadata(applicationVersion: applicationVersion), to: stage.appending(path: "backup.json"))
        if fm.fileExists(atPath: skillsDirectory.path) { try fm.copyItem(at: skillsDirectory, to: stage.appending(path: "skills")) } else { try fm.createDirectory(at: stage.appending(path: "skills"), withIntermediateDirectories: true) }
        try fm.moveItem(at: stage, to: target)
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
        _ = try decoder.decode([String: String].self, from: Data(contentsOf: package.appending(path: "mcp-secrets.json")))
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: package.appending(path: "skills").path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.invalidSkill("backup nie zawiera katalogu skills") }
        let rollbackRoot = root.appending(path: "backups/restore-rollbacks")
        let rollback = rollbackRoot.appending(path: UUID().uuidString)
        try fm.createDirectory(at: rollback, withIntermediateDirectories: true)
        let names = ["catalog.json", "projects.local.json", "mcp.json", "mcp-secrets.json", "skills"]
        for name in names { let current = root.appending(path: name); if fm.fileExists(atPath: current.path) { try fm.copyItem(at: current, to: rollback.appending(path: name)) } }
        do {
            for name in names {
                let target = root.appending(path: name); let backupItem = package.appending(path: name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: backupItem, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
        } catch {
            for name in names {
                let target = root.appending(path: name); let saved = rollback.appending(path: name)
                try? fm.removeItem(at: target)
                if fm.fileExists(atPath: saved.path) { try? fm.copyItem(at: saved, to: target) }
            }
            throw error
        }
        try pruneFullRestoreBackups(at: rollbackRoot, keeping: 3)
    }

    /// Replaces the Git-backed part of the library with a freshly cloned copy.
    ///
    /// `projects.local.json` and `mcp-secrets.json` are deliberately untouched: they never leave
    /// this Mac, so a restore must not wipe the local project paths or secrets of the machine it
    /// runs on. The clone's `.git` is adopted so later backups push straight back to the remote.
    public func adoptLibrary(from clone: URL) throws {
        let names = ["catalog.json", "mcp.json", "skills", ".gitignore", ".git"]
        var isDirectory: ObjCBool = false
        let hasCatalog = fm.fileExists(atPath: clone.appending(path: "catalog.json").path)
        let hasSkills = fm.fileExists(atPath: clone.appending(path: "skills").path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard hasCatalog || hasSkills else { throw SkillboxError.invalidSkill("repozytorium nie zawiera biblioteki Agentbox (brak catalog.json i katalogu skills)") }
        if hasCatalog { _ = try decoder.decode(Catalog.self, from: Data(contentsOf: clone.appending(path: "catalog.json"))) }
        if fm.fileExists(atPath: clone.appending(path: "mcp.json").path) {
            _ = try decoder.decode(MCPConfiguration.self, from: Data(contentsOf: clone.appending(path: "mcp.json")))
        }
        let rollbackRoot = root.appending(path: "backups/restore-rollbacks")
        let rollback = rollbackRoot.appending(path: UUID().uuidString)
        try fm.createDirectory(at: rollback, withIntermediateDirectories: true)
        for name in names {
            let current = root.appending(path: name)
            if fm.fileExists(atPath: current.path) { try fm.copyItem(at: current, to: rollback.appending(path: name)) }
        }
        do {
            for name in names {
                let target = root.appending(path: name), source = clone.appending(path: name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
            }
            try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        } catch {
            for name in names {
                let target = root.appending(path: name), saved = rollback.appending(path: name)
                try? fm.removeItem(at: target)
                if fm.fileExists(atPath: saved.path) { try? fm.copyItem(at: saved, to: target) }
            }
            throw error
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
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func snapshotLibrary() throws {
        let sources = [catalogURL, localURL, mcpURL].filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let snapshot = snapshotsDirectory.appending(path: name)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for source in sources { try fm.copyItem(at: source, to: snapshot.appending(path: source.lastPathComponent)) }
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
