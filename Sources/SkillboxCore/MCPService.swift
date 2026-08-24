import Foundation

extension SkillboxService {
    public func mcpConfiguration() async throws -> MCPConfiguration { try await store.mcpConfiguration() }

    public func saveMCPServer(_ server: MCPServer) async throws {
        var config = try await store.mcpConfiguration()
        guard server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        if let index = config.servers.firstIndex(where: { $0.id == server.id }) {
            guard !config.servers.contains(where: { $0.id != server.id && $0.name == server.name }) else { throw SkillboxError.mcpConflict("serwer \(server.name) już istnieje") }
            config.servers[index] = server
        }
        else if config.servers.contains(where: { $0.name == server.name }) { throw SkillboxError.mcpConflict("serwer \(server.name) już istnieje") }
        else { config.servers.append(server) }
        try await store.save(config)
    }

    public func managedFields(serverID: UUID) async throws -> [MCPManagedField] {
        let config = try await store.mcpConfiguration()
        guard let server = config.servers.first(where: { $0.id == serverID }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        var fields: [MCPManagedField] = []
        fields += server.environment.map { MCPManagedField(location: .environment, key: $0.key, value: $0.value, classification: .environment) }
        fields += (server.literalEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, value: $0.value, classification: .literal) }
        fields += (server.secretEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, classification: .secret, hasStoredSecret: true) }
        fields += server.headers.map { MCPManagedField(location: .header, key: $0.key, value: $0.value, classification: .environment) }
        fields += (server.literalHeaders ?? [:]).map { MCPManagedField(location: .header, key: $0.key, value: $0.value, classification: .literal) }
        fields += (server.secretHeaders ?? [:]).map { MCPManagedField(location: .header, key: $0.key, classification: .secret, hasStoredSecret: true) }
        return fields.sorted { $0.location.rawValue == $1.location.rawValue ? $0.key < $1.key : $0.location.rawValue < $1.location.rawValue }
    }

    public func saveMCPServer(_ server: MCPServer, managedFields fields: [MCPManagedField]) async throws {
        var config = try await store.mcpConfiguration()
        let index = config.servers.firstIndex(where: { $0.id == server.id })
        guard server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        guard !config.servers.contains(where: { $0.id != server.id && $0.name == server.name }) else { throw SkillboxError.mcpConflict("serwer \(server.name) już istnieje") }
        let old = index.map { config.servers[$0] } ?? server
        let oldSecrets = try await store.secrets()
        var secrets = oldSecrets
        let oldAccounts = Set(Array((old.secretEnvironment ?? [:]).values) + Array((old.secretHeaders ?? [:]).values))
        oldAccounts.forEach { secrets.removeValue(forKey: $0) }
        var updated = server
        updated.environment = [:]; updated.headers = [:]
        updated.literalEnvironment = [:]; updated.literalHeaders = [:]
        updated.secretEnvironment = [:]; updated.secretHeaders = [:]
        var seen = Set<String>()
        for field in fields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw SkillboxError.mcpConflict("nazwa pola MCP nie może być pusta") }
            let identity = "\(field.location.rawValue)|\(key.lowercased())"
            guard seen.insert(identity).inserted else { throw SkillboxError.mcpConflict("pole \(key) występuje więcej niż raz") }
            let oldAccount = field.location == .environment ? old.secretEnvironment?[key] : old.secretHeaders?[key]
            let oldSecret = oldAccount.flatMap { oldSecrets[$0] }
            switch field.classification {
            case .environment:
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw SkillboxError.mcpConflict("podaj nazwę zmiennej systemowej dla \(key)") }
                if field.location == .environment { updated.environment[key] = value } else { updated.headers[key] = value }
            case .literal:
                let value = field.value.isEmpty && field.hasStoredSecret ? oldSecret ?? "" : field.value
                if field.location == .environment { updated.literalEnvironment?[key] = value } else { updated.literalHeaders?[key] = value }
            case .secret:
                let account = oldAccount ?? "mcp/\(server.id.uuidString)/\(field.location.rawValue)/\(key)"
                let value = field.value.isEmpty && field.hasStoredSecret ? oldSecret : field.value
                guard let value, !value.isEmpty else { throw SkillboxError.mcpConflict("podaj wartość sekretu dla \(key)") }
                secrets[account] = value
                if field.location == .environment { updated.secretEnvironment?[key] = account } else { updated.secretHeaders?[key] = account }
            }
        }
        if let index { config.servers[index] = updated } else { config.servers.append(updated) }
        try await store.save(config, replacingSecrets: secrets)
    }

    public func saveMCPPreset(_ preset: MCPPreset) async throws {
        var config = try await store.mcpConfiguration()
        if let index = config.presets.firstIndex(where: { $0.id == preset.id }) { config.presets[index] = preset }
        else { config.presets.append(preset) }
        try await store.save(config)
    }

    public func deleteMCPServer(id: UUID) async throws {
        var config = try await store.mcpConfiguration()
        if let server = config.servers.first(where: { $0.id == id }) {
            try await store.deleteSecrets(accounts: Array((server.secretEnvironment ?? [:]).values) + Array((server.secretHeaders ?? [:]).values))
        }
        config.servers.removeAll { $0.id == id }
        for index in config.presets.indices { config.presets[index].serverIDs.removeAll { $0 == id } }
        if var assignments = config.projectServerIDs { for key in assignments.keys { assignments[key]?.removeAll { $0 == id } }; config.projectServerIDs = assignments }
        try await store.save(config)
    }

    public func deleteMCPPreset(id: UUID) async throws {
        var config = try await store.mcpConfiguration()
        config.presets.removeAll { $0.id == id }
        for key in config.projectPresetIDs.keys { config.projectPresetIDs[key]?.removeAll { $0 == id } }
        try await store.save(config)
    }

    public func setMCPPresets(projectID: UUID, presetIDs: [UUID]) async throws {
        var config = try await store.mcpConfiguration()
        config.projectPresetIDs[projectID.uuidString] = presetIDs
        try await store.save(config)
    }

    public func setMCPProfiles(projectID: UUID, selections: [String: UUID]) async throws {
        var config = try await store.mcpConfiguration()
        var all = config.projectProfileSelections ?? [:]
        all[projectID.uuidString] = selections
        config.projectProfileSelections = all
        try await store.save(config)
    }

    public func setMCPServers(projectID: UUID, serverIDs: [UUID], tags: [String]) async throws {
        var config = try await store.mcpConfiguration()
        var assignments = config.projectServerIDs ?? [:]
        assignments[projectID.uuidString] = Array(Set(serverIDs))
        config.projectServerIDs = assignments
        var tagAssignments = config.projectServerTags ?? [:]
        tagAssignments[projectID.uuidString] = Array(Set(tags.map { $0.lowercased() })).sorted()
        config.projectServerTags = tagAssignments
        try await store.save(config)
    }

    public func mcpPresetIDs(projectID: UUID) async throws -> [UUID] {
        try await store.mcpConfiguration().projectPresetIDs[projectID.uuidString] ?? []
    }

    public func previewMCP(projectID: UUID) async throws -> [MCPPreview] {
        let local = try await store.configuration()
        guard let project = local.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        let mcp = try await store.mcpConfiguration()
        let presetIDs = Set(mcp.projectPresetIDs[projectID.uuidString] ?? [])
        var serverIDs = Set(mcp.presets.filter { presetIDs.contains($0.id) }.flatMap(\.serverIDs))
        serverIDs.formUnion(mcp.projectServerIDs?[projectID.uuidString] ?? [])
        let tags = Set(mcp.projectServerTags?[projectID.uuidString] ?? [])
        var servers = mcp.servers.filter { serverIDs.contains($0.id) || !tags.isDisjoint(with: $0.tags ?? []) }.filter(\.enabled)
        servers.sort { $0.name < $1.name }
        let secrets = try await store.secrets()
        return try project.tools.map { try MCPRenderer.preview(tool: $0, project: URL(fileURLWithPath: project.path), servers: servers, secrets: secrets) }
    }

    public func syncMCP(projectID: UUID) async throws -> [MCPPreview] {
        let previews = try await previewMCP(projectID: projectID)
        let local = try await store.configuration()
        guard let project = local.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        try MCPRenderer.apply(previews: previews, project: URL(fileURLWithPath: project.path))
        return previews
    }
}

