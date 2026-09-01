import Foundation

public enum Tool: String, Codable, CaseIterable, Sendable {
    case claude, codex, opencode

    public var projectSkillsPath: String {
        switch self {
        case .claude: ".claude/skills"
        case .codex: ".codex/skills"
        case .opencode: ".opencode/skills"
        }
    }

    public func globalSkillsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch self {
        case .claude: home.appending(path: ".claude/skills")
        case .codex: home.appending(path: ".codex/skills")
        case .opencode: home.appending(path: ".config/opencode/skills")
        }
    }
}

public struct SkillSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, git }
    public var kind: Kind
    public var location: String
    public var subpath: String?
    public var branch: String?
    public var revision: String?

    public init(kind: Kind, location: String, subpath: String? = nil, branch: String? = nil, revision: String? = nil) {
        self.kind = kind; self.location = location; self.subpath = subpath
        self.branch = branch; self.revision = revision
    }
}

public struct Skill: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tags: [String]
    public var source: SkillSource
    public var updatedAt: Date

    public init(id: String, name: String, tags: [String] = [], source: SkillSource, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.tags = tags
        self.source = source; self.updatedAt = updatedAt
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    // Filled in from `selections.json` by `resolved(_:)`; see `CodingKeys` below. Defaults let the
    // synthesized decoder work without them being present in the file.
    public var tools: [Tool] = []
    public var skillIDs: [String] = []
    public var tags: [String] = []
    /// Skills excluded from this project even when a selected tag matches them.
    public var excludedSkillIDs: [String]?
    /// Whether Agentbox may add generated MCP files to the project's tracked `.gitignore`.
    /// `nil` means no, so existing projects are never modified without an explicit choice.
    public var manageGitignore: Bool?
    /// Parent folder this project came from. `nil` for a project added on its own, so projects
    /// saved before parent folders existed keep decoding and keep their own settings.
    public var rootID: UUID?
    /// `true` when the user gave this project settings of its own instead of the parent folder's.
    /// `nil` means it follows the folder, which is what a project added in a batch does.
    public var overridesRoot: Bool?

    public init(id: UUID = UUID(), name: String, path: String, tools: [Tool] = [], skillIDs: [String] = [], tags: [String] = [], excludedSkillIDs: [String]? = nil, manageGitignore: Bool? = nil, rootID: UUID? = nil, overridesRoot: Bool? = nil) {
        self.id = id; self.name = name; self.path = path; self.tools = tools
        self.skillIDs = skillIDs; self.tags = tags
        self.excludedSkillIDs = excludedSkillIDs; self.manageGitignore = manageGitignore
        self.rootID = rootID; self.overridesRoot = overridesRoot
    }

    /// What a project *is* — identity, where it lives, whether it follows a folder — is all that
    /// `projects.local.json` holds. What is *attached* to it lives in `selections.json`, under one
    /// key, together with every other place's attachments.
    ///
    /// `tools`, `skillIDs`, `tags` and `excludedSkillIDs` stay as properties because the whole sync
    /// path reads them, but they are filled in by `LocalConfiguration.resolved(_:)` from the
    /// selection — never decoded from or written to this file.
    enum CodingKeys: String, CodingKey { case id, name, path, manageGitignore, rootID, overridesRoot }
}

/// A parent folder added with `Dodaj wiele`. It holds the settings its subprojects inherit, so one
/// change reaches every project in the folder, and it remembers which new subfolders the user does
/// not want to be asked about again.
public struct ProjectRoot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    // As on `Project`: filled in from `selections.json`, never stored here.
    public var tools: [Tool] = []
    public var skillIDs: [String] = []
    public var tags: [String] = []
    public var excludedSkillIDs: [String]?
    public var manageGitignore: Bool?
    /// Whether Agentbox looks for new subfolders here and offers to add them as projects.
    public var watchesNewFolders: Bool
    /// Subfolders the user dismissed. They are never offered again until the list is cleared.
    public var ignoredPaths: [String]

    public init(id: UUID = UUID(), name: String, path: String, tools: [Tool] = [], skillIDs: [String] = [], tags: [String] = [], excludedSkillIDs: [String]? = nil, manageGitignore: Bool? = nil, watchesNewFolders: Bool = true, ignoredPaths: [String] = []) {
        self.id = id; self.name = name; self.path = path; self.tools = tools
        self.skillIDs = skillIDs; self.tags = tags
        self.excludedSkillIDs = excludedSkillIDs; self.manageGitignore = manageGitignore
        self.watchesNewFolders = watchesNewFolders; self.ignoredPaths = ignoredPaths
    }

    /// Like `Project`: the folder's identity and watch settings live here, its attachments in
    /// `selections.json` under the folder's own id.
    enum CodingKeys: String, CodingKey { case id, name, path, manageGitignore, watchesNewFolders, ignoredPaths }
}

