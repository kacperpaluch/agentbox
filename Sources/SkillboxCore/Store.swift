import Foundation

public actor SkillboxStore {
    public let root: URL
    public var skillsDirectory: URL { root.appending(path: "skills") }
    private var catalogURL: URL { root.appending(path: "catalog.json") }
    private var localURL: URL { root.appending(path: "projects.local.json") }
    private var mcpURL: URL { root.appending(path: "mcp.json") }
    private var secretsURL: URL { root.appending(path: "mcp-secrets.json") }
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

    public func save(_ catalog: Catalog) throws { try atomicWrite(catalog, to: catalogURL) }
    public func save(_ config: LocalConfiguration) throws { try atomicWrite(config, to: localURL) }
    public func save(_ config: MCPConfiguration) throws { try atomicWrite(config, to: mcpURL) }
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

    private func read<T: Decodable>(_ url: URL, fallback: T) throws -> T {
        guard fm.fileExists(atPath: url.path) else { return fallback }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