enum MCPRenderer {
    private static let start = "# >>> skillbox managed MCP >>>"
    private static let end = "# <<< skillbox managed MCP <<<"

    static func preview(tool: Tool, project: URL, servers: [MCPServer], secrets: [String: String] = [:]) throws -> MCPPreview {
        let names = servers.map(\.name)
        let previous = try manifest(project)[tool.rawValue] ?? []
        let file: URL
        let content: String
        switch tool {
        case .claude:
            file = project.appending(path: ".mcp.json")
            content = try jsonMerged(file: file, path: ["mcpServers"], servers: servers, tool: tool, previouslyManaged: Set(previous), secrets: secrets)
        case .codex:
            file = project.appending(path: ".codex/config.toml")
            content = try codexMerged(file: file, servers: servers, previouslyManaged: Set(previous), secrets: secrets)
        case .opencode:
            let jsonc = project.appending(path: "opencode.jsonc")
            file = FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : project.appending(path: "opencode.json")
            content = try jsonMerged(file: file, path: ["mcp"], servers: servers, tool: tool, previouslyManaged: Set(previous), secrets: secrets)
        }
        return MCPPreview(tool: tool, file: file.path, content: content, added: Array(Set(names).subtracting(previous)).sorted(), removed: Array(Set(previous).subtracting(names)).sorted())
    }