/// A subfolder of a watched parent folder that is not a project yet and was not dismissed.
public struct DetectedProjectFolder: Codable, Identifiable, Hashable, Sendable {
    public var rootID: UUID
    public var rootName: String
    public var path: String
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(rootID: UUID, rootName: String, path: String) {
        self.rootID = rootID; self.rootName = rootName; self.path = path
    }
}

/// A shared text synchronized into a project as `AGENTS.md`. `CLAUDE.md` is never edited directly —
/// Agentbox always generates it as a one-line `@AGENTS.md` import, the convention Claude Code itself
/// documents for reading the same instructions as other agents without duplicating the text.
public struct AgentDoc: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tags: [String]
    public var content: String
    public var updatedAt: Date

    public init(id: String, name: String, tags: [String] = [], content: String, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.tags = tags
        self.content = content; self.updatedAt = updatedAt
    }
}

public struct DocsConfiguration: Codable, Sendable {
    public var version = 1
    public var docs: [AgentDoc] = []
    public init() {}
}

public struct Catalog: Codable, Sendable {
    public var version = 1
    public var skills: [Skill] = []
    /// Optional for libraries created before 0.19.0.
    public var claudePlugins: [ClaudePluginDefinition]?
    public init() {}
}

public struct ClaudePluginDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var marketplace: String
    public var plugin: String
    public var scope: ClaudePluginScope
    public init(id: UUID = UUID(), name: String, marketplace: String, plugin: String, scope: ClaudePluginScope = .project) {
        self.id = id; self.name = name; self.marketplace = marketplace; self.plugin = plugin; self.scope = scope
    }
}

public struct LocalConfiguration: Codable, Sendable {
    public var projects: [Project] = []
    /// Parent folders added in a batch. What their projects inherit lives in `selections`.
    public var projectRoots: [ProjectRoot]?
    /// Starting attachments for a newly created project. This is local to the Mac, just like the
    /// project list: it is a convenience template, not an assignment that existing projects inherit.
    public var projectDefaults = AttachmentSelection(tools: Tool.allCases)
    /// Every place's attachments, keyed by project id, folder id or `"global"`. Read from and
    /// written to `selections.json` by the store — never part of `projects.local.json`, which is
    /// this Mac's local record and stays out of the Git backup.
    public var selections: [String: AttachmentSelection] = [:]
    public init() {}

    // `backupRemote` used to live here, pointing at the library's Git backup. That feature is gone,
    // so the key is simply no longer decoded; an older `projects.local.json` still carrying it reads
    // fine and drops it on the next save.
    enum CodingKeys: String, CodingKey { case projects, projectRoots, projectDefaults }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
        projectRoots = try values.decodeIfPresent([ProjectRoot].self, forKey: .projectRoots)
        // MVP libraries have no template yet. They retain the historical new-project starting point:
        // all supported clients selected, with no attached content.
        projectDefaults = try values.decodeIfPresent(AttachmentSelection.self, forKey: .projectDefaults)
            ?? AttachmentSelection(tools: Tool.allCases)
    }
}

/// `selections.json`. One file answering "what is attached where", for projects, parent folders and
/// this Mac alike.
///
/// It is tracked in the Git backup, unlike `projects.local.json`. That is deliberate: the keys are
/// bare UUIDs and the values name skills, servers and documents that all live in the library
/// anyway — no paths, no project names, nothing local. It also means a restore now brings back
/// which skills a project used, which the old layout could only do for servers and documents.
public struct SelectionsConfiguration: Codable, Sendable {
    public var version = 1
    public var selections: [String: AttachmentSelection] = [:]
    public init() {}
}

public struct FullBackupMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var applicationVersion: String
    public init(formatVersion: Int = 1, createdAt: Date = .now, applicationVersion: String) { self.formatVersion = formatVersion; self.createdAt = createdAt; self.applicationVersion = applicationVersion }
}

