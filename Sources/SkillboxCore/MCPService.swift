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

    /// Creates an independent, byte-for-byte MCP definition under a user-selected name.  This is
    /// deliberately separate from the editor save path: rebuilding a server from form fields can
    /// otherwise omit data that is not currently visible in that form.
    public func duplicateMCPServer(id: UUID, name: String) async throws -> MCPServer {
        var config = try await store.mcpConfiguration()
        guard let source = config.servers.first(where: { $0.id == id }) else {
            throw SkillboxError.mcpConflict("serwer MCP nie istnieje")
        }
        guard name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
            throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -")
        }
        guard !config.servers.contains(where: { $0.name == name }) else {
            throw SkillboxError.mcpConflict("serwer \(name) już istnieje")
        }
        let copy = source.duplicated(name: name)
        config.servers.append(copy)
        try await store.save(config)
        return copy
    }

    /// Every MCP value lives in the local library configuration. `${NAME}` is the only special
    /// form: it forwards a system environment variable instead of storing a literal value.
    ///
    /// Values an older version put in `mcp-secrets.json` are listed here too, resolved to what they
    /// actually are. Without that the editor showed a legacy server with no fields at all, and
    /// saving it — which rebuilds the server from exactly these fields — dropped the reference
    /// along with the header or variable it stood for. Listing them migrates the value into
    /// `mcp.json` on the next save, which is where every value lives now.
    public func managedFields(serverID: UUID) async throws -> [MCPManagedField] {
        let config = try await store.mcpConfiguration()
        guard let server = config.servers.first(where: { $0.id == serverID }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje") }
        let secrets = try await store.secrets()
        var fields: [MCPManagedField] = []
        fields += server.environment.map { MCPManagedField(location: .environment, key: $0.key, value: "${\($0.value)}", classification: .literal) }
        fields += (server.literalEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, value: $0.value, classification: .literal) }
        fields += (server.secretEnvironment ?? [:]).map { MCPManagedField(location: .environment, key: $0.key, value: secrets[$0.value] ?? "", classification: .literal) }
        fields += server.headers.map { MCPManagedField(location: .header, key: $0.key, value: $0.key.lowercased() == "authorization" ? "Bearer ${\($0.value)}" : "${\($0.value)}", classification: .literal) }
        fields += (server.literalHeaders ?? [:]).map { MCPManagedField(location: .header, key: $0.key, value: $0.value, classification: .literal) }
        // `jsonServer` renders a legacy Authorization secret as `Bearer <token>`, so it is shown the
        // same way here — what the editor displays is what the project file will contain.
        fields += (server.secretHeaders ?? [:]).map { key, account in
            let raw = secrets[account] ?? ""
            return MCPManagedField(location: .header, key: key, value: key.lowercased() == "authorization" ? "Bearer \(raw)" : raw, classification: .literal)
        }
        return fields.sorted { $0.location.rawValue == $1.location.rawValue ? $0.key < $1.key : $0.location.rawValue < $1.location.rawValue }
    }

    public func saveMCPServer(_ server: MCPServer, managedFields fields: [MCPManagedField]) async throws {
        var config = try await store.mcpConfiguration()
        let index = config.servers.firstIndex(where: { $0.id == server.id })
        guard server.name.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill("nazwa MCP może zawierać litery, cyfry, _ i -") }
        guard !config.servers.contains(where: { $0.id != server.id && $0.name == server.name }) else { throw SkillboxError.mcpConflict("serwer \(server.name) już istnieje") }
        var updated = server
        updated.tags = updated.tags.map(SkillboxService.normalizedTags)
        updated.environment = [:]; updated.headers = [:]
        updated.literalEnvironment = [:]; updated.literalHeaders = [:]
        updated.secretEnvironment = nil; updated.secretHeaders = nil
        var seen = Set<String>()
        for field in fields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw SkillboxError.mcpConflict("nazwa pola MCP nie może być pusta") }
            let identity = "\(field.location.rawValue)|\(key.lowercased())"
            guard seen.insert(identity).inserted else { throw SkillboxError.mcpConflict("pole \(key) występuje więcej niż raz") }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw SkillboxError.mcpConflict("podaj wartość dla \(key)") }
            let reference = Self.environmentReference(field.location == .header ? value.replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive, .anchored]) : value)
            if let reference {
                if field.location == .environment { updated.environment[key] = reference } else { updated.headers[key] = reference }
            } else if field.location == .environment { updated.literalEnvironment?[key] = field.value }
            else { updated.literalHeaders?[key] = field.value }
        }
        if let index { config.servers[index] = updated } else { config.servers.append(updated) }
        try await store.save(config)
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
        config.servers.removeAll { $0.id == id }
        var local = try await store.configuration()
        for key in local.selections.keys { local.selections[key]?.serverIDs.removeAll { $0 == id } }
        try await store.save(local, config)
    }

    public func setMCPServers(projectID: UUID, serverIDs: [UUID], tags: [String]) async throws {
        let local = try await store.configuration()
        if let project = local.projects.first(where: { $0.id == projectID }), local.inheritsRoot(project) {
            throw SkillboxError.invalidSkill("projekt \(project.name) korzysta z ustawień folderu nadrzędnego — przypisz serwery do folderu albo nadaj projektowi własne ustawienia")
        }
        var config = local
        var selection = config.storedSelection(for: .project(projectID))
        selection.serverIDs = SkillboxService.prunedServerIDs(Array(Set(serverIDs)), tags: tags, servers: try await store.mcpConfiguration().servers)
        selection.serverTags = SkillboxService.normalizedTags(tags)
        config.selections[projectID.uuidString] = selection
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
        let selectionID = local.selectionID(for: project).uuidString
        var servers = Self.assignedServers(selection: local.storedSelection(for: .project(local.selectionID(for: project))), mcp: mcp)
        servers.sort { $0.name < $1.name }
        let disabledGlobal = mcp.projectDisabledGlobalServers?[selectionID] ?? [:]
        let secrets = try await store.secrets()
        let projectURL = URL(fileURLWithPath: project.path)
        var previews = try project.tools.map { tool in
            try MCPRenderer.preview(tool: tool, project: projectURL, servers: servers, secrets: secrets, disabledGlobalNames: disabledGlobal[tool.rawValue] ?? [])
        }
        // Tools unticked in the project still have managed entries until this cleanup lands. They get
        // no servers and no opt-out either: a tool the project no longer uses must end up with its
        // files gone, not with a leftover `enabled = false` nobody can see in the editor any more.
        previews += try SkillboxService.abandonedTools(project: project).map { tool in
            try MCPRenderer.preview(tool: tool, project: projectURL, servers: [], secrets: secrets, disabledGlobalNames: [])
        }
        return previews
    }

    public func syncMCP(projectID: UUID) async throws -> [MCPPreview] {
        let previews = try await previewMCP(projectID: projectID)
        let local = try await store.configuration()
        guard let project = local.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        try MCPRenderer.apply(previews: previews, project: URL(fileURLWithPath: project.path))
        return previews
    }

    /// Servers a project's MCP selection resolves to: direct assignments plus tag matches, minus
    /// anything disabled at the library level. Shared by `previewMCP` and `globalMCPServers`, which
    /// both need to know what is already fully managed for the project before working out what else
    /// applies to it.
    private static func assignedServers(selection: AttachmentSelection, mcp: MCPConfiguration) -> [MCPServer] {
        let serverIDs = Set(selection.serverIDs)
        // Lowercased on both sides, so tags saved before normalization keep matching.
        let tags = Set(selection.serverTags.map { $0.lowercased() })
        return mcp.servers.filter { serverIDs.contains($0.id) || !tags.isDisjoint(with: ($0.tags ?? []).map { $0.lowercased() }) }.filter(\.enabled)
    }

    private static func environmentReference(_ value: String) -> String? {
        guard value.hasPrefix("${"), value.hasSuffix("}"), value.count > 3 else { return nil }
        return String(value.dropFirst(2).dropLast())
    }

    /// MCP servers found declared globally (outside Agentbox) for the tools of one selection — a
    /// project's own, or the parent folder its projects inherit settings from — read-only, straight
    /// from `~/.codex/config.toml` and Claude Code's user scope. A name already assigned directly is
    /// left out: its full Agentbox definition already takes precedence over whatever the global file
    /// declares, so there is nothing to opt out of.
    public func globalMCPServers(selectionID: UUID, tools: [Tool], home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [GlobalMCPServerRef] {
        let mcp = try await store.mcpConfiguration()
        let local = try await store.configuration()
        let assignedNames = Set(Self.assignedServers(selection: local.storedSelection(for: .project(selectionID)), mcp: mcp).map(\.name))
        var refs: [GlobalMCPServerRef] = []
        if tools.contains(.codex) {
            refs += GlobalMCPDiscovery.codexGlobalServerNames(home: home).filter { !assignedNames.contains($0) }.map { GlobalMCPServerRef(tool: .codex, name: $0) }
        }
        if tools.contains(.claude) {
            refs += GlobalMCPDiscovery.claudeGlobalServerNames(home: home).filter { !assignedNames.contains($0) }.map { GlobalMCPServerRef(tool: .claude, name: $0) }
        }
        return refs.sorted { $0.tool.rawValue == $1.tool.rawValue ? $0.name < $1.name : $0.tool.rawValue < $1.tool.rawValue }
    }

    /// The project convenience: resolves which selection actually governs it (its own settings, or
    /// its parent folder's when it inherits them) and its effective tools automatically.
    public func globalMCPServers(projectID: UUID, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> [GlobalMCPServerRef] {
        let local = try await store.configuration()
        guard let project = local.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        return try await globalMCPServers(selectionID: local.selectionID(for: project), tools: project.tools, home: home)
    }

    /// One selection's current opt-outs, keyed by tool — what `setDisabledGlobalServers` last saved.
    public func disabledGlobalServers(selectionID: UUID) async throws -> [Tool: [String]] {
        let mcp = try await store.mcpConfiguration()
        let stored = mcp.projectDisabledGlobalServers?[selectionID.uuidString] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, names in Tool(rawValue: key).map { ($0, names) } })
    }

    public func disabledGlobalServers(projectID: UUID) async throws -> [Tool: [String]] {
        let local = try await store.configuration()
        guard let project = local.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        return try await disabledGlobalServers(selectionID: local.selectionID(for: project))
    }

    /// Replaces, for one tool, the set of globally-declared server names one selection opts out of.
    /// Pass an empty list to re-enable everything (inherit the global definitions again).
    public func setDisabledGlobalServers(selectionID: UUID, tool: Tool, names: [String]) async throws {
        var config = try await store.mcpConfiguration()
        let key = selectionID.uuidString
        var perSelection = config.projectDisabledGlobalServers ?? [:]
        var perTool = perSelection[key] ?? [:]
        let cleaned = Array(Set(names)).sorted()
        if cleaned.isEmpty { perTool.removeValue(forKey: tool.rawValue) } else { perTool[tool.rawValue] = cleaned }
        if perTool.isEmpty { perSelection.removeValue(forKey: key) } else { perSelection[key] = perTool }
        config.projectDisabledGlobalServers = perSelection.isEmpty ? nil : perSelection
        try await store.save(config)
    }

    /// Global servers every newly added project or folder starts out opted out of.
    public func defaultDisabledGlobalServers() async throws -> [Tool: [String]] {
        let stored = try await store.mcpConfiguration().defaultDisabledGlobalServers ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, names in Tool(rawValue: key).map { ($0, names) } })
    }

    /// Replaces that list for one tool. Existing projects are deliberately left alone — this only
    /// decides where the next one starts, which is what makes it safe to change at any time.
    public func setDefaultDisabledGlobalServers(tool: Tool, names: [String]) async throws {
        var config = try await store.mcpConfiguration()
        var defaults = config.defaultDisabledGlobalServers ?? [:]
        let cleaned = Array(Set(names)).sorted()
        if cleaned.isEmpty { defaults.removeValue(forKey: tool.rawValue) } else { defaults[tool.rawValue] = cleaned }
        config.defaultDisabledGlobalServers = defaults.isEmpty ? nil : defaults
        try await store.save(config)
    }

    /// Copies the defaults onto a selection that has just come into existence. A project inheriting a
    /// parent folder is skipped by its caller: the folder's own record already governs it, and a
    /// second one under the project's id would only be a record nothing reads.
    static func applyDefaultDisabledGlobalServers(_ mcp: inout MCPConfiguration, selectionID: UUID) {
        guard let defaults = mcp.defaultDisabledGlobalServers, !defaults.isEmpty else { return }
        var perSelection = mcp.projectDisabledGlobalServers ?? [:]
        perSelection[selectionID.uuidString] = defaults
        mcp.projectDisabledGlobalServers = perSelection
    }

    /// The project convenience: like `setMCPServers`, refuses to edit a project that follows its
    /// parent folder's settings — change them on the folder itself, or give the project its own
    /// settings first.
    public func setDisabledGlobalServers(projectID: UUID, tool: Tool, names: [String]) async throws {
        let local = try await store.configuration()
        if let project = local.projects.first(where: { $0.id == projectID }), local.inheritsRoot(project) {
            let folder = local.root(for: project)?.name ?? "nadrzędnego"
            throw SkillboxError.invalidSkill("projekt \(project.name) dziedziczy ustawienia z folderu \(folder) — użyj `agentbox mcp global <disable|enable> \(folder) … --folder`, żeby zmienić je dla całego folderu, albo nadaj projektowi własne ustawienia w aplikacji")
        }
        guard let project = local.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        try await setDisabledGlobalServers(selectionID: local.selectionID(for: project), tool: tool, names: names)
    }
}

