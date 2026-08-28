import Foundation

/// Everything that can be attached to one place: which clients it is for, and which skills, MCP
/// servers and documents land there.
///
/// Agentbox has three kinds of place — a project, a parent folder whose projects inherit its
/// settings, and the user's own machine ("globalnie") — and each used to carry its attachments in a
/// different shape: skills inline on `Project`/`ProjectRoot`, servers and documents in side maps in
/// `mcp.json`/`docs.json`, and the global choice as three loose fields on `LocalConfiguration`.
/// Reading "what is attached here" meant knowing which of the three applied, and every editor in the
/// app repeated the same six-field dance.
///
/// Now there is one type and one file: `selections.json`, keyed by project id, folder id or
/// `"global"`. `Project` and `ProjectRoot` keep these fields as properties, because the whole sync
/// path reads them, but they are filled in by `LocalConfiguration.resolved(_:)` — never stored on
/// the project itself.
public struct AttachmentSelection: Codable, Hashable, Sendable {
    /// Which clients this place is configured for. Lives here rather than on the place itself
    /// because the global target has nowhere else to put it.
    public var tools: [Tool]
    public var skillIDs: [String]
    public var skillTags: [String]
    /// Skills dropped from this place even though a selected tag matches them.
    public var excludedSkillIDs: [String]
    public var serverIDs: [UUID]
    public var serverTags: [String]
    public var docIDs: [String]
    public var docTags: [String]

    public init(
        tools: [Tool] = [],
        skillIDs: [String] = [],
        skillTags: [String] = [],
        excludedSkillIDs: [String] = [],
        serverIDs: [UUID] = [],
        serverTags: [String] = [],
        docIDs: [String] = [],
        docTags: [String] = []
    ) {
        self.tools = tools
        self.skillIDs = skillIDs; self.skillTags = skillTags; self.excludedSkillIDs = excludedSkillIDs
        self.serverIDs = serverIDs; self.serverTags = serverTags
        self.docIDs = docIDs; self.docTags = docTags
    }

    public var isEmpty: Bool {
        skillIDs.isEmpty && skillTags.isEmpty && serverIDs.isEmpty && serverTags.isEmpty
            && docIDs.isEmpty && docTags.isEmpty
    }
}

/// A place attachments can land. `project` and `root` carry the id they are stored under; `global`
/// needs none, because there is exactly one per Mac.
public enum SelectionTarget: Hashable, Sendable {
    case project(UUID)
    case root(UUID)
    case global
}

extension SelectionTarget {
    /// The key this place's attachments are stored under in `selections.json`. Projects and folders
    /// use their UUID — they never collide — and the Mac itself uses a reserved name.
    public var storageKey: String {
        switch self {
        case .project(let id), .root(let id): return id.uuidString
        case .global: return "global"
        }
    }
}

extension LocalConfiguration {
    /// What is written down for this exact place, with no inheritance applied.
    public func storedSelection(for target: SelectionTarget) -> AttachmentSelection {
        selections[target.storageKey] ?? AttachmentSelection()
    }
}

extension SkillboxService {
    /// What this place *effectively* uses, with folder inheritance already applied: a project that
    /// follows its parent folder reports the folder's attachments, because that is what actually
    /// gets synchronized into it.
    public func selection(for target: SelectionTarget) async throws -> AttachmentSelection {
        Self.selection(for: target, config: try await store.configuration(), resolvingInheritance: true)
    }

    /// What is written down for this exact place, ignoring inheritance. This is what an editor must
    /// show: a project that follows its folder has its own (usually empty) record, and showing the
    /// folder's values there would silently copy them onto the project the moment you pressed save.
    public func storedSelection(for target: SelectionTarget) async throws -> AttachmentSelection {
        Self.selection(for: target, config: try await store.configuration(), resolvingInheritance: false)
    }

    /// The pure form, taking the configuration instead of reading it. The GUI already keeps it in
    /// memory and answers this question on every redraw, so it calls this rather than hitting the
    /// store — and by sharing the body it cannot drift from what a sync would do.
    public static func selection(
        for target: SelectionTarget,
        config: LocalConfiguration,
        resolvingInheritance: Bool
    ) -> AttachmentSelection {
        guard case .project(let id) = target else { return config.storedSelection(for: target) }
        guard resolvingInheritance, let project = config.projects.first(where: { $0.id == id }) else {
            return config.storedSelection(for: target)
        }
        return config.storedSelection(for: .project(config.selectionID(for: project)))
    }

    /// Writes a selection back. One file, one save, one recovery snapshot — where this used to reach
    /// into three.
    public func setSelection(_ selection: AttachmentSelection, for target: SelectionTarget) async throws {
        var config = try await store.configuration()
        let catalog = try await store.catalog()
        let mcp = try await store.mcpConfiguration()
        let docs = try await store.docsConfiguration()

        // A project that follows its parent folder reads the folder's record, so writing one under
        // its own key would only leave something nothing ever reads.
        if case .project(let id) = target,
           let project = config.projects.first(where: { $0.id == id }),
           config.inheritsRoot(project) {
            config.selections[target.storageKey] = nil
            try await store.save(config)
            return
        }

        config.selections[target.storageKey] = Self.pruned(selection, catalog: catalog, mcp: mcp, docs: docs)
        try await store.save(config)
    }

    /// A selected tag already covers everything carrying it, so the redundant individual picks are
    /// dropped on save — otherwise removing the tag later would silently leave them behind.
    static func pruned(_ selection: AttachmentSelection, catalog: Catalog, mcp: MCPConfiguration, docs: DocsConfiguration) -> AttachmentSelection {
        var pruned = selection
        pruned.tools = selection.tools.sorted { $0.rawValue < $1.rawValue }
        pruned.skillTags = normalizedTags(selection.skillTags)
        pruned.serverTags = normalizedTags(selection.serverTags)
        pruned.docTags = normalizedTags(selection.docTags)

        let excluded = Set(selection.excludedSkillIDs)
        let skillTags = Dictionary(catalog.skills.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
        pruned.skillIDs = pruneRedundant(selection.skillIDs, coveredBy: pruned.skillTags) { skillTags[$0] ?? [] }
            .filter { !excluded.contains($0) }
        pruned.serverIDs = prunedServerIDs(Array(Set(selection.serverIDs)), tags: pruned.serverTags, servers: mcp.servers)
        pruned.docIDs = prunedDocIDs(Array(Set(selection.docIDs)), tags: pruned.docTags, docs: docs.docs)
        return pruned
    }
}

extension SkillboxService {
    /// Every place's attachments in one read. The GUI keeps this in memory and answers "what is
    /// attached here" from it on every redraw, instead of hitting the store per row.
    public func allSelections() async throws -> [String: AttachmentSelection] {
        try await store.configuration().selections
    }
}
