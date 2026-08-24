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
    public func secrets() throws -> [String: String] { try read(secretsURL, fallback: [:]) }
    public func saveSecrets(_ additions: [String: String]) throws {
        var values: [String: String] = try read(secretsURL, fallback: [:])
        values.merge(additions) { _, new in new }
        try atomicWrite(values, to: secretsURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
    }
    public func replaceSecrets(_ values: [String: String]) throws {
        try atomicWrite(values, to: secretsURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
    }
    public func deleteSecrets(accounts: [String]) throws {
        var values: [String: String] = try read(secretsURL, fallback: [:])
        accounts.forEach { values.removeValue(forKey: $0) }
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
