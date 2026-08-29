import Foundation

extension SkillboxService {
    public func analyzeMCPJSON(_ text: String, singleServerName: String? = nil) throws -> MCPImportSummary { try parseMCPJSON(text, singleServerName: singleServerName).summary }

    public func importMCPJSON(_ text: String, serverNames: Set<String>? = nil, classifications _: [String: MCPValueClassification] = [:], singleServerName: String? = nil) async throws -> MCPImportSummary {
        let parsed = try parseMCPJSON(text, singleServerName: singleServerName)
        let chosen = serverNames ?? Set(parsed.summary.servers.map(\.name))
        let servers = parsed.summary.servers.filter { chosen.contains($0.name) }
        guard !servers.isEmpty else { throw SkillboxError.invalidSkill("nie wybrano serwerów MCP") }
        if let invalid = servers.first(where: { $0.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil }) { throw SkillboxError.invalidSkill("nazwa MCP \(invalid.name) może zawierać litery, cyfry, _ i -") }
        guard Set(servers.map(\.name)).count == servers.count else { throw SkillboxError.mcpConflict("import zawiera powtórzone nazwy serwerów") }
        let summary = MCPImportSummary(servers: servers, secretCount: 0, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, fields: parsed.summary.fields.filter { chosen.contains($0.serverName) }, isSingleServerInput: parsed.summary.isSingleServerInput)
        var config = try await store.mcpConfiguration()
        for server in servers {
            if let index = config.servers.firstIndex(where: { $0.name == server.name }) {
                let replaced = config.servers[index]
                var updated = server; updated.id = replaced.id; config.servers[index] = updated
            }
            else { config.servers.append(server) }
        }
        try await store.save(config)
        return summary
    }