public struct FullBackupInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var createdAt: Date
    public var applicationVersion: String
    public init(name: String, createdAt: Date, applicationVersion: String) { self.name = name; self.createdAt = createdAt; self.applicationVersion = applicationVersion }
}

public struct SyncResult: Sendable {
    public var copied: [String] = []
    public var removed: [String] = []
    public init() {}
}

public enum MCPTransport: String, Codable, CaseIterable, Sendable { case stdio, http }

public struct MCPServer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransport
    public var command: String
    public var arguments: [String]
    public var url: String
    /// Maps environment variable passed to the server -> source environment variable name.
    public var environment: [String: String]
    /// Maps HTTP header -> source environment variable name. Literal secrets are intentionally unsupported.
    public var headers: [String: String]
    public var enabled: Bool
    public var literalEnvironment: [String: String]?
    public var literalHeaders: [String: String]?
    public var secretEnvironment: [String: String]?
    public var secretHeaders: [String: String]?
    public var tags: [String]?

    public init(id: UUID = UUID(), name: String, transport: MCPTransport, command: String = "", arguments: [String] = [], url: String = "", environment: [String: String] = [:], headers: [String: String] = [:], enabled: Bool = true, literalEnvironment: [String: String]? = nil, literalHeaders: [String: String]? = nil, secretEnvironment: [String: String]? = nil, secretHeaders: [String: String]? = nil, tags: [String]? = nil) {
        self.id = id; self.name = name; self.transport = transport; self.command = command
        self.arguments = arguments; self.url = url; self.environment = environment
        self.headers = headers; self.enabled = enabled
        self.literalEnvironment = literalEnvironment; self.literalHeaders = literalHeaders
        self.secretEnvironment = secretEnvironment; self.secretHeaders = secretHeaders
        self.tags = tags
    }

    /// Keeps a full connection definition while deliberately creating a new library identity.
    /// Project assignments use `id`, so they never follow a duplicated server automatically.
    public func duplicated(name: String) -> MCPServer {
        var copy = self
        copy.id = UUID()
        copy.name = name
        return copy
    }
}

public struct MCPConfiguration: Codable, Sendable {
    public var version = 1
    public var servers: [MCPServer] = []
    /// Per-project opt-out of a tool's own global/user-scope MCP servers — the ones defined outside
    /// Agentbox (`~/.codex/config.toml`, Claude Code's user scope) that load in every project
    /// automatically. Keyed by selection ID (project or parent folder, like `projectServerIDs`),
    /// then by `Tool.rawValue`, holding the names disabled for that selection.
    public var projectDisabledGlobalServers: [String: [String: [String]]]?
    /// Global servers a newly added project (or parent folder) starts out opted out of, keyed by
    /// `Tool.rawValue`. Applied once, when the selection is created, rather than consulted on every
    /// lookup — so a project added later can still be switched back on like any other, and existing
    /// projects are never changed behind the user's back.
    public var defaultDisabledGlobalServers: [String: [String]]?
    public init() {}
}

/// One MCP server Agentbox found declared globally for a tool — outside any project, so it loads
/// everywhere unless a project opts out. Agentbox only reads these to list them; it never edits the
/// files they live in.
public struct GlobalMCPServerRef: Identifiable, Hashable, Sendable {
    public var tool: Tool
    public var name: String
    public var id: String { "\(tool.rawValue):\(name)" }
    public init(tool: Tool, name: String) { self.tool = tool; self.name = name }
}

public struct MCPImportSummary: Sendable {
    public var servers: [MCPServer]
    public var secretCount: Int
    public var stdioCount: Int
    public var httpCount: Int
    public var fields: [MCPImportField]
    /// True when the pasted JSON is one server definition rather than a map of named servers.
    public var isSingleServerInput: Bool
    public init(servers: [MCPServer], secretCount: Int, stdioCount: Int, httpCount: Int, fields: [MCPImportField] = [], isSingleServerInput: Bool = false) { self.servers = servers; self.secretCount = secretCount; self.stdioCount = stdioCount; self.httpCount = httpCount; self.fields = fields; self.isSingleServerInput = isSingleServerInput }
}

/// How one MCP value is written down: as a reference to a system environment variable, or as the
/// value itself. This is a display type only — it is never persisted, so it carries no third
/// "secret" case any more. Older versions had one, back when values could live in a separate
/// `mcp-secrets.json`; nothing writes that file today.
public enum MCPValueClassification: String, CaseIterable, Sendable {
    case environment = "Zmienna systemowa"
    case literal = "Wartość lokalna"
}

