import Foundation

extension SkillboxService {
    public func analyzeMCPJSON(_ text: String) throws -> MCPImportSummary { try parseMCPJSON(text).summary }

    public func importMCPJSON(_ text: String, serverNames: Set<String>? = nil, classifications: [String: MCPValueClassification] = [:]) async throws -> MCPImportSummary {
        let parsed = try parseMCPJSON(text, classifications: classifications)
        let chosen = serverNames ?? Set(parsed.summary.servers.map(\.name))
        let servers = parsed.summary.servers.filter { chosen.contains($0.name) }
        guard !servers.isEmpty else { throw SkillboxError.invalidSkill("nie wybrano serwerów MCP") }
        if let invalid = servers.first(where: { $0.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil }) { throw SkillboxError.invalidSkill("nazwa MCP \(invalid.name) może zawierać litery, cyfry, _ i -") }
        guard Set(servers.map(\.name)).count == servers.count else { throw SkillboxError.mcpConflict("import zawiera powtórzone nazwy serwerów") }
        let summary = MCPImportSummary(servers: servers, secretCount: servers.reduce(0) { $0 + ($1.secretEnvironment?.count ?? 0) + ($1.secretHeaders?.count ?? 0) }, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, fields: parsed.summary.fields.filter { chosen.contains($0.serverName) })
        let prefixes = servers.map { "mcp/\($0.name)/" }
        var config = try await store.mcpConfiguration()
        var secrets = try await store.secrets()
        for server in servers {
            if let index = config.servers.firstIndex(where: { $0.name == server.name }) {
                let replaced = config.servers[index]
                // The replaced definition may have used different account names — for example
                // mcp/<uuid>/environment/KEY written by the editor. Drop them, or their plaintext
                // values linger in mcp-secrets.json and in every full backup taken afterwards.
                for account in Array((replaced.secretEnvironment ?? [:]).values) + Array((replaced.secretHeaders ?? [:]).values) {
                    secrets.removeValue(forKey: account)
                }
                var updated = server; updated.id = replaced.id; config.servers[index] = updated
            }
            else { config.servers.append(server) }
        }
        secrets.merge(parsed.secrets.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }) { _, new in new }
        try await store.save(config, replacingSecrets: secrets)
        return summary
    }

    private func parseMCPJSON(_ text: String, classifications: [String: MCPValueClassification] = [:]) throws -> (summary: MCPImportSummary, secrets: [String: String]) {
        guard let data = text.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.invalidSkill("konfiguracja MCP nie jest poprawnym JSON") }
        let entries = raw["mcpServers"] as? [String: Any] ?? raw
        var servers: [MCPServer] = []; var secretCount = 0; var secrets: [String: String] = [:]; var fields: [MCPImportField] = []
        for name in entries.keys.sorted() {
            guard let value = entries[name] as? [String: Any] else { continue }
            let transport: MCPTransport = (value["type"] as? String) == "http" || value["url"] != nil ? .http : .stdio
            let env = Self.stringMap(value["env"])
            let headers = Self.stringMap(value["headers"])
            var environmentRefs: [String: String] = [:], headerRefs: [String: String] = [:]
            var literalEnv: [String: String] = [:], literalHeaders: [String: String] = [:]
            var secretEnv: [String: String] = [:], secretHeaders: [String: String] = [:]
            for (key, val) in env.sorted(by: { $0.key < $1.key }) {
                let detected: MCPValueClassification = Self.environmentReference(val) != nil ? .environment : (Self.looksSecret(key) ? .secret : .literal)
                let field = MCPImportField(serverName: name, location: .environment, key: key, displayValue: detected == .secret ? "••••••••" : val, classification: classifications[MCPImportField.fieldID(serverName: name, location: .environment, key: key)] ?? detected)
                fields.append(field)
                switch field.classification {
                case .environment: environmentRefs[key] = Self.environmentReference(val) ?? key
                case .secret:
                    let account = "mcp/\(name)/env/\(key)"; secrets[account] = val; secretEnv[key] = account; secretCount += 1
                case .literal: literalEnv[key] = val
                }
            }
            for (key, rawValue) in headers.sorted(by: { $0.key < $1.key }) {
                let withoutBearer = rawValue.replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
                let detected: MCPValueClassification = Self.environmentReference(withoutBearer) != nil ? .environment : ((Self.looksSecret(key) || Self.looksSecret(rawValue)) ? .secret : .literal)
                let field = MCPImportField(serverName: name, location: .header, key: key, displayValue: detected == .secret ? "••••••••" : rawValue, classification: classifications[MCPImportField.fieldID(serverName: name, location: .header, key: key)] ?? detected)
                fields.append(field)
                switch field.classification {
                case .environment: headerRefs[key] = Self.environmentReference(withoutBearer) ?? key
                case .secret:
                    let account = "mcp/\(name)/header/\(key)"
                    let secret = key.lowercased() == "authorization" && rawValue.lowercased().hasPrefix("bearer ") ? String(rawValue.dropFirst(7)) : rawValue
                    secrets[account] = secret; secretHeaders[key] = account; secretCount += 1
                case .literal: literalHeaders[key] = rawValue
                }
            }
            servers.append(MCPServer(name: name, transport: transport, command: value["command"] as? String ?? "", arguments: value["args"] as? [String] ?? [], url: value["url"] as? String ?? "", environment: environmentRefs, headers: headerRefs, literalEnvironment: literalEnv.isEmpty ? nil : literalEnv, literalHeaders: literalHeaders.isEmpty ? nil : literalHeaders, secretEnvironment: secretEnv.isEmpty ? nil : secretEnv, secretHeaders: secretHeaders.isEmpty ? nil : secretHeaders))
        }
        return (MCPImportSummary(servers: servers, secretCount: secretCount, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, fields: fields), secrets)
    }

    private static func looksSecret(_ value: String) -> Bool {
        let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["password", "token", "api_key", "apikey", "cookie", "secret", "authorization", "bearer"].contains { normalized.contains($0) }
    }

    private static func environmentReference(_ value: String) -> String? {
        guard value.hasPrefix("${"), value.hasSuffix("}"), value.count > 3 else { return nil }
        return String(value.dropFirst(2).dropLast())
    }

    private static func stringMap(_ raw: Any?) -> [String: String] {
        guard let values = raw as? [String: Any] else { return [:] }
        return values.reduce(into: [:]) { result, item in if !(item.value is NSNull) { result[item.key] = String(describing: item.value) } }
    }
}