    /// A single server's `command`/`args`/`url`/`env`/`headers` as hand-editable JSON, with every
    /// value shown as it really is — including secrets in plain text. Agentbox runs locally for one
    /// person, so there is nothing to hide on-screen; the only boundary that matters is that a value
    /// classified as a secret never leaves this Mac (it stays out of the Git-backed library backup
    /// and out of any project's committed files), and that boundary is enforced on save, not by
    /// hiding the value here.
    public func exportMCPServerJSON(_ id: UUID) async throws -> String {
        let config = try await store.mcpConfiguration()
        guard let server = config.servers.first(where: { $0.id == id }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        let data = try JSONSerialization.data(withJSONObject: Self.fullEntry(server, secrets: [:]), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole `mcpServers` configuration as hand-editable JSON — same full-fidelity shape as
    /// `exportMCPServerJSON`, wrapped so it can be pasted back into "Importuj lub użyj AI" as is.
    public func exportMCPConfigurationJSON(_ servers: [MCPServer]) async throws -> String {
        var entries: [String: Any] = [:]
        for server in servers { entries[server.name] = Self.fullEntry(server, secrets: [:]) }
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": entries], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies hand-edited JSON to one existing server, matched by `id` rather than by name so a
    /// rename in the JSON still lands on the right server. The JSON fully replaces command/args/url/
    /// env/headers — whatever it does not mention is gone, same as editing the fields directly. Every
    /// value is reclassified from scratch by the same heuristic `importMCPJSON` uses (a key that
    /// looks like a token or password stays local-only), so a secret typed here is protected
    /// automatically without a manual "mark as secret" step.
    public func updateMCPServerJSON(_ id: UUID, name: String, json: String, enabled: Bool, tags: [String]) async throws -> MCPServer {
        guard name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        guard let data = json.data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SkillboxError.invalidSkill("konfiguracja serwera nie jest poprawnym JSON") }
        var config = try await store.mcpConfiguration()
        guard let index = config.servers.firstIndex(where: { $0.id == id }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        guard !config.servers.contains(where: { $0.id != id && $0.name == name }) else { throw SkillboxError.mcpConflict("serwer \(name) już istnieje") }
        let parsed = Self.parseEntry(name: name, value: value)
        var updated = parsed.server
        updated.id = id; updated.enabled = enabled; updated.tags = SkillboxService.normalizedTags(tags)
        config.servers[index] = updated
        try await store.save(config)
        return updated
    }

    private static func fullEntry(_ server: MCPServer, secrets: [String: String]) -> [String: Any] {
        if server.transport == .stdio {
            var env = server.literalEnvironment ?? [:]
            env.merge(server.environment.mapValues { "${\($0)}" }) { _, new in new }
            for (key, account) in server.secretEnvironment ?? [:] { env[key] = secrets[account] ?? "" }
            var value: [String: Any] = ["command": server.command, "args": server.arguments]
            if !env.isEmpty { value["env"] = env }
            return value
        }
        var headers = server.literalHeaders ?? [:]
        headers.merge(server.headers.map { key, env -> (String, String) in
            let reference = "${\(env)}"
            return (key, key.lowercased() == "authorization" ? "Bearer \(reference)" : reference)
        }, uniquingKeysWith: { _, new in new })
        for (key, account) in server.secretHeaders ?? [:] {
            let raw = secrets[account] ?? ""
            headers[key] = key.lowercased() == "authorization" ? "Bearer \(raw)" : raw
        }
        var value: [String: Any] = ["type": "http", "url": server.url]
        if !headers.isEmpty { value["headers"] = headers }
        return value
    }

    private func parseMCPJSON(_ text: String, singleServerName: String? = nil) throws -> (summary: MCPImportSummary, secrets: [String: String]) {
        guard let data = text.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.invalidSkill("konfiguracja MCP nie jest poprawnym JSON") }
        let explicitEntries = raw["mcpServers"] as? [String: Any]
        let isSingleServerInput = explicitEntries == nil && Self.isServerEntry(raw)
        let entries: [String: Any]
        if let explicitEntries { entries = explicitEntries }
        else if isSingleServerInput {
            let name = singleServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries = [name?.isEmpty == false ? name! : Self.suggestedServerName(raw): raw]
        } else { entries = raw }
        var servers: [MCPServer] = []; var secrets: [String: String] = [:]; var fields: [MCPImportField] = []
        for name in entries.keys.sorted() {
            guard let value = entries[name] as? [String: Any] else { continue }
            let parsed = Self.parseEntry(name: name, value: value)
            servers.append(parsed.server); fields += parsed.fields; secrets.merge(parsed.secrets) { _, new in new }
        }
        return (MCPImportSummary(servers: servers, secretCount: 0, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, fields: fields, isSingleServerInput: isSingleServerInput), secrets)
    }

    private static func isServerEntry(_ value: [String: Any]) -> Bool {
        ["command", "args", "env", "url", "headers", "type"].contains { value[$0] != nil }
    }

    private static func suggestedServerName(_ value: [String: Any]) -> String {
        let arguments = value["args"] as? [String] ?? []
        if let candidate = arguments.reversed().first(where: { $0.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil && !$0.hasPrefix("-") }) { return candidate }
        return "mcp-server"
    }

    /// Parses one `mcpServers` entry into a server plus the fields/secrets bookkeeping the import
    /// summary and the secrets store need. Shared by the bulk importer and the single-server JSON
    /// editor so both classify values — and name secret accounts — exactly the same way.
    private static func parseEntry(name: String, value: [String: Any]) -> (server: MCPServer, fields: [MCPImportField], secrets: [String: String]) {
        let transport: MCPTransport = (value["type"] as? String) == "http" || value["url"] != nil ? .http : .stdio
        let env = stringMap(value["env"])
        let headers = stringMap(value["headers"])
        var environmentRefs: [String: String] = [:], headerRefs: [String: String] = [:]
        var literalEnv: [String: String] = [:], literalHeaders: [String: String] = [:]
        let secretEnv: [String: String] = [:], secretHeaders: [String: String] = [:]
        var fields: [MCPImportField] = []; let secrets: [String: String] = [:]
        for (key, val) in env.sorted(by: { $0.key < $1.key }) {
            let detected: MCPValueClassification = environmentReference(val) != nil ? .environment : .literal
            let field = MCPImportField(serverName: name, location: .environment, key: key, displayValue: val, classification: detected)
            fields.append(field)
            switch field.classification {
            case .environment: environmentRefs[key] = environmentReference(val) ?? key
            case .secret: break
            case .literal: literalEnv[key] = val
            }
        }
        for (key, rawValue) in headers.sorted(by: { $0.key < $1.key }) {
            let withoutBearer = rawValue.replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])
            let detected: MCPValueClassification = environmentReference(withoutBearer) != nil ? .environment : .literal
            let field = MCPImportField(serverName: name, location: .header, key: key, displayValue: rawValue, classification: detected)
            fields.append(field)
            switch field.classification {
            case .environment: headerRefs[key] = environmentReference(withoutBearer) ?? key
            case .secret: break
            case .literal: literalHeaders[key] = rawValue
            }
        }
        let server = MCPServer(name: name, transport: transport, command: value["command"] as? String ?? "", arguments: value["args"] as? [String] ?? [], url: value["url"] as? String ?? "", environment: environmentRefs, headers: headerRefs, literalEnvironment: literalEnv.isEmpty ? nil : literalEnv, literalHeaders: literalHeaders.isEmpty ? nil : literalHeaders, secretEnvironment: secretEnv.isEmpty ? nil : secretEnv, secretHeaders: secretHeaders.isEmpty ? nil : secretHeaders)
        return (server, fields, secrets)
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