public struct MCPImportField: Identifiable, Hashable, Sendable {
    public enum Location: String, Codable, Sendable { case environment, header }
    public var id: String
    public var serverName: String
    public var location: Location
    public var key: String
    public var displayValue: String
    public var classification: MCPValueClassification

    /// Builds the identity used to match a field with its user-chosen classification.
    /// The unit separator cannot appear in server names or sane keys, unlike "|".
    public static func fieldID(serverName: String, location: Location, key: String) -> String {
        "\(serverName)\u{1F}\(location.rawValue)\u{1F}\(key)"
    }

    public init(serverName: String, location: Location, key: String, displayValue: String, classification: MCPValueClassification) {
        self.id = Self.fieldID(serverName: serverName, location: location, key: key)
        self.serverName = serverName; self.location = location; self.key = key
        self.displayValue = displayValue; self.classification = classification
    }
}

public struct MCPManagedField: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var location: MCPImportField.Location
    public var key: String
    /// The real value — including a secret's plaintext. Agentbox is local and single-user, so the
    /// field editor shows it as is instead of masking it; only `classification` decides whether it
    /// ever leaves this Mac.
    public var value: String
    public var classification: MCPValueClassification

    public init(id: UUID = UUID(), location: MCPImportField.Location, key: String, value: String = "", classification: MCPValueClassification) {
        self.id = id; self.location = location; self.key = key; self.value = value
        self.classification = classification
    }
}

public struct MCPPreview: Sendable {
    public var tool: Tool
    public var file: String
    /// The full new content of `file`. Empty means the file should not exist at all: it is never
    /// created, and an existing one is removed when the preview is applied.
    public var content: String
    public var added: [String]
    public var removed: [String]
    /// A previously managed file that this tool no longer writes to, for example `opencode.json`
    /// after `opencode.jsonc` appeared. Its managed entries are stripped in the same transaction.
    public var staleFile: String?
    public var staleContent: String?
    /// Claude Code's per-project opt-out of its global MCP servers lives in a different file than
    /// `.mcp.json` (`.claude/settings.local.json`), so it is tracked as a second managed file here
    /// instead of folded into `content`. Codex's equivalent override lives inside the same
    /// `.codex/config.toml` block as everything else, so it needs none of this and stays nil.
    public var disabledGlobalFile: String?
    public var disabledGlobalContent: String?
    public var disabledGlobalAdded: [String]
    public var disabledGlobalRemoved: [String]
    public init(tool: Tool, file: String, content: String, added: [String], removed: [String], staleFile: String? = nil, staleContent: String? = nil, disabledGlobalFile: String? = nil, disabledGlobalContent: String? = nil, disabledGlobalAdded: [String] = [], disabledGlobalRemoved: [String] = []) {
        self.tool = tool; self.file = file; self.content = content; self.added = added; self.removed = removed
        self.staleFile = staleFile; self.staleContent = staleContent
        self.disabledGlobalFile = disabledGlobalFile; self.disabledGlobalContent = disabledGlobalContent
        self.disabledGlobalAdded = disabledGlobalAdded; self.disabledGlobalRemoved = disabledGlobalRemoved
    }
}

public struct SkillSyncPreview: Sendable {
    public var tool: Tool
    public var target: String
    public var added: [String]
    /// Managed skills whose library version is newer than the copy recorded in the manifest.
    /// Skills that are already up to date appear in none of these lists.
    public var updated: [String]
    public var removed: [String]
    public init(tool: Tool, target: String, added: [String], updated: [String], removed: [String]) {
        self.tool = tool; self.target = target; self.added = added; self.updated = updated; self.removed = removed
    }
}

/// The plan for one generated file that is not tied to a specific `Tool` — today `AGENTS.md` and the
/// `CLAUDE.md` import that is always generated alongside it.
public struct DocPreview: Sendable {
    public var file: String
    /// The full new content of `file`. Empty means the file should not exist at all: it is never
    /// created, and an existing managed copy is removed.
    public var content: String
    public var added: [String]
    public var removed: [String]
    public init(file: String, content: String, added: [String], removed: [String]) {
        self.file = file; self.content = content; self.added = added; self.removed = removed
    }
}

