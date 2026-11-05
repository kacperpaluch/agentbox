import Foundation

/// One tag and everything that uses it: entries carrying it and places attaching by it.
public struct TagSummary: Identifiable, Hashable, Sendable {
    public let name: String
    public var skills = 0
    public var servers = 0
    public var docs = 0
    /// Projects, parent folders, this Mac and the new-project defaults that attach by this tag.
    public var places = 0
    public var id: String { name }
    public var total: Int { skills + servers + docs + places }
    public init(name: String) { self.name = name }
}

extension SkillboxService {
    /// Every tag in the library with what uses it, sorted by name.
    public func tagSummaries() async throws -> [TagSummary] {
        let catalog = try await store.catalog(), config = try await store.configuration()
        let mcp = try await store.mcpConfiguration(), docs = try await store.docsConfiguration()
        var result: [String: TagSummary] = [:]
        func count(_ tags: [String], _ field: WritableKeyPath<TagSummary, Int>) {
            for tag in Set(tags.map { $0.lowercased() }) { result[tag, default: TagSummary(name: tag)][keyPath: field] += 1 }
        }
        for skill in catalog.skills { count(skill.tags, \.skills) }
        for server in mcp.servers { count(server.tags ?? [], \.servers) }
        for doc in docs.docs { count(doc.tags, \.docs) }
        for selection in Array(config.selections.values) + [config.projectDefaults] { count(selection.skillTags + selection.serverTags + selection.docTags, \.places) }
        return result.values.sorted { $0.name < $1.name }
    }

    /// Renames a tag everywhere at once — skills, MCP servers, documents and every place that
    /// attaches by it — in one save with one snapshot. A name already in use merges the two.
    ///
    /// The places matter most: renaming the tag on the skills alone would silently detach them
    /// from every project that picks them by the old name, at the next synchronization.
    @discardableResult
    public func renameTag(_ old: String, to new: String) async throws -> TagSummary {
        let from = old.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let to = new.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !to.isEmpty, !to.contains(",") else { throw SkillboxError.invalidInput("nowa nazwa tagu nie może być pusta ani zawierać przecinka") }
        guard from != to else { throw SkillboxError.invalidInput("nowa nazwa tagu jest taka sama jak obecna") }
        var catalog = try await store.catalog(), config = try await store.configuration()
        var mcp = try await store.mcpConfiguration(), docs = try await store.docsConfiguration()
        var changed = TagSummary(name: to)
        func renamed(_ tags: [String], _ field: WritableKeyPath<TagSummary, Int>) -> [String] {
            guard tags.contains(where: { $0.lowercased() == from }) else { return tags }
            changed[keyPath: field] += 1
            var seen = Set<String>()
            return tags.map { $0.lowercased() == from ? to : $0 }.filter { seen.insert($0.lowercased()).inserted }
        }
        func renamed(_ selection: AttachmentSelection) -> AttachmentSelection {
            var value = selection
            let before = changed.places
            value.skillTags = renamed(value.skillTags, \.places)
            value.serverTags = renamed(value.serverTags, \.places)
            value.docTags = renamed(value.docTags, \.places)
            // One place using the tag for several kinds is still one place.
            changed.places = min(changed.places, before + 1)
            return value
        }
        for index in catalog.skills.indices { catalog.skills[index].tags = renamed(catalog.skills[index].tags, \.skills) }
        for index in mcp.servers.indices where mcp.servers[index].tags != nil { mcp.servers[index].tags = renamed(mcp.servers[index].tags ?? [], \.servers) }
        for index in docs.docs.indices { docs.docs[index].tags = renamed(docs.docs[index].tags, \.docs) }
        for key in Array(config.selections.keys) { config.selections[key] = config.selections[key].map(renamed) }
        config.projectDefaults = renamed(config.projectDefaults)
        guard changed.total > 0 else { throw SkillboxError.invalidInput("tag \(from) nie jest nigdzie używany") }
        try await store.save(catalog, config, mcp, docs)
        return changed
    }
}
