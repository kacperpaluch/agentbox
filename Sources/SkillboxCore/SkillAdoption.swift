import Foundation

/// A managed skill whose copy inside a project no longer matches the library's.
///
/// Only the unambiguous case is reported: the library copy has not moved since this project was
/// synchronized — its manifest timestamp still matches `Skill.updatedAt` — so the difference can
/// only have come from the project side, where the user was working. When the library changed too,
/// the two edits are a conflict that no automatic answer resolves, and the ordinary "nieaktualny"
/// reporting already covers it.
public struct DriftedSkill: Identifiable, Hashable, Sendable {
    public var skillID: String
    public var skillName: String
    public var projectID: UUID
    public var projectName: String
    public var tool: Tool
    /// The project's copy — the one that would replace the library's.
    public var path: String
    /// A Git-backed skill is replaced wholesale by `update`, so anything adopted into it would be
    /// thrown away at the next update. Reported so the user learns why nothing can be taken from
    /// here, but never adopted — the same rule the in-app editor already follows.
    public var isGitBacked: Bool
    public var id: String { "\(projectID.uuidString)|\(tool.rawValue)|\(skillID)" }

    public init(skillID: String, skillName: String, projectID: UUID, projectName: String, tool: Tool, path: String, isGitBacked: Bool) {
        self.skillID = skillID; self.skillName = skillName
        self.projectID = projectID; self.projectName = projectName
        self.tool = tool; self.path = path; self.isGitBacked = isGitBacked
    }
}

extension SkillboxService {
    /// Skills changed inside a project since it was last synchronized. Pass a `projectID` for one
    /// project, or nothing to look everywhere — which is also how a conflict between two projects
    /// changing the same skill becomes visible before anything is written.
    public func driftedSkills(projectID: UUID? = nil) async throws -> [DriftedSkill] {
        let config = try await store.configuration()
        let catalog = try await store.catalog()
        let library = await store.skillsDirectory
        let known = Dictionary(catalog.skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fm = FileManager.default
        var found: [DriftedSkill] = []
        for project in config.resolvedProjects.sorted(by: { $0.name < $1.name }) where projectID == nil || project.id == projectID {
            let projectURL = URL(fileURLWithPath: project.path)
            for tool in project.tools + Self.abandonedTools(project: project) {
                let target = try Self.managedTarget(project: projectURL, tool: tool)
                for (id, written) in Self.skillManifest(at: target).skills.sorted(by: { $0.key < $1.key }) {
                    guard let skill = known[id] else { continue }
                    // The library moved on since this project was written, so what differs here is
                    // an ordinary pending update, not something the project has to offer back.
                    guard skill.updatedAt <= written else { continue }
                    let copy = target.appending(path: id)
                    guard fm.fileExists(atPath: copy.path), !Self.directoryMatches(library.appending(path: id), copy) else { continue }
                    found.append(DriftedSkill(
                        skillID: id, skillName: skill.name,
                        projectID: project.id, projectName: project.name,
                        tool: tool, path: copy.path, isGitBacked: skill.source.kind == .git
                    ))
                }
            }
        }
        return found
    }

    /// Copies the project's version of each skill back into the library, so work done where the
    /// work actually happens is not lost the next time the project is synchronized.
    ///
    /// The library entry is restamped, which is what makes every *other* project holding that skill
    /// report as outdated and pick the change up on its next sync — adoption is a library edit, and
    /// behaves exactly like editing the skill in the app.
    @discardableResult
    public func adoptSkillChanges(_ items: [DriftedSkill]) async throws -> [Skill] {
        guard !items.isEmpty else { return [] }
        var catalog = try await store.catalog()
        let library = await store.skillsDirectory
        let grouped = Dictionary(grouping: items, by: \.skillID)
        // Everything is checked before the first copy: a batch that cannot be applied in full must
        // not leave half of it in the library.
        for id in grouped.keys.sorted() {
            let sources = grouped[id] ?? []
            guard let index = catalog.skills.firstIndex(where: { $0.id == id }) else { throw SkillboxError.skillNotFound(id) }
            guard catalog.skills[index].source.kind == .local else {
                throw SkillboxError.invalidSkill("skill \(id) pochodzi z Git — wprowadź zmianę w repozytorium źródłowym, bo aktualizacja i tak zastąpi kopię w bibliotece")
            }
            // Two projects that changed the same skill differently cannot both be right, and taking
            // whichever came last would silently throw the other away.
            let first = URL(fileURLWithPath: sources[0].path)
            guard sources.dropFirst().allSatisfy({ Self.directoryMatches(first, URL(fileURLWithPath: $0.path)) }) else {
                throw SkillboxError.skillConflict("skill \(id) zmienił się inaczej w projektach: \(sources.map(\.projectName).sorted().joined(separator: ", ")) — przejmij zmiany z jednego z nich")
            }
            guard FileManager.default.fileExists(atPath: first.appending(path: "SKILL.md").path) else {
                throw SkillboxError.invalidSkill("brak SKILL.md w \(first.path)")
            }
        }
        var adopted: [Skill] = []
        var restamps: [(target: URL, skillID: String, date: Date)] = []
        for id in grouped.keys.sorted() {
            let sources = grouped[id] ?? []
            guard let index = catalog.skills.firstIndex(where: { $0.id == id }) else { continue }
            try copyReplacing(from: URL(fileURLWithPath: sources[0].path), to: library.appending(path: id))
            catalog.skills[index].updatedAt = .now
            adopted.append(catalog.skills[index])
            for source in sources {
                restamps.append((URL(fileURLWithPath: source.path).deletingLastPathComponent(), id, catalog.skills[index].updatedAt))
            }
        }
        try await store.save(catalog)
        // The projects the change came from already hold exactly what the library now has. Without
        // this they would be reported as outdated against their own contribution, and the next sync
        // would copy identical bytes back into them.
        for restamp in restamps { try? Self.restampSkillManifest(restamp.skillID, at: restamp.target, to: restamp.date) }
        return adopted
    }
}
