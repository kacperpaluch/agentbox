import Foundation

extension SkillboxService {
    public func analyzeMCPJSON(_ text: String) throws -> MCPImportSummary { try parseMCPJSON(text).summary }

    public func importMCPJSON(_ text: String, serverNames: Set<String>? = nil) async throws -> MCPImportSummary {
        let parsed = try parseMCPJSON(text)
        let chosen = serverNames ?? Set(parsed.summary.servers.map(\.name))
        let servers = parsed.summary.servers.filter { chosen.contains($0.name) }
        guard !servers.isEmpty else { throw SkillboxError.invalidSkill("nie wybrano serwerów MCP") }
        if let invalid = servers.first(where: { $0.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil }) { throw SkillboxError.invalidSkill("nazwa MCP \(invalid.name) może zawierać litery, cyfry, _ i -") }
        guard Set(servers.map(\.name)).count == servers.count else { throw SkillboxError.mcpConflict("import zawiera powtórzone nazwy serwerów") }
        let summary = MCPImportSummary(servers: servers, secretCount: servers.reduce(0) { $0 + ($1.secretEnvironment?.count ?? 0) + ($1.secretHeaders?.count ?? 0) }, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, profileGroups: Array(Set(servers.compactMap(\.group))).sorted())
        let prefixes = servers.map { "mcp/\($0.name)/" }
        var config = try await store.mcpConfiguration()
        for server in servers {
            if let index = config.servers.firstIndex(where: { $0.name == server.name }) { var updated = server; updated.id = config.servers[index].id; config.servers[index] = updated }
            else { config.servers.append(server) }
        }
        let oldSecrets = try await store.secrets()
        do {
            try await store.saveSecrets(parsed.secrets.filter { key, _ in prefixes.contains { key.hasPrefix($0) } })
            try await store.save(config)
        } catch {
            try? await store.replaceSecrets(oldSecrets)
            throw error
        }
        return summary
    }

    private func parseMCPJSON(_ text: String) throws -> (summary: MCPImportSummary, secrets: [String: String]) {
        guard let data = text.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.invalidSkill("konfiguracja MCP nie jest poprawnym JSON") }
        let entries = raw["mcpServers"] as? [String: Any] ?? raw
        var servers: [MCPServer] = []; var secretCount = 0; var secrets: [String: String] = [:]
        for name in entries.keys.sorted() {
            guard let value = entries[name] as? [String: Any] else { continue }
            let transport: MCPTransport = (value["type"] as? String) == "http" || value["url"] != nil ? .http : .stdio
            let env = Self.stringMap(value["env"])
            let headers = Self.stringMap(value["headers"])
            var environmentRefs: [String: String] = [:], headerRefs: [String: String] = [:]
            var literalEnv: [String: String] = [:], literalHeaders: [String: String] = [:]
            var secretEnv: [String: String] = [:], secretHeaders: [String: String] = [:]
            for (key, val) in env {
                if let reference = Self.environmentReference(val) { environmentRefs[key] = reference }
                else if Self.looksSecret(key) { let account = "mcp/\(name)/env/\(key)"; secrets[account] = val; secretEnv[key] = account; secretCount += 1 }
                else { literalEnv[key] = val }
            }
            for (key, rawValue) in headers {
                if let reference = Self.environmentReference(rawValue.replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored])) { headerRefs[key] = reference }
                else if Self.looksSecret(key) || Self.looksSecret(rawValue) {
                    let account = "mcp/\(name)/header/\(key)"
                    let secret = key.lowercased() == "authorization" && rawValue.lowercased().hasPrefix("bearer ") ? String(rawValue.dropFirst(7)) : rawValue
                    secrets[account] = secret; secretHeaders[key] = account; secretCount += 1
                } else { literalHeaders[key] = rawValue }
            }
            servers.append(MCPServer(name: name, transport: transport, command: value["command"] as? String ?? "", arguments: value["args"] as? [String] ?? [], url: value["url"] as? String ?? "", environment: environmentRefs, headers: headerRefs, literalEnvironment: literalEnv.isEmpty ? nil : literalEnv, literalHeaders: literalHeaders.isEmpty ? nil : literalHeaders, secretEnvironment: secretEnv.isEmpty ? nil : secretEnv, secretHeaders: secretHeaders.isEmpty ? nil : secretHeaders))
        }
        let grouped = Self.detectProfiles(&servers)
        return (MCPImportSummary(servers: servers, secretCount: secretCount, stdioCount: servers.filter { $0.transport == .stdio }.count, httpCount: servers.filter { $0.transport == .http }.count, profileGroups: grouped), secrets)
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

    private static func detectProfiles(_ servers: inout [MCPServer]) -> [String] {
        var signatures: [String: [Int]] = [:]
        for index in servers.indices where servers[index].transport == .stdio {
            let package = servers[index].arguments.drop(while: { $0.hasPrefix("-") }).first ?? ""
            signatures[servers[index].command + "|" + package, default: []].append(index)
        }
        var groups: [String] = []
        for indices in signatures.values where indices.count > 1 {
            let firstParts = servers[indices[0]].name.split(separator: "-")
            guard let first = firstParts.first.map(String.init), first.count >= 3, indices.allSatisfy({ servers[$0].name.hasPrefix(first) }) else { continue }
            groups.append(first)
            for index in indices {
                let suffix = servers[index].name.replacingOccurrences(of: first + "-", with: "")
                servers[index].group = first
                servers[index].profile = suffix == "mcp" ? "Domyślny" : suffix.capitalized
            }
        }
        return Array(Set(groups)).sorted()
    }
}
