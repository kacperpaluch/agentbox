import Foundation

extension SkillboxService {
    public func mcpConfiguration() async throws -> MCPConfiguration { try await store.mcpConfiguration() }

    public func saveMCPServer(_ server: MCPServer) async throws {
        var config = try await store.mcpConfiguration()
        guard server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        // Project tag assignments are stored lowercased, so server tags must be too — a server
        // tagged "SEO" was silently never matched by a project tag saved as "seo".
        var stored = server
        stored.tags = stored.tags.map(SkillboxService.normalizedTags)
        if let index = config.servers.firstIndex(where: { $0.id == stored.id }) {
            guard !config.servers.contains(where: { $0.id != stored.id && $0.name == stored.name }) else { throw SkillboxError.mcpConflict("serwer \(stored.name) już istnieje") }
            config.servers[index] = stored
        }
        else if config.servers.contains(where: { $0.name == stored.name }) { throw SkillboxError.mcpConflict("serwer \(stored.name) już istnieje") }
        else { config.servers.append(stored) }
        try await store.save(config)
    }

    /// Every field with its real value, secrets included in plain text — Agentbox runs locally for
    /// one person, so the editor can just show what is actually stored instead of masking it.
    public func managedFields(serverID: UUID) async throws -> [MCPManagedField] {
        let config = try await store.mcpConfiguration()
        guard let server = config.servers.first(where: { $0.id == serverID }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        let secrets = try await store.secrets()
        var fields: [MCPManagedField] = []
        fields += server.environment.map { MCPManagedField(location: .environment, key: $0.key, value: $0.value, classification: .environment) }
        fields += (server.literalEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, value: $0.value, classification: .literal) }
        fields += (server.secretEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, value: secrets[$0.value] ?? "", classification: .secret) }
        fields += server.headers.map { MCPManagedField(location: .header, key: $0.key, value: $0.value, classification: .environment) }
        fields += (server.literalHeaders ?? [:]).map { MCPManagedField(location: .header, key: $0.key, value: $0.value, classification: .literal) }
        fields += (server.secretHeaders ?? [:]).map { MCPManagedField(location: .header, key: $0.key, value: secrets[$0.value] ?? "", classification: .secret) }
        return fields.sorted { $0.location.rawValue == $1.location.rawValue ? $0.key < $1.key : $0.location.rawValue < $1.location.rawValue }
    }

    public func saveMCPServer(_ server: MCPServer, managedFields fields: [MCPManagedField]) async throws {
        var config = try await store.mcpConfiguration()
        let index = config.servers.firstIndex(where: { $0.id == server.id })
        guard server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        guard !config.servers.contains(where: { $0.id != server.id && $0.name == server.name }) else { throw SkillboxError.mcpConflict("serwer \(server.name) już istnieje") }
        let old = index.map { config.servers[$0] } ?? server
        var secrets = try await store.secrets()
        let oldAccounts = Set(Array((old.secretEnvironment ?? [:]).values) + Array((old.secretHeaders ?? [:]).values))
        oldAccounts.forEach { secrets.removeValue(forKey: $0) }
        var updated = server
        updated.tags = updated.tags.map(SkillboxService.normalizedTags)
        updated.environment = [:]; updated.headers = [:]
        updated.literalEnvironment = [:]; updated.literalHeaders = [:]
        updated.secretEnvironment = [:]; updated.secretHeaders = [:]
        var seen = Set<String>()
        for field in fields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw SkillboxError.mcpConflict("nazwa pola MCP nie może być pusta") }
            let identity = "\(field.location.rawValue)|\(key.lowercased())"
            guard seen.insert(identity).inserted else { throw SkillboxError.mcpConflict("pole \(key) występuje więcej niż raz") }
            // Reusing the same account name across saves (instead of minting a fresh one each time)
            // keeps mcp-secrets.json diff-stable when nothing about this field actually changed.
            let oldAccount = field.location == .environment ? old.secretEnvironment?[key] : old.secretHeaders?[key]
            switch field.classification {
            case .environment:
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw SkillboxError.mcpConflict("podaj nazwę zmiennej systemowej dla \(key)") }
                if field.location == .environment { updated.environment[key] = value } else { updated.headers[key] = value }
            case .literal:
                if field.location == .environment { updated.literalEnvironment?[key] = field.value } else { updated.literalHeaders?[key] = field.value }
            case .secret:
                guard !field.value.isEmpty else { throw SkillboxError.mcpConflict("podaj wartość sekretu dla \(key)") }
                let account = oldAccount ?? "mcp/\(server.id.uuidString)/\(field.location.rawValue)/\(key)"
                secrets[account] = field.value
                if field.location == .environment { updated.secretEnvironment?[key] = account } else { updated.secretHeaders?[key] = account }
            }
        }
        if let index { config.servers[index] = updated } else { config.servers.append(updated) }
        try await store.save(config, replacingSecrets: secrets)
    }

    /// Adds tags to several servers at once, merging with whatever each one already has — the MCP
    /// counterpart of `addTags(skillIDs:tags:)` in the Library tab.
    public func addMCPServerTags(serverIDs: [UUID], tags: [String]) async throws {
        var config = try await store.mcpConfiguration()
        let normalized = SkillboxService.normalizedTags(tags)
        var found = Set<UUID>()
        for index in config.servers.indices where serverIDs.contains(config.servers[index].id) {
            config.servers[index].tags = Array(Set((config.servers[index].tags ?? []) + normalized)).sorted()
            found.insert(config.servers[index].id)
        }
        if let missing = serverIDs.first(where: { !found.contains($0) }) { throw SkillboxError.mcpConflict("serwer MCP nie istnieje: \(missing)") }
        try await store.save(config)
    }

    public func deleteMCPServer(id: UUID) async throws {
        var config = try await store.mcpConfiguration()
        if let server = config.servers.first(where: { $0.id == id }) {
            try await store.deleteSecrets(accounts: Array((server.secretEnvironment ?? [:]).values) + Array((server.secretHeaders ?? [:]).values))
        }
        config.servers.removeAll { $0.id == id }
        if var assignments = config.projectServerIDs { for key in assignments.keys { assignments[key]?.removeAll { $0 == id } }; config.projectServerIDs = assignments }
        try await store.save(config)
    }

    public func setMCPServers(projectID: UUID, serverIDs: [UUID], tags: [String]) async throws {
        let local = try await store.configuration()
        if let project = local.projects.first(where: { $0.id == projectID }), local.inheritsRoot(project) {
            throw SkillboxError.invalidSkill("projekt \(project.name) korzysta z ustawień folderu nadrzędnego — przypisz serwery do folderu albo nadaj projektowi własne ustawienia")
        }
        var config = try await store.mcpConfiguration()
        var assignments = config.projectServerIDs ?? [:]
        assignments[projectID.uuidString] = SkillboxService.prunedServerIDs(Array(Set(serverIDs)), tags: tags, servers: config.servers)
        config.projectServerIDs = assignments
        var tagAssignments = config.projectServerTags ?? [:]
        tagAssignments[projectID.uuidString] = SkillboxService.normalizedTags(tags)
        config.projectServerTags = tagAssignments
        try await store.save(config)
    }

    public func previewMCP(projectID: UUID) async throws -> [MCPPreview] {
        let local = try await store.configuration()
        guard let project = local.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        let mcp = try await store.mcpConfiguration()
        // A project following a parent folder reads the folder's MCP selection, so adding a server
        // to the folder reaches every project in it.
        let selectionID = local.mcpSelectionID(for: project).uuidString
        let serverIDs = Set(mcp.projectServerIDs?[selectionID] ?? [])
        // Lowercased on both sides, so tags saved before normalization keep matching.
        let tags = Set((mcp.projectServerTags?[selectionID] ?? []).map { $0.lowercased() })
        var servers = mcp.servers.filter { serverIDs.contains($0.id) || !tags.isDisjoint(with: ($0.tags ?? []).map { $0.lowercased() }) }.filter(\.enabled)
        servers.sort { $0.name < $1.name }
        let secrets = try await store.secrets()
        let projectURL = URL(fileURLWithPath: project.path)
        var previews = try project.tools.map { try MCPRenderer.preview(tool: $0, project: projectURL, servers: servers, secrets: secrets) }
        // Tools unticked in the project still have managed entries until this cleanup lands.
        previews += try SkillboxService.abandonedTools(project: project).map { try MCPRenderer.preview(tool: $0, project: projectURL, servers: [], secrets: secrets) }
        return previews
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

    /// Every tool the project-local MCP manifest still has entries for.
    static func managedTools(_ project: URL) -> Set<Tool> {
        Set(((try? manifest(project)) ?? [:]).filter { !$0.value.isEmpty }.keys.compactMap(Tool.init(rawValue:)))
    }

    /// In the returned preview, empty `content` means the file should not exist: it is never
    /// created, and an existing one is removed. That covers a project with no MCP selection —
    /// which used to get an empty scaffold in every repository — and cleans such scaffolds up.
    static func preview(tool: Tool, project: URL, servers: [MCPServer], secrets: [String: String] = [:]) throws -> MCPPreview {
        let names = servers.map(\.name)
        let previous = try manifest(project)[tool.rawValue] ?? []
        let file: URL
        let content: String
        var stale: (path: String, content: String)?
        switch tool {
        case .claude:
            file = project.appending(path: ".mcp.json")
            content = try renderedJSON(file: file, path: ["mcpServers"], servers: servers, tool: tool, previouslyManaged: Set(previous), secrets: secrets)
        case .codex:
            file = project.appending(path: ".codex/config.toml")
            content = try renderedTOML(file: file, servers: servers, previouslyManaged: Set(previous), secrets: secrets)
        case .opencode:
            let jsonc = project.appending(path: "opencode.jsonc")
            let json = project.appending(path: "opencode.json")
            file = FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : json
            content = try renderedJSON(file: file, path: ["mcp"], servers: servers, tool: tool, previouslyManaged: Set(previous), secrets: secrets)
            // Adding opencode.jsonc later moves the target file. Without this, every entry
            // Agentbox had written to opencode.json would stay there forever, unmanaged.
            if file == jsonc, !previous.isEmpty, FileManager.default.fileExists(atPath: json.path) {
                let cleaned = try jsonMerged(file: json, path: ["mcp"], servers: [], tool: tool, previouslyManaged: Set(previous), secrets: secrets)
                if cleaned != (try? String(contentsOf: json, encoding: .utf8)) { stale = (json.path, cleaned) }
            }
        }
        return MCPPreview(tool: tool, file: file.path, content: content, added: Array(Set(names).subtracting(previous)).sorted(), removed: Array(Set(previous).subtracting(names)).sorted(), staleFile: stale?.path, staleContent: stale?.content)
    }

    /// The full new content of one managed JSON file, or "" when it should not exist.
    ///
    /// With nothing managed now or before, an existing file is the user's alone and is returned
    /// byte for byte — re-serializing a configuration Agentbox does not own would only churn
    /// their diff. The exception is a file holding nothing beyond the empty scaffold: it is
    /// reported as removable, which also cleans up what versions before 0.9.3 left behind.
    private static func renderedJSON(file: URL, path: [String], servers: [MCPServer], tool: Tool, previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        if servers.isEmpty, previouslyManaged.isEmpty {
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            let raw = try String(contentsOf: file, encoding: .utf8)
            // An unparseable file is deliberately left alone here instead of throwing:
            // nothing is managed in it, so there is nothing to protect.
            let cleaned = try? jsonMerged(file: file, path: path, servers: [], tool: tool, previouslyManaged: [], secrets: [:])
            return cleaned == "" ? "" : raw
        }
        return try jsonMerged(file: file, path: path, servers: servers, tool: tool, previouslyManaged: previouslyManaged, secrets: secrets)
    }

    /// The Codex counterpart of `renderedJSON`. A stray managed block that the manifest no longer
    /// knows about is still ours by its markers, so it is stripped rather than kept forever.
    private static func renderedTOML(file: URL, servers: [MCPServer], previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        if servers.isEmpty, previouslyManaged.isEmpty {
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = strippedManagedBlock(raw)
            if stripped.isEmpty { return "" }
            return stripped == raw ? raw : stripped + "\n"
        }
        return try codexMerged(file: file, servers: servers, previouslyManaged: previouslyManaged, secrets: secrets)
    }

    static func apply(previews: [MCPPreview], project: URL) throws {
        let fm = FileManager.default
        // Scratch copies for this write only; removed whether it succeeds or fails.
        let backup = SkillboxService.scratchDirectory()
        defer { try? fm.removeItem(at: backup) }
        var state = try manifest(project)
        var originals: [(file: URL, backup: URL?, existed: Bool)] = []
        try protectGeneratedFiles(project)
        do {
            for preview in previews {
                try writeManaged(preview.content, to: URL(fileURLWithPath: preview.file), backupPrefix: preview.tool.rawValue + "-", backup: backup, originals: &originals)
                if let stalePath = preview.staleFile, let staleContent = preview.staleContent {
                    try writeManaged(staleContent, to: URL(fileURLWithPath: stalePath), backupPrefix: preview.tool.rawValue + "-stale-", backup: backup, originals: &originals)
                }
                let names = Set(state[preview.tool.rawValue] ?? []).subtracting(preview.removed).union(preview.added)
                state[preview.tool.rawValue] = Array(names).sorted()
            }
            // A manifest with nothing managed anywhere is clutter, exactly like the files above;
            // it disappears together with an emptied .skillbox directory.
            state = state.filter { !$0.value.isEmpty }
            let manifestURL = project.appending(path: ".skillbox/mcp-manifest.json")
            if state.isEmpty {
                if fm.fileExists(atPath: manifestURL.path) { try fm.removeItem(at: manifestURL) }
                let directory = manifestURL.deletingLastPathComponent()
                if let leftovers = try? fm.contentsOfDirectory(atPath: directory.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: directory)
                }
            } else {
                try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: manifestURL, options: .atomic)
            }
        } catch {
            for original in originals.reversed() {
                try? fm.removeItem(at: original.file)
                if original.existed, let saved = original.backup { try? fm.copyItem(at: saved, to: original.file) }
            }
            throw error
        }
    }

    /// One managed file for `apply`: backed up first, skipped when already identical, removed when
    /// the content is empty. Skipping identical writes keeps a no-op sync from churning files, and
    /// removal is what retires an empty scaffold instead of leaving it in the repository.
    private static func writeManaged(_ content: String, to file: URL, backupPrefix: String, backup: URL, originals: inout [(file: URL, backup: URL?, existed: Bool)]) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: file.path)
        if existed, (try? String(contentsOf: file, encoding: .utf8)) == content { return }
        if !existed, content.isEmpty { return }
        var backupFile: URL?
        if existed {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            let copy = backup.appending(path: backupPrefix + file.lastPathComponent)
            try fm.copyItem(at: file, to: copy); backupFile = copy
        }
        originals.append((file, backupFile, existed))
        if content.isEmpty {
            try fm.removeItem(at: file)
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = content.data(using: .utf8) else { throw SkillboxError.mcpConflict("nie można zakodować \(file.lastPathComponent)") }
            try data.write(to: file, options: .atomic)
        }
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
        // An emptied entries map takes its key with it, and a file left with nothing at all is
        // reported as "" so the caller removes it instead of writing an empty scaffold.
        if path.count == 1 {
            var entries = current[path[0]] as? [String: Any] ?? [:]
            try mergeJSONEntries(&entries, servers: servers, tool: tool, previouslyManaged: previouslyManaged, secrets: secrets)
            if entries.isEmpty { current.removeValue(forKey: path[0]) } else { current[path[0]] = entries }
            root = current
        } else {
            var parent = current[path[0]] as? [String: Any] ?? [:]
            var entries = parent[path[1]] as? [String: Any] ?? [:]
            try mergeJSONEntries(&entries, servers: servers, tool: tool, previouslyManaged: previouslyManaged, secrets: secrets)
            if entries.isEmpty { parent.removeValue(forKey: path[1]) } else { parent[path[1]] = entries }
            if parent.isEmpty { current.removeValue(forKey: path[0]) } else { current[path[0]] = parent }
            root = current
        }
        guard !root.isEmpty else { return "" }
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

    /// The text with the managed marker block removed; unchanged when there is no block.
    private static func strippedManagedBlock(_ text: String) -> String {
        guard let startRange = text.range(of: start), let endRange = text.range(of: end), startRange.lowerBound < endRange.upperBound else { return text }
        var result = text
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func codexMerged(file: URL, servers: [MCPServer], previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        existing = strippedManagedBlock(existing)
        for server in servers where !previouslyManaged.contains(server.name) && declaresCodexServer(existing, name: server.name) { throw SkillboxError.mcpConflict("\(server.name) istnieje w config.toml poza blokiem Skillbox") }
        // With nothing left to manage the block disappears entirely; a file that held only the
        // block is reported as "" and removed by the caller.
        guard !servers.isEmpty else { return existing.isEmpty ? "" : existing + "\n" }
        var block = [start]
        for server in servers {
            block.append("[mcp_servers.\(tomlKey(server.name))]")
            if server.transport == .stdio {
                block.append("command = \(toml(server.command))")
                if !server.arguments.isEmpty { block.append("args = [\(server.arguments.map(toml).joined(separator: ", "))]") }
                // Codex accepts a bare name to forward a same-named variable, or
                // { name = "...", source = "..." } to read it from a differently named one.
                let entries = server.environment.sorted { $0.key < $1.key }.map { key, source in
                    key == source ? toml(key) : "{ name = \(toml(key)), source = \(toml(source)) }"
                }
                if !entries.isEmpty { block.append("env_vars = [\(entries.joined(separator: ", "))]") }
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

    /// Matches `[mcp_servers.name]` and `[mcp_servers."name"]`, with or without surrounding spaces.
    /// A literal string search missed the quoted form and produced a duplicate table that Codex
    /// then refused to parse.
    private static func declaresCodexServer(_ text: String, name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^[ \t]*\\[[ \t]*mcp_servers[ \t]*\\.[ \t]*(\(escaped)|\"\(escaped)\")[ \t]*\\]"
        return text.range(of: pattern, options: .regularExpression) != nil
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