    static func apply(previews: [MCPPreview], project: URL) throws {
        let fm = FileManager.default
        let backup = project.appending(path: ".skillbox/mcp-backups/\(UUID().uuidString)")
        var state = try manifest(project)
        var originals: [(file: URL, backup: URL?, existed: Bool)] = []
        try protectGeneratedFiles(project)
        do {
            for preview in previews {
                let file = URL(fileURLWithPath: preview.file)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let existed = fm.fileExists(atPath: file.path)
                var backupFile: URL?
                if existed {
                    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                    let copy = backup.appending(path: preview.tool.rawValue + "-" + file.lastPathComponent)
                    try fm.copyItem(at: file, to: copy); backupFile = copy
                }
                originals.append((file, backupFile, existed))
                guard let data = preview.content.data(using: .utf8) else { throw SkillboxError.mcpConflict("nie można zakodować \(file.lastPathComponent)") }
                try data.write(to: file, options: .atomic)
                let names = Set(state[preview.tool.rawValue] ?? []).subtracting(preview.removed).union(preview.added)
                state[preview.tool.rawValue] = Array(names).sorted()
            }
            let manifestURL = project.appending(path: ".skillbox/mcp-manifest.json")
            try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            for original in originals.reversed() {
                try? fm.removeItem(at: original.file)
                if original.existed, let saved = original.backup { try? fm.copyItem(at: saved, to: original.file) }
            }
            throw error
        }
        try pruneBackups(project, keeping: 10)
    }

