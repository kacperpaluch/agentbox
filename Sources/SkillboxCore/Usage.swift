import Foundation

/// Where one library item actually lands: which projects get it, through which parent folders, and
/// whether this Mac itself takes it.
///
/// `projects` is the answer that matters, and it is resolved rather than looked up: a project that
/// follows a parent folder, or that picks the item up through a tag, is in the list even though its
/// own record never names it. Without that, "usuń skill" was a question asked in the dark — the
/// deletion quietly reaches every selection, including a folder covering thirty projects.
public struct UsageReport: Hashable, Sendable {
    public var projects: [String]
    public var roots: [String]
    public var global: Bool
    /// Why the usage could not be worked out. A failed lookup is not "unused" — reporting it that
    /// way took the warning out of the very dialog that asks whether to delete.
    public var failure: String?
    public init(projects: [String] = [], roots: [String] = [], global: Bool = false, failure: String? = nil) {
        self.projects = projects; self.roots = roots; self.global = global; self.failure = failure
    }
    public var isUnused: Bool { failure == nil && projects.isEmpty && roots.isEmpty && !global }

    /// One line for a confirmation dialog, or `nil` when nothing uses the item.
    public var summary: String? {
        if let failure { return "nie udało się ustalić (\(failure))" }
        guard !isUnused else { return nil }
        var parts: [String] = []
        if !projects.isEmpty { parts.append("\(projects.count) \(Self.projectWord(projects.count))") }
        if !roots.isEmpty { parts.append("folder\(roots.count == 1 ? "" : "y") nadrzędn\(roots.count == 1 ? "y" : "e"): \(roots.joined(separator: ", "))") }
        if global { parts.append("ten Mac") }
        return parts.joined(separator: ", ")
    }

    private static func projectWord(_ count: Int) -> String {
        // 2–4 take the plural the Polish language uses for small counts, 12–14 do not.
        let lastTwo = count % 100, last = count % 10
        if count == 1 { return "projekt" }
        if (2...4).contains(last), !(12...14).contains(lastTwo) { return "projekty" }
        return "projektów"
    }
}

extension SkillboxService {
    public func usage(ofSkill skillID: String) async throws -> UsageReport {
        let catalog = try await store.catalog()
        return try await usage(
            matches: { SkillboxService.selectedSkills(in: catalog, for: $0).contains { $0.id == skillID } },
            selectionMatches: { selection in
                let tags = Set(selection.skillTags.map { $0.lowercased() })
                let tagged = catalog.skills.first { $0.id == skillID }.map { !tags.isDisjoint(with: $0.tags.map { $0.lowercased() }) } ?? false
                return (selection.skillIDs.contains(skillID) || tagged) && !selection.excludedSkillIDs.contains(skillID)
            }
        )
    }

    public func usage(ofServer serverID: UUID) async throws -> UsageReport {
        let mcp = try await store.mcpConfiguration()
        let matches: @Sendable (AttachmentSelection) -> Bool = { selection in
            SkillboxService.assignedServers(selection: selection, mcp: mcp).contains { $0.id == serverID }
        }
        return try await usage(selection: matches)
    }

    public func usage(ofDoc docID: String) async throws -> UsageReport {
        let docs = try await store.docsConfiguration()
        let tagsOfDoc = Set((docs.docs.first { $0.id == docID }?.tags ?? []).map { $0.lowercased() })
        return try await usage(selection: { selection in
            selection.docIDs.contains(docID) || !Set(selection.docTags.map { $0.lowercased() }).isDisjoint(with: tagsOfDoc)
        })
    }

    public func usage(ofPlugin pluginID: UUID) async throws -> UsageReport {
        try await usage(selection: { ($0.claudePluginIDs ?? []).contains(pluginID) })
    }

    /// The shape every lookup above shares: ask the question of each project's effective selection,
    /// of each parent folder's own selection, and of this Mac's.
    private func usage(selection matches: (AttachmentSelection) -> Bool) async throws -> UsageReport {
        try await usage(matches: nil, selectionMatches: matches)
    }

    /// `matches` answers for a whole project when resolving needs more than the selection alone —
    /// skills, where a project can exclude an item its folder assigns.
    private func usage(matches: ((Project) -> Bool)?, selectionMatches: (AttachmentSelection) -> Bool) async throws -> UsageReport {
        let config = try await store.configuration()
        var projects: [String] = []
        for project in config.resolvedProjects.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let used = matches?(project) ?? selectionMatches(config.storedSelection(for: .project(config.selectionID(for: project))))
            if used { projects.append(project.name) }
        }
        let roots = config.roots
            .filter { selectionMatches(config.storedSelection(for: .root($0.id))) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return UsageReport(projects: projects, roots: roots, global: selectionMatches(config.storedSelection(for: .global)))
    }
}
