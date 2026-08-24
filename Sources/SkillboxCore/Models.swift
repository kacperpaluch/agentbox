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
    public var tools: [Tool]
    public var skillIDs: [String]
    public var tags: [String]
    /// Skills excluded from this project even when a selected tag matches them.
    /// Optional so projects saved before exclusions keep decoding.
    public var excludedSkillIDs: [String]?
    /// Whether Agentbox may add generated MCP files to the project's tracked `.gitignore`.
    /// `nil` means no, so existing projects are never modified without an explicit choice.
    public var manageGitignore: Bool?

    public init(id: UUID = UUID(), name: String, path: String, tools: [Tool], skillIDs: [String] = [], tags: [String] = [], excludedSkillIDs: [String]? = nil, manageGitignore: Bool? = nil) {
        self.id = id; self.name = name; self.path = path; self.tools = tools
        self.skillIDs = skillIDs; self.tags = tags
        self.excludedSkillIDs = excludedSkillIDs; self.manageGitignore = manageGitignore
    }
}

public struct Catalog: Codable, Sendable {
    public var version = 1
    public var skills: [Skill] = []
    public init() {}
}

public struct LocalConfiguration: Codable, Sendable {
    public var projects: [Project] = []
    public var backupRemote: String?
    /// Global (per-user) skill selection written to `~/.claude/skills` and its equivalents.
    /// Optional so libraries created before global sync keep decoding.
    public var globalTools: [Tool]?
    public var globalSkillIDs: [String]?
    public var globalTags: [String]?
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
    public var group: String?
    public var profile: String?
    public var tags: [String]?

    public init(id: UUID = UUID(), name: String, transport: MCPTransport, command: String = "", arguments: [String] = [], url: String = "", environment: [String: String] = [:], headers: [String: String] = [:], enabled: Bool = true, literalEnvironment: [String: String]? = nil, literalHeaders: [String: String]? = nil, secretEnvironment: [String: String]? = nil, secretHeaders: [String: String]? = nil, group: String? = nil, profile: String? = nil, tags: [String]? = nil) {
        self.id = id; self.name = name; self.transport = transport; self.command = command
        self.arguments = arguments; self.url = url; self.environment = environment
        self.headers = headers; self.enabled = enabled
        self.literalEnvironment = literalEnvironment; self.literalHeaders = literalHeaders
        self.secretEnvironment = secretEnvironment; self.secretHeaders = secretHeaders
        self.group = group; self.profile = profile
        self.tags = tags
    }
}

public struct MCPPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var serverIDs: [UUID]
    public init(id: UUID = UUID(), name: String, serverIDs: [UUID] = []) { self.id = id; self.name = name; self.serverIDs = serverIDs }
}

public struct MCPConfiguration: Codable, Sendable {
    public var version = 1
    public var servers: [MCPServer] = []
    public var presets: [MCPPreset] = []
    public var projectPresetIDs: [String: [UUID]] = [:]
    public var projectProfileSelections: [String: [String: UUID]]?
    public var projectServerIDs: [String: [UUID]]?
    public var projectServerTags: [String: [String]]?
    public var aiSettings: MCPAISettings?
    public init() {}
}

public enum MCPAIProvider: String, Codable, CaseIterable, Sendable { case openAI, claude }

public enum MCPAIDefaults {
    public static let openAIModel = "gpt-5.6"
    public static let claudeModel = "claude-sonnet-5"
}

public struct MCPAISettings: Codable, Sendable {
    public var provider: MCPAIProvider
    public var openAIModel: String
    public var claudeModel: String
    public init(provider: MCPAIProvider = .openAI, openAIModel: String = MCPAIDefaults.openAIModel, claudeModel: String = MCPAIDefaults.claudeModel) {
        self.provider = provider; self.openAIModel = openAIModel; self.claudeModel = claudeModel
    }
}

public struct MCPImportSummary: Sendable {
    public var servers: [MCPServer]
    public var secretCount: Int
    public var stdioCount: Int
    public var httpCount: Int
    public var fields: [MCPImportField]
    public init(servers: [MCPServer], secretCount: Int, stdioCount: Int, httpCount: Int, fields: [MCPImportField] = []) { self.servers = servers; self.secretCount = secretCount; self.stdioCount = stdioCount; self.httpCount = httpCount; self.fields = fields }
}

public enum MCPValueClassification: String, Codable, CaseIterable, Sendable {
    case environment = "Zmienna systemowa"
    case secret = "Sekret lokalny"
    case literal = "Zwykła wartość"
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
    public var value: String
    public var classification: MCPValueClassification
    public var hasStoredSecret: Bool

    public init(id: UUID = UUID(), location: MCPImportField.Location, key: String, value: String = "", classification: MCPValueClassification, hasStoredSecret: Bool = false) {
        self.id = id; self.location = location; self.key = key; self.value = value
        self.classification = classification; self.hasStoredSecret = hasStoredSecret
    }
}

public struct MCPPreview: Sendable {
    public var tool: Tool
    public var file: String
    public var content: String
    public var added: [String]
    public var removed: [String]
    /// A previously managed file that this tool no longer writes to, for example `opencode.json`
    /// after `opencode.jsonc` appeared. Its managed entries are stripped in the same transaction.
    public var staleFile: String?
    public var staleContent: String?
    public init(tool: Tool, file: String, content: String, added: [String], removed: [String], staleFile: String? = nil, staleContent: String? = nil) {
        self.tool = tool; self.file = file; self.content = content; self.added = added; self.removed = removed
        self.staleFile = staleFile; self.staleContent = staleContent
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

public struct ProjectSyncPreview: Sendable {
    public var skills: [SkillSyncPreview]
    public var mcp: [MCPPreview]
    public init(skills: [SkillSyncPreview], mcp: [MCPPreview]) { self.skills = skills; self.mcp = mcp }
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

    public var changeCount: Int {
        if case .pending(let added, let outdated, let removed) = state { return added + outdated + removed }
        return 0
    }

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
        }
    }
}