public struct ProjectSyncPreview: Sendable {
    public var skills: [SkillSyncPreview]
    public var mcp: [MCPPreview]
    public var docs: [DocPreview]
    public var plugins: [ClaudePluginPreview]
    public init(skills: [SkillSyncPreview], mcp: [MCPPreview], docs: [DocPreview] = [], plugins: [ClaudePluginPreview] = []) { self.skills = skills; self.mcp = mcp; self.docs = docs; self.plugins = plugins }
    /// Selected plugins Claude Code has not been asked for yet. The project status counts these,
    /// so `Synchronizuj` is offered for a plugin exactly as it is for a missing skill.
    public var missingPlugins: [ClaudePluginPreview] { plugins.filter { !$0.isInstalled } }
}

public struct ProjectSyncPlan: Identifiable, Sendable {
    public var id: UUID { project.id }
    public var project: Project
    public var preview: ProjectSyncPreview

    public init(project: Project, preview: ProjectSyncPreview) {
        self.project = project
        self.preview = preview
    }
}

/// Whether a project's files still match the library, without opening its full preview.
public struct ProjectStatus: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case synced
        case pending(added: Int, outdated: Int, removed: Int)
        /// Synchronization would stop: an unmanaged skill or MCP entry blocks it.
        case blocked(String)
        /// The project folder is gone.
        case missing
    }
    public var id: UUID { projectID }
    public var projectID: UUID
    public var state: State

    public init(projectID: UUID, state: State) { self.projectID = projectID; self.state = state }
}

/// A skill directory found inside a project that Agentbox does not manage and that is not yet
/// in the library. Adopting it copies it into the library so it can be synchronized everywhere.
public struct AdoptableSkill: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var suggestedID: String
    public var path: String
    public var tool: Tool
    public init(suggestedID: String, path: String, tool: Tool) { self.suggestedID = suggestedID; self.path = path; self.tool = tool }
}

/// A candidate `addGitCollection` found a `SKILL.md` for but did not import — its id already
/// belongs to a skill from a different source, so overwriting it silently would have been wrong.
public struct SkippedSkill: Identifiable, Hashable, Sendable {
    public var id: String
    public var reason: String
    public init(id: String, reason: String) { self.id = id; self.reason = reason }
}

/// The outcome of importing a Git collection. One conflicting or invalid candidate no longer sinks
/// the whole batch — every other skill in the repository still gets imported and saved, and
/// `skipped` says which ones did not and why.
public struct GitImportResult: Sendable {
    public var imported: [Skill]
    public var skipped: [SkippedSkill]
    public init(imported: [Skill], skipped: [SkippedSkill] = []) { self.imported = imported; self.skipped = skipped }
}

public struct ProjectSyncOutcome: Identifiable, Sendable {
    public enum State: Sendable, Equatable {
        case synced
        /// Already matched the library, so nothing was written and no backup was taken.
        case upToDate
        /// The project was rolled back to its previous state; the message explains why.
        case failed(String)
        /// Not attempted, because an earlier project failed.
        case skipped
    }
    public var id: UUID { plan.project.id }
    public var plan: ProjectSyncPlan
    public var state: State

    public init(plan: ProjectSyncPlan, state: State) { self.plan = plan; self.state = state }
}

public struct LibrarySnapshot: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var date: Date
    public var files: [String]
    public init(name: String, date: Date, files: [String]) { self.name = name; self.date = date; self.files = files }
}

public enum SkillboxError: LocalizedError {
    case invalidSkill(String), duplicateSkill(String), skillNotFound(String)
    case projectNotFound(String), commandFailed(String), unsafePath(String)
    case mcpConflict(String), skillConflict(String)
    case docNotFound(String), docConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkill(let value): "Nieprawidłowy skill: \(value)"
        case .duplicateSkill(let value): "Skill już istnieje: \(value)"
        case .skillNotFound(let value): "Nie znaleziono skilla: \(value)"
        case .projectNotFound(let value): "Nie znaleziono projektu: \(value)"
        case .commandFailed(let value): "Polecenie nie powiodło się: \(value)"
        case .unsafePath(let value): "Niebezpieczna ścieżka: \(value)"
        case .mcpConflict(let value): "Konflikt MCP: \(value)"
        case .skillConflict(let value): "Konflikt skilla: \(value)"
        case .docNotFound(let value): "Nie znaleziono dokumentu: \(value)"
        case .docConflict(let value): "Konflikt dokumentu: \(value)"
        }
    }
}