enum MCPRenderer {
    private static let start = "# >>> skillbox managed MCP >>>"
    private static let end = "# <<< skillbox managed MCP <<<"

    /// Every tool the project-local MCP manifest still has entries for — including a tool whose only
    /// remaining entry is a `-disabled-global` opt-out (see `renderedClaudeDisabledGlobal`), so that
    /// stale opt-out alone still counts as "this tool has something to clean up".
    static func managedTools(_ project: URL) -> Set<Tool> {
        let raw = ((try? manifest(project)) ?? [:]).filter { !$0.value.isEmpty }
        return Set(raw.keys.compactMap { key in
            Tool.init(rawValue: key) ?? Tool.init(rawValue: key.replacingOccurrences(of: "-disabled-global", with: ""))
        })
    }

    /// In the returned preview, empty `content` means the file should not exist: it is never
    /// created, and an existing one is removed. That covers a project with no MCP selection —
    /// which used to get an empty scaffold in every repository — and cleans such scaffolds up.
    static func preview(tool: Tool, project: URL, servers: [MCPServer], secrets: [String: String] = [:], disabledGlobalNames: [String] = []) throws -> MCPPreview {
        // Codex's opt-out lives inside the very same `.codex/config.toml` block as everything else,
        // so it is tracked under the tool's regular manifest key, right alongside real servers.
        let names = servers.map(\.name) + (tool == .codex ? disabledGlobalNames : [])
        let previous = try manifest(project)[tool.rawValue] ?? []
        let file: URL
        let content: String
        var stale: (path: String, content: String)?
        var disabledGlobal: (file: URL, content: String, added: [String], removed: [String])?
        switch tool {
        case .claude:
            file = project.appending(path: ".mcp.json")
            content = try renderedJSON(file: file, path: ["mcpServers"], servers: servers, tool: tool, previouslyManaged: Set(previous), secrets: secrets)
            // Claude Code's opt-out lives in a different file (`.claude/settings.local.json`), so it
            // gets its own manifest key and its own added/removed pair.
            let disabledFile = project.appending(path: ".claude/settings.local.json")
            let previousDisabled = try manifest(project)["claude-disabled-global"] ?? []
            let disabledContent = try renderedClaudeDisabledGlobal(file: disabledFile, names: disabledGlobalNames, previouslyManaged: Set(previousDisabled))
            disabledGlobal = (disabledFile, disabledContent, Array(Set(disabledGlobalNames).subtracting(previousDisabled)).sorted(), Array(Set(previousDisabled).subtracting(disabledGlobalNames)).sorted())
        case .codex:
            file = project.appending(path: ".codex/config.toml")
            content = try renderedTOML(file: file, servers: servers, disabledGlobalNames: disabledGlobalNames, previouslyManaged: Set(previous), secrets: secrets)
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
        return MCPPreview(tool: tool, file: file.path, content: content, added: Array(Set(names).subtracting(previous)).sorted(), removed: Array(Set(previous).subtracting(names)).sorted(), staleFile: stale?.path, staleContent: stale?.content, disabledGlobalFile: disabledGlobal?.file.path, disabledGlobalContent: disabledGlobal?.content, disabledGlobalAdded: disabledGlobal?.added ?? [], disabledGlobalRemoved: disabledGlobal?.removed ?? [])
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
    private static func renderedTOML(file: URL, servers: [MCPServer], disabledGlobalNames: [String], previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        if servers.isEmpty, disabledGlobalNames.isEmpty, previouslyManaged.isEmpty {
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = strippedManagedBlock(raw)
            if stripped.isEmpty { return "" }
            return stripped == raw ? raw : stripped + "\n"
        }
        return try codexMerged(file: file, servers: servers, disabledGlobalNames: disabledGlobalNames, previouslyManaged: previouslyManaged, secrets: secrets)
    }

    static func apply(previews: [MCPPreview], project: URL) throws {
        let fm = FileManager.default
        // Scratch copies for this write only; removed whether it succeeds or fails.
        let backup = SkillboxService.scratchDirectory()
        defer { try? fm.removeItem(at: backup) }
        var state = try manifest(project)
        var originals: [(file: URL, backup: URL?, existed: Bool)] = []
        try protectGeneratedFiles(project, previews: previews)
        do {
            for preview in previews {
                try writeManaged(preview.content, to: URL(fileURLWithPath: preview.file), backupPrefix: preview.tool.rawValue + "-", backup: backup, originals: &originals)
                if let stalePath = preview.staleFile, let staleContent = preview.staleContent {
                    try writeManaged(staleContent, to: URL(fileURLWithPath: stalePath), backupPrefix: preview.tool.rawValue + "-stale-", backup: backup, originals: &originals)
                }
                let names = Set(state[preview.tool.rawValue] ?? []).subtracting(preview.removed).union(preview.added)
                state[preview.tool.rawValue] = Array(names).sorted()
                if let disabledPath = preview.disabledGlobalFile, let disabledContent = preview.disabledGlobalContent {
                    try writeManaged(disabledContent, to: URL(fileURLWithPath: disabledPath), backupPrefix: preview.tool.rawValue + "-disabled-global-", backup: backup, originals: &originals)
                    let key = "\(preview.tool.rawValue)-disabled-global"
                    let disabledNames = Set(state[key] ?? []).subtracting(preview.disabledGlobalRemoved).union(preview.disabledGlobalAdded)
                    state[key] = Array(disabledNames).sorted()
                }
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

    private static func codexMerged(file: URL, servers: [MCPServer], disabledGlobalNames: [String], previouslyManaged: Set<String>, secrets: [String: String]) throws -> String {
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        existing = strippedManagedBlock(existing)
        let ownedNames = Set(servers.map(\.name)).union(disabledGlobalNames)
        for name in ownedNames where !previouslyManaged.contains(name) && declaresCodexServer(existing, name: name) { throw SkillboxError.mcpConflict("\(name) istnieje w config.toml poza blokiem Skillbox") }
        // With nothing left to manage the block disappears entirely; a file that held only the
        // block is reported as "" and removed by the caller.
        guard !servers.isEmpty || !disabledGlobalNames.isEmpty else { return existing.isEmpty ? "" : existing + "\n" }
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
        // A name already fully defined above needs no separate opt-out — kept here only as a
        // defensive fallback, since `globalMCPServers` already excludes assigned names upstream.
        let assignedNames = Set(servers.map(\.name))
        for name in disabledGlobalNames.sorted() where !assignedNames.contains(name) {
            // Overrides just `enabled` for this project, without redeclaring command/args — Codex's
            // documented way to opt a project out of a user-scope server (one shared, via
            // ~/.codex/config.toml, with the ChatGPT desktop app and the Codex IDE extension).
            block.append("[mcp_servers.\(tomlKey(name))]")
            block.append("enabled = false")
            block.append("")
        }
        block.append(end)
        return ([existing, block.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n")) + "\n"
    }

    /// Claude Code's per-project opt-out of a user-scope (global) MCP server: appends the server's
    /// name to `disabledMcpServers` in `.claude/settings.local.json` — the file Claude Code already
    /// treats as local, unshared settings. Everything else in the file, and any name Agentbox does
    /// not itself own, is left untouched: the same "don't overwrite what you don't manage" rule as
    /// everywhere else in this file.
    private static func renderedClaudeDisabledGlobal(file: URL, names: [String], previouslyManaged: Set<String>) throws -> String {
        // Nothing managed now or before: the file belongs to the user (and to Claude Code, which
        // writes its own permission decisions there), so it is returned byte for byte instead of
        // being re-serialized. Exactly the guard `renderedJSON` uses for the same reason — without
        // it every sync reordered and reformatted a file Agentbox has no entry in.
        if names.isEmpty, previouslyManaged.isEmpty {
            guard FileManager.default.fileExists(atPath: file.path) else { return "" }
            return try String(contentsOf: file, encoding: .utf8)
        }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SkillboxError.mcpConflict("\(file.lastPathComponent) nie jest poprawnym JSON")
            }
            root = object
        } else if names.isEmpty { return "" }
        var current = Set((root["disabledMcpServers"] as? [String]) ?? [])
        for old in previouslyManaged.subtracting(names) { current.remove(old) }
        current.formUnion(names)
        if current.isEmpty { root.removeValue(forKey: "disabledMcpServers") } else { root["disabledMcpServers"] = current.sorted() }
        guard !root.isEmpty else { return "" }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
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

    /// Keeps generated files out of the repository, in two groups with two different reasons.
    ///
    /// `.claude/settings.local.json` is deliberately not lumped in with the MCP configs: it holds no
    /// secrets, it is Claude Code's own local-settings file, and Agentbox only ever adds a name to
    /// its `disabledMcpServers`. It is therefore excluded only once the project actually has such an
    /// opt-out, instead of being listed in every repository that merely has Claude Code ticked.
    private static func protectGeneratedFiles(_ project: URL, previews: [MCPPreview]) throws {
        let info = project.appending(path: ".git/info")
        guard FileManager.default.fileExists(atPath: info.path) else { return }
        let url = info.appending(path: "exclude")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var groups: [(marker: String, entries: [String])] = [
            ("# Skillbox MCP configs (mogą zawierać lokalne sekrety)", [".mcp.json", ".codex/config.toml", "opencode.json", "opencode.jsonc", ".skillbox/"])
        ]
        if previews.contains(where: { $0.disabledGlobalFile != nil && !($0.disabledGlobalContent ?? "").isEmpty }) {
            groups.append(("# Skillbox: lokalne ustawienia Claude Code, nieprzeznaczone do współdzielenia", [".claude/settings.local.json"]))
        }
        let present = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        var changed = false
        for group in groups {
            let missing = group.entries.filter { !present.contains($0) }
            guard !missing.isEmpty else { continue }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.contains(group.marker) { text += group.marker + "\n" }
            text += missing.joined(separator: "\n") + "\n"
            changed = true
        }
        guard changed else { return }
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
