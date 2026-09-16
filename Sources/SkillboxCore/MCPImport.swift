import Foundation

extension SkillboxService {
    public func analyzeMCPJSON(_ text: String, singleServerName: String? = nil) throws -> MCPImportSummary { try parseMCPJSON(text, singleServerName: singleServerName).summary }

    public func importMCPJSON(_ text: String, serverNames: Set<String>? = nil, singleServerName: String? = nil) async throws -> MCPImportSummary {
        let parsed = try parseMCPJSON(text, singleServerName: singleServerName)
        let chosen = serverNames ?? Set(parsed.summary.servers.map(\.name))
        let servers = parsed.summary.servers.filter { chosen.contains($0.name) }
        guard !servers.isEmpty else { throw SkillboxError.invalidSkill("nie wybrano serwerów MCP") }
        if let invalid = servers.first(where: { $0.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil }) { throw SkillboxError.invalidSkill("nazwa MCP \(invalid.name) może zawierać litery, cyfry, _ i -") }
        guard Set(servers.map(\.name)).count == servers.count else { throw SkillboxError.mcpConflict("import zawiera powtórzone nazwy serwerów") }
        var config = try await store.mcpConfiguration()
        // What is reported is what is saved: a reimported server keeps its old id.
        var written: [MCPServer] = []
        for server in servers {
            if let index = config.servers.firstIndex(where: { $0.name == server.name }) {
                let replaced = config.servers[index]
                // The `mcpServers` shape has nowhere to put a tag or an `enabled` flag, so importing
                // an export of the whole configuration used to strip the tags a project assigns by
                // and switch a deliberately disabled server back on. What the format cannot carry is
                // kept from the server being replaced.
                var updated = server
                updated.id = replaced.id
                updated.tags = replaced.tags
                updated.enabled = replaced.enabled
                config.servers[index] = updated
                written.append(updated)
            }
            else { config.servers.append(server); written.append(server) }
        }
        try await store.save(config)
        return MCPImportSummary(servers: written, secretCount: 0, stdioCount: written.filter { $0.transport == .stdio }.count, httpCount: written.filter { $0.transport == .http }.count, fields: parsed.summary.fields.filter { chosen.contains($0.serverName) }, isSingleServerInput: parsed.summary.isSingleServerInput)
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
        // With an empty secrets map a value stored in the legacy `mcp-secrets.json` was rendered as
        // `""`, and saving that JSON back replaced a working configuration with a blank token.
        let data = try JSONSerialization.data(withJSONObject: Self.fullEntry(server, secrets: try await store.secrets()), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The editor's unsaved form as the JSON its other view shows, so switching views carries the
    /// draft along instead of reloading what was last saved.
    public func mcpServerDraftJSON(_ server: MCPServer, fields: [MCPManagedField]) async throws -> String {
        let draft = try Self.applyingFields(fields, to: server)
        let data = try JSONSerialization.data(withJSONObject: Self.fullEntry(draft, secrets: try await store.secrets()), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The other direction: edited JSON back into form values, validated like an import.
    public func mcpServerDraft(fromJSON json: String, name: String) throws -> (server: MCPServer, fields: [MCPManagedField]) {
        guard let value = Self.jsonObject(from: json) else { throw SkillboxError.invalidSkill("konfiguracja serwera nie jest poprawnym JSON") }
        let server = try Self.parseEntry(name: name, value: value).server
        return (server, Self.managedFields(of: server, secrets: [:]))
    }

    /// The whole `mcpServers` configuration as hand-editable JSON — same full-fidelity shape as
    /// `exportMCPServerJSON`, wrapped so it can be pasted back into "Importuj lub użyj AI" as is.
    public func exportMCPConfigurationJSON(_ servers: [MCPServer]) async throws -> String {
        let secrets = try await store.secrets()
        var entries: [String: Any] = [:]
        for server in servers { entries[server.name] = Self.fullEntry(server, secrets: secrets) }
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": entries], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies hand-edited JSON to one existing server, matched by `id` rather than by name so a
    /// rename in the JSON still lands on the right server. The JSON fully replaces command/args/url/
    /// env/headers — whatever it does not mention is gone, same as editing the fields directly. Every
    /// value is reclassified from scratch exactly as `importMCPJSON` does it: `${VAR}` becomes a
    /// reference to a system variable, everything else is stored as a local value in `mcp.json`.
    /// Tags and the enabled flag are passed alongside the JSON because the format cannot hold them.
    public func updateMCPServerJSON(_ id: UUID, name: String, json: String, enabled: Bool, tags: [String]) async throws -> MCPServer {
        guard name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        guard let value = Self.jsonObject(from: json) else { throw SkillboxError.invalidSkill("konfiguracja serwera nie jest poprawnym JSON") }
        var config = try await store.mcpConfiguration()
        guard let index = config.servers.firstIndex(where: { $0.id == id }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        guard !config.servers.contains(where: { $0.id != id && $0.name == name }) else { throw SkillboxError.mcpConflict("serwer \(name) już istnieje") }
        let parsed = try Self.parseEntry(name: name, value: value)
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
        guard let raw = Self.jsonObject(from: text) else { throw SkillboxError.invalidSkill("konfiguracja MCP nie jest poprawnym JSON") }
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
            guard let value = entries[name] as? [String: Any] else {
                // Inside `mcpServers` every value is a server; loose top-level keys may be anything.
                if explicitEntries != nil || isSingleServerInput { throw Self.schemaError("mcpServers.\(name)", "obiekt") }
                continue
            }
            if explicitEntries == nil, !isSingleServerInput, !Self.isServerEntry(value) { continue }
            let parsed = try Self.parseEntry(name: name, value: value)
            servers.append(parsed.server); fields += parsed.fields; secrets.merge(parsed.secrets) { _, new in new }
        }
        return (MCPImportSummary(servers: servers, secretCount: 0, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, fields: fields, isSingleServerInput: isSingleServerInput), secrets)
    }

    /// macOS can replace JSON delimiters with typographic quotes while typing or pasting. Keep a
    /// valid JSON document completely unchanged; only retry a failed parse with those delimiters
    /// normalized. This means typographic quotes inside an otherwise valid string are preserved.
    private static func jsonObject(from text: String) -> [String: Any]? {
        func decode(_ source: String) -> [String: Any]? {
            guard let data = source.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let object = decode(text) { return object }

        let normalized = text
            .replacingOccurrences(of: "\u{201C}", with: "\"") // “
            .replacingOccurrences(of: "\u{201D}", with: "\"") // ”
            .replacingOccurrences(of: "\u{201E}", with: "\"") // „
            .replacingOccurrences(of: "\u{00AB}", with: "\"") // «
            .replacingOccurrences(of: "\u{00BB}", with: "\"") // »
        guard normalized != text else { return nil }
        return decode(normalized)
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
    /// Every field is checked against the shape clients expect before anything is saved. A cast
    /// with a default turned `"args": "--port 3000"` or `"env": ["A"]` into an empty value, and the
    /// import then replaced a working server with one that had lost its settings.
    private static func parseEntry(name: String, value: [String: Any]) throws -> (server: MCPServer, fields: [MCPImportField], secrets: [String: String]) {
        let path = "mcpServers.\(name)"
        let type = try optionalString(value["type"], at: "\(path).type")
        let command = try optionalString(value["command"], at: "\(path).command") ?? ""
        let url = try optionalString(value["url"], at: "\(path).url") ?? ""
        var arguments: [String] = []
        if let raw = value["args"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { throw schemaError("\(path).args", "tablica tekstów") }
            arguments = try list.enumerated().map { index, item in
                guard let text = item as? String else { throw schemaError("\(path).args[\(index)]", "tekst") }
                return text
            }
        }
        let transport: MCPTransport = type == "http" || value["url"] != nil ? .http : .stdio
        if transport == .stdio, command.trimmingCharacters(in: .whitespaces).isEmpty { throw schemaError("\(path).command", "niepusty tekst") }
        if transport == .http, url.trimmingCharacters(in: .whitespaces).isEmpty { throw schemaError("\(path).url", "niepusty tekst") }
        let env = try stringMap(value["env"], at: "\(path).env")
        let headers = try stringMap(value["headers"], at: "\(path).headers")
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
            case .literal: literalHeaders[key] = rawValue
            }
        }
        let server = MCPServer(name: name, transport: transport, command: command, arguments: arguments, url: url, environment: environmentRefs, headers: headerRefs, literalEnvironment: literalEnv.isEmpty ? nil : literalEnv, literalHeaders: literalHeaders.isEmpty ? nil : literalHeaders, secretEnvironment: secretEnv.isEmpty ? nil : secretEnv, secretHeaders: secretHeaders.isEmpty ? nil : secretHeaders)
        return (server, fields, secrets)
    }

    private static func environmentReference(_ value: String) -> String? {
        guard value.hasPrefix("${"), value.hasSuffix("}"), value.count > 3 else { return nil }
        return String(value.dropFirst(2).dropLast())
    }

    private static func stringMap(_ raw: Any?, at path: String) throws -> [String: String] {
        guard let raw, !(raw is NSNull) else { return [:] }
        guard let values = raw as? [String: Any] else { throw schemaError(path, "obiekt z wartościami tekstowymi") }
        var result: [String: String] = [:]
        for (key, item) in values where !(item is NSNull) {
            switch item {
            case let text as String: result[key] = text
            // A number or a flag is a common way to write an environment value; it is kept as the
            // text a client would pass on. `true` used to become "1".
            case let number as NSNumber:
                result[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            default: throw schemaError("\(path).\(key)", "tekst, liczba lub wartość logiczna")
            }
        }
        return result
    }

    private static func optionalString(_ raw: Any?, at path: String) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String else { throw schemaError(path, "tekst") }
        return text
    }

    private static func schemaError(_ path: String, _ expected: String) -> Error {
        SkillboxError.invalidSkill("konfiguracja MCP: \(path) musi być typu: \(expected) — nic nie zapisano")
    }
}
