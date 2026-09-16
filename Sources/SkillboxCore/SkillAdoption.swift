import Foundation

/// A managed skill whose copy inside a project no longer matches the library's.
///
/// Only the unambiguous case is reported: the library copy still holds what was written into this
/// project, so the difference can only have come from the project side, where the user was working.
/// Manifests since 0.28.0 record a digest of what was written and answer that directly; older ones
/// only have a timestamp, which a skill edited straight in the library folder does not move — for
/// those the timestamp is all there is until the next sync records a digest. When the library
/// changed too, the two edits are a conflict that no automatic answer resolves, and the ordinary
/// "nieaktualny" reporting already covers it.
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
    /// Both sides as they were when this was listed. Adoption compares them again before writing,
    /// so a library edited in the meantime is never overwritten by a stale proposal.
    var libraryDigest: String
    var projectDigest: String
    public var id: String { "\(projectID.uuidString)|\(tool.rawValue)|\(skillID)" }
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
                let manifest: SkillManifest
                do { manifest = try Self.skillManifest(at: target) } catch {
                    // Asked about one project, its damaged manifest is the answer. Across all of
                    // them, that project is already shown as blocked with this reason, and it must
                    // not hide what the other projects have to offer.
                    if projectID != nil { throw error }
                    continue
                }
                for (id, written) in manifest.skills.sorted(by: { $0.key < $1.key }) {
                    guard let skill = known[id] else { continue }
                    let copy = target.appending(path: id)
                    guard fm.fileExists(atPath: copy.path),
                          let projectDigest = Self.skillDigest(copy),
                          let libraryDigest = Self.skillDigest(library.appending(path: id)),
                          projectDigest != libraryDigest else { continue }
                    if let recorded = manifest.digests?[id] {
                        // Only the project moved away from what was written.
                        guard projectDigest != recorded, libraryDigest == recorded else { continue }
                    } else {
                        // The library moved on since this project was written, so what differs here
                        // is an ordinary pending update, not something the project has to offer back.
                        guard skill.updatedAt <= written else { continue }
                    }
                    found.append(DriftedSkill(
                        skillID: id, skillName: skill.name,
                        projectID: project.id, projectName: project.name,
                        tool: tool, path: copy.path, isGitBacked: skill.source.kind == .git,
                        libraryDigest: libraryDigest, projectDigest: projectDigest
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
            guard Set(sources.map(\.projectDigest)).count == 1 else {
                throw SkillboxError.skillConflict("skill \(id) zmienił się inaczej w projektach: \(sources.map(\.projectName).sorted().joined(separator: ", ")) — przejmij zmiany z jednego z nich")
            }
            // What was reviewed is what gets written, and only over the library it was compared with.
            let stale = "skill \(id) zmienił się od przygotowania listy — odśwież ją przed przejęciem zmian"
            guard Self.skillDigest(library.appending(path: id)) == sources[0].libraryDigest else { throw SkillboxError.skillConflict(stale) }
            for source in sources where Self.skillDigest(URL(fileURLWithPath: source.path)) != source.projectDigest {
                throw SkillboxError.skillConflict(stale)
            }
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: sources[0].path).appending(path: "SKILL.md").path) else {
                throw SkillboxError.invalidSkill("brak SKILL.md w \(sources[0].path)")
            }
        }
        var adopted: [Skill] = []
        var copies: [(source: URL, id: String)] = []
        var restamps: [(target: URL, skillID: String, date: Date)] = []
        for id in grouped.keys.sorted() {
            let sources = grouped[id] ?? []
            guard let index = catalog.skills.firstIndex(where: { $0.id == id }) else { continue }
            copies.append((URL(fileURLWithPath: sources[0].path), id))
            catalog.skills[index].updatedAt = .now
            adopted.append(catalog.skills[index])
            for source in sources {
                restamps.append((URL(fileURLWithPath: source.path).deletingLastPathComponent(), id, catalog.skills[index].updatedAt))
            }
        }
        let saved = catalog
        try await replacingLibrarySkills(copies) { try await self.store.save(saved) }
        // The projects the change came from already hold exactly what the library now has. Without
        // this they would be reported as outdated against their own contribution, and the next sync
        // would copy identical bytes back into them. The library change is already committed at
        // this point; a restamp that fails only costs that project one redundant sync.
        for restamp in restamps { try? Self.restampSkillManifest(restamp.skillID, at: restamp.target, to: restamp.date) }
        return adopted
    }
}