    private static func manifest(_ project: URL) throws -> [String: [String]] {
        let url = project.appending(path: ".skillbox/mcp-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
    }

    private static func jsonMerged(file: URL, path: [String], servers: [MCPServer], tool: Tool, previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let parseable = file.pathExtension == "jsonc" ? stripJSONComments(raw) : raw
            guard let data = parseable.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SkillboxError.mcpConflict("\(file.lastPathComponent) nie jest poprawnym JSON/JSONC") }
            root = object
        }
        var current = root
        if path.count == 1 {
            var entries = current[path[0]] as? [String: Any] ?? [:]
            try mergeJSONEntries(&entries, servers: servers, tool: tool, previouslyManaged: previouslyManaged, secrets: secrets)
            current[path[0]] = entries; root = current
        } else {
            var parent = current[path[0]] as? [String: Any] ?? [:]
            var entries = parent[path[1]] as? [String: Any] ?? [:]
            try mergeJSONEntries(&entries, servers: servers, tool: tool, previouslyManaged: previouslyManaged, secrets: secrets)
            parent[path[1]] = entries; current[path[0]] = parent; root = current
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func mergeJSONEntries(_ entries: inout [String: Any], servers: [MCPServer], tool: Tool, previouslyManaged: Set<String>, secrets: [String: String]) throws {
        let desired = Set(servers.map(\.name))
        for old in previouslyManaged.subtracting(desired) { entries.removeValue(forKey: old) }
        for server in servers {
            if entries[server.name] != nil && !previouslyManaged.contains(server.name) { throw SkillboxError.mcpConflict("\(server.name) istnieje i nie jest zarządzany przez Skillbox") }
            entries[server.name] = try jsonServer(server, tool: tool, secrets: secrets)
        }
    }

    private static func jsonServer(_ server: MCPServer, tool: Tool, secrets: [String: String]) throws -> [String: Any] {
        let resolvedEnv = try resolved(server.literalEnvironment, secretRefs: server.secretEnvironment, secrets: secrets, server: server.name)
        let resolvedHeaders = try resolved(server.literalHeaders, secretRefs: server.secretHeaders, secrets: secrets, server: server.name)
        if server.transport == .stdio {
            if tool == .claude {
                var value: [String: Any] = ["command": server.command, "args": server.arguments]
                var env = resolvedEnv; env.merge(server.environment.mapValues { "${\($0)}" }) { _, reference in reference }
                if !env.isEmpty { value["env"] = env }
                return value
            }
            var value: [String: Any] = ["type": "local", "command": [server.command] + server.arguments]
            var env = resolvedEnv; env.merge(server.environment.mapValues { "{env:\($0)}" }) { _, reference in reference }
            if !env.isEmpty { value["environment"] = env }
            return value
        }
        var value: [String: Any] = ["type": tool == .claude ? "http" : "remote", "url": server.url]
        var headers = resolvedHeaders
        headers.merge(Dictionary(uniqueKeysWithValues: server.headers.map { key, env in
                let reference = tool == .claude ? "${\(env)}" : "{env:\(env)}"
                return (key, key.lowercased() == "authorization" ? "Bearer \(reference)" : reference)
            })) { _, reference in reference }
        if let account = server.secretHeaders?["Authorization"], let token = secrets[account] { headers["Authorization"] = "Bearer \(token)" }
        if !headers.isEmpty { value["headers"] = headers }
        return value
    }

    private static func codexMerged(file: URL, servers: [MCPServer], previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let startRange = existing.range(of: start), let endRange = existing.range(of: end), startRange.lowerBound < endRange.upperBound { existing.removeSubrange(startRange.lowerBound..<endRange.upperBound); existing = existing.trimmingCharacters(in: .whitespacesAndNewlines) }
        for server in servers where !previouslyManaged.contains(server.name) && existing.range(of: "[mcp_servers.\(server.name)]", options: .literal) != nil { throw SkillboxError.mcpConflict("\(server.name) istnieje w config.toml poza blokiem Skillbox") }
        var block = [start]
        for server in servers {
            block.append("[mcp_servers.\(tomlKey(server.name))]")
            if server.transport == .stdio {
                if server.environment.contains(where: { $0.key != $0.value }) { throw SkillboxError.mcpConflict("Codex wymaga tej samej nazwy zmiennej po obu stronach, np. TOKEN=TOKEN (serwer: \(server.name))") }
                block.append("command = \(toml(server.command))")
                if !server.arguments.isEmpty { block.append("args = [\(server.arguments.map(toml).joined(separator: ", "))]") }
                let vars = Array(Set(server.environment.values)).sorted(); if !vars.isEmpty { block.append("env_vars = [\(vars.map(toml).joined(separator: ", "))]") }
                let env = try resolved(server.literalEnvironment, secretRefs: server.secretEnvironment, secrets: secrets, server: server.name)
                if !env.isEmpty { block.append("env = { \(env.sorted { $0.key < $1.key }.map { "\(tomlKey($0.key)) = \(toml($0.value))" }.joined(separator: ", ")) }") }
            } else {
                block.append("url = \(toml(server.url))")
                var headers = server.headers
                if let bearer = headers.removeValue(forKey: "Authorization") { block.append("bearer_token_env_var = \(toml(bearer))") }
                if !headers.isEmpty { block.append("env_http_headers = { \(headers.sorted { $0.key < $1.key }.map { "\(tomlKey($0.key)) = \(toml($0.value))" }.joined(separator: ", ")) }") }
                var literal = try resolved(server.literalHeaders, secretRefs: server.secretHeaders, secrets: secrets, server: server.name)
                if let account = server.secretHeaders?["Authorization"], let token = secrets[account] { literal["Authorization"] = "Bearer \(token)" }
                if !literal.isEmpty { block.append("http_headers = { \(literal.sorted { $0.key < $1.key }.map { "\(tomlKey($0.key)) = \(toml($0.value))" }.joined(separator: ", ")) }") }
            }
            block.append("")
        }
        block.append(end)
        return ([existing, block.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n")) + "\n"
    }

    private static func toml(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func tomlKey(_ value: String) -> String { value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? value : toml(value) }

    private static func resolved(_ literals: [String: String]?, secretRefs: [String: String]?, secrets: [String: String], server: String) throws -> [String: String] {
        var result = literals ?? [:]
        for (key, account) in secretRefs ?? [:] {
            guard let value = secrets[account] else { throw SkillboxError.mcpConflict("brak sekretu \(key) dla serwera \(server)") }
            result[key] = value
        }
        return result
    }

    private static func protectGeneratedFiles(_ project: URL) throws {
        let info = project.appending(path: ".git/info")
        guard FileManager.default.fileExists(atPath: info.path) else { return }
        let url = info.appending(path: "exclude")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let marker = "# Skillbox MCP configs (mogą zawierać lokalne sekrety)"
        let entries = [".mcp.json", ".codex/config.toml", "opencode.json", "opencode.jsonc", ".skillbox/"]
        let present = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = entries.filter { !present.contains($0) }
        guard !missing.isEmpty else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.contains(marker) { text += marker + "\n" }
        text += missing.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func pruneBackups(_ project: URL, keeping limit: Int) throws {
        let root = project.appending(path: ".skillbox/mcp-backups")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for item in sorted.dropFirst(limit) { try FileManager.default.removeItem(at: item) }
    }

    private static func stripJSONComments(_ input: String) -> String {
        let chars = Array(input); var output = ""; var index = 0; var inString = false; var escaped = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                output.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                index += 1; continue
            }
            if char == "\"" { inString = true; output.append(char); index += 1; continue }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                index += 2; while index < chars.count && chars[index] != "\n" { index += 1 }; continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2; while index + 1 < chars.count && !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }; index = min(index + 2, chars.count); continue
            }
            output.append(char); index += 1
        }
        let clean = Array(output); var normalized = ""; index = 0; inString = false; escaped = false
        while index < clean.count {
            let char = clean[index]
            if inString {
                normalized.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                index += 1; continue
            }
            if char == "\"" { inString = true; normalized.append(char); index += 1; continue }
            if char == "," {
                var lookahead = index + 1
                while lookahead < clean.count && clean[lookahead].isWhitespace { lookahead += 1 }
                if lookahead < clean.count && (clean[lookahead] == "}" || clean[lookahead] == "]") { index += 1; continue }
            }
            normalized.append(char); index += 1
        }
        return normalized
    }
}
