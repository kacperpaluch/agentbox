import Foundation
@testable import SkillboxCore

/// Test-only conveniences that take a project or folder with its attachments still written on it,
/// the way the API looked before selections moved into `selections.json`.
///
/// They exist so the suites can keep saying `Project(name:path:tools:skillIDs:)` — which reads well
/// in a test — without the production API carrying a second way to pass the same thing. Each one
/// splits the value into the record and its selection and calls the real method.
extension SkillboxService {
    /// The identity half of a project: everything `projects.local.json` still stores.
    private static func record(_ project: Project) -> Project {
        Project(id: project.id, name: project.name, path: project.path,
                manageGitignore: project.manageGitignore, rootID: project.rootID, overridesRoot: project.overridesRoot)
    }

    /// Omitting the server or document arguments means "leave them as they are" — the way the old
    /// API behaved, where they lived in files this call did not touch.
    private func merged(_ project: Project, _ existing: AttachmentSelection, serverIDs: [UUID]?, serverTags: [String]?, docIDs: [String]?, docTags: [String]?) -> AttachmentSelection {
        AttachmentSelection(tools: project.tools, skillIDs: project.skillIDs, skillTags: project.tags,
                            excludedSkillIDs: project.excludedSkillIDs ?? [],
                            serverIDs: serverIDs ?? existing.serverIDs, serverTags: serverTags ?? existing.serverTags,
                            docIDs: docIDs ?? existing.docIDs, docTags: docTags ?? existing.docTags)
    }

    private func merged(_ root: ProjectRoot, _ existing: AttachmentSelection, serverIDs: [UUID]?, serverTags: [String]?, docIDs: [String]?, docTags: [String]?) -> AttachmentSelection {
        AttachmentSelection(tools: root.tools, skillIDs: root.skillIDs, skillTags: root.tags,
                            excludedSkillIDs: root.excludedSkillIDs ?? [],
                            serverIDs: serverIDs ?? existing.serverIDs, serverTags: serverTags ?? existing.serverTags,
                            docIDs: docIDs ?? existing.docIDs, docTags: docTags ?? existing.docTags)
    }

    @discardableResult
    func addProject(_ project: Project, serverIDs: [UUID]? = nil, serverTags: [String]? = nil, docIDs: [String]? = nil, docTags: [String]? = nil) async throws -> Project {
        let existing = try await store.configuration().storedSelection(for: .project(project.id))
        return try await addProject(Self.record(project), selection: merged(project, existing, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags))
    }

    func updateProject(_ project: Project, serverIDs: [UUID]? = nil, serverTags: [String]? = nil, docIDs: [String]? = nil, docTags: [String]? = nil) async throws {
        let existing = try await store.configuration().storedSelection(for: .project(project.id))
        try await updateProject(Self.record(project), selection: merged(project, existing, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags))
    }

    @discardableResult
    func addProjectRoot(_ root: ProjectRoot, folders: [String], serverIDs: [UUID]? = nil, serverTags: [String]? = nil, docIDs: [String]? = nil, docTags: [String]? = nil, treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
        let existing = try await store.configuration().storedSelection(for: .root(root.id))
        return try await addProjectRoot(root, folders: folders,
                                        selection: merged(root, existing, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags),
                                        treatingExistingAsKnown: treatingExistingAsKnown)
    }

    func updateProjectRoot(_ root: ProjectRoot, serverIDs: [UUID]? = nil, serverTags: [String]? = nil, docIDs: [String]? = nil, docTags: [String]? = nil) async throws {
        let existing = try await store.configuration().storedSelection(for: .root(root.id))
        try await updateProjectRoot(root, selection: merged(root, existing, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags))
    }

    @discardableResult
    func adoptProjectsIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], serverIDs: [UUID]? = nil, serverTags: [String]? = nil, docIDs: [String]? = nil, docTags: [String]? = nil, treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
        let existing = try await store.configuration().storedSelection(for: .root(root.id))
        return try await adoptProjectsIntoRoot(root, following: following, keepingOwnSettings: keepingOwnSettings,
                                               selection: merged(root, existing, serverIDs: serverIDs, serverTags: serverTags, docIDs: docIDs, docTags: docTags),
                                               treatingExistingAsKnown: treatingExistingAsKnown)
    }

    /// What a place has attached, as the assertions used to read it straight out of `mcp.json` and
    /// `docs.json`.
    func storedSelection(id: UUID) async throws -> AttachmentSelection {
        try await store.configuration().storedSelection(for: .project(id))
    }
}
