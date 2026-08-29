import XCTest
@testable import SkillboxCore

/// `AttachmentSelection` is a façade over three storage shapes that predate it — skills inline on
/// `Project`/`ProjectRoot`, servers and docs in side maps, the global choice as loose fields on
/// `LocalConfiguration`. These tests pin the property that makes it safe to build on: reading a
/// place and writing the result straight back changes nothing, for every kind of place.
final class AttachmentSelectionTests: AgentboxTestCase {
    /// Builds a library with one skill, one server, one document and one standalone project.
    private func makeService() async throws -> (SkillboxService, URL, Project, MCPServer) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "demo", tags: ["web"])
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo", tags: ["web"]))
        let server = try await service.mcpConfiguration().servers.first { $0.name == "probe" }!
        _ = try await service.createDoc(id: "zasady", name: "Zasady", tags: ["web"], content: "# Zasady\n")

        let project = try await service.addProject(
            Project(name: "app", path: projectURL.path, tools: [.claude], skillIDs: ["demo"]),
            serverIDs: [server.id], serverTags: [], docIDs: ["zasady"], docTags: []
        )
        return (service, root, project, server)
    }

    func testSelectionRoundTripsForAStandaloneProject() async throws {
        let (service, _, project, server) = try await makeService()

        let before = try await service.selection(for: .project(project.id))
        XCTAssertEqual(before.tools, [.claude])
        XCTAssertEqual(before.skillIDs, ["demo"])
        XCTAssertEqual(before.serverIDs, [server.id])
        XCTAssertEqual(before.docIDs, ["zasady"])

        try await service.setSelection(before, for: .project(project.id))
        let after = try await service.selection(for: .project(project.id))
        XCTAssertEqual(before, after)
    }

    func testSelectionRoundTripsForAParentFolderAndItsProjectsInheritIt() async throws {
        let (service, root, _, server) = try await makeService()
        let workspace = root.appending(path: "workspace")
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true)
        }
        let folder = try await service.addProjectRoot(
            ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude, .codex], skillIDs: ["demo"]),
            folders: [workspace.appending(path: "alpha").path, workspace.appending(path: "beta").path],
            serverIDs: [server.id], serverTags: [], docIDs: ["zasady"], docTags: []
        )

        let before = try await service.storedSelection(for: .root(folder.id))
        XCTAssertEqual(Set(before.tools), Set([.claude, .codex]))
        XCTAssertEqual(before.serverIDs, [server.id])
        XCTAssertEqual(before.docIDs, ["zasady"])

        try await service.setSelection(before, for: .root(folder.id))
        let afterFolder = try await service.storedSelection(for: .root(folder.id))
        XCTAssertEqual(before, afterFolder)

        // A project that follows the folder reports the folder's attachments as its effective ones…
        let alpha = try await service.listProjects().first { $0.name == "alpha" }!
        let effective = try await service.selection(for: .project(alpha.id))
        XCTAssertEqual(effective.skillIDs, ["demo"])
        XCTAssertEqual(effective.serverIDs, [server.id])
        XCTAssertEqual(effective.docIDs, ["zasady"])

        // …while its own record stays empty, so opening an editor cannot silently copy the folder's
        // values onto the project and detach it from the folder on the next save.
        let stored = try await service.storedSelection(for: .project(alpha.id))
        XCTAssertTrue(stored.isEmpty, "projekt dziedziczący nie powinien mieć własnego zapisu: \(stored)")
    }

    func testSelectionRoundTripsForTheGlobalTarget() async throws {
        let (service, _, _, _) = try await makeService()

        try await service.setSelection(
            AttachmentSelection(tools: [.claude, .opencode], skillIDs: ["demo"], skillTags: ["Wszedzie"]),
            for: .global
        )
        let stored = try await service.selection(for: .global)
        XCTAssertEqual(Set(stored.tools), Set([.claude, .opencode]))
        XCTAssertEqual(stored.skillIDs, ["demo"])
        XCTAssertEqual(stored.skillTags, ["wszedzie"], "tagi powinny być znormalizowane tak jak wszędzie indziej")

        try await service.setSelection(stored, for: .global)
        let reread = try await service.selection(for: .global)
        XCTAssertEqual(stored, reread)
    }

    /// This Mac is a place like any other, so the tag-owns-what-it-pulls-in rule applies to it too.
    /// It used not to: the global choice had its own save path that skipped pruning entirely.
    func testGlobalTargetPrunesRedundantPicksLikeAProject() async throws {
        let (service, _, _, _) = try await makeService()
        try await service.setSelection(
            AttachmentSelection(tools: [.claude], skillIDs: ["demo"], skillTags: ["web"]),
            for: .global
        )
        let stored = try await service.selection(for: .global)
        XCTAssertEqual(stored.skillIDs, [], "tag `web` już obejmuje ten skill")
        XCTAssertEqual(stored.skillTags, ["web"])
    }

    /// The façade must not become a second, disagreeing way to write the same thing: what it stores
    /// has to be exactly what the per-type methods behind it store.
    func testFacadeWritesTheSameRecordsAsThePerTypeMethods() async throws {
        let (service, _, project, server) = try await makeService()

        try await service.setSelection(
            AttachmentSelection(tools: [.claude, .codex], skillIDs: ["demo"], serverIDs: [server.id], docIDs: ["zasady"]),
            for: .project(project.id)
        )

        let stored = try await service.storedProjects().first { $0.id == project.id }!
        XCTAssertEqual(Set(stored.tools), Set([.claude, .codex]))
        XCTAssertEqual(stored.skillIDs, ["demo"])
        let record = try await service.storedSelection(id: project.id)
        XCTAssertEqual(record.serverIDs, [server.id])
        XCTAssertEqual(record.docIDs, ["zasady"])
    }

    /// Selecting a tag already covers every skill, server and document carrying it, so the redundant
    /// individual picks are dropped on save — the façade must keep that pruning, not bypass it.
    func testFacadeKeepsTagPruningOnSave() async throws {
        let (service, _, project, server) = try await makeService()

        try await service.setSelection(
            AttachmentSelection(
                tools: [.claude],
                skillIDs: ["demo"], skillTags: ["web"],
                serverIDs: [server.id], serverTags: ["web"],
                docIDs: ["zasady"], docTags: ["web"]
            ),
            for: .project(project.id)
        )

        let stored = try await service.selection(for: .project(project.id))
        XCTAssertEqual(stored.skillIDs, [], "tag `web` już obejmuje ten skill")
        XCTAssertEqual(stored.serverIDs, [], "tag `web` już obejmuje ten serwer")
        XCTAssertEqual(stored.docIDs, [], "tag `web` już obejmuje ten dokument")
        XCTAssertEqual(stored.skillTags, ["web"])
    }

    func testProjectDefaultsPersistAllAttachmentKindsWithoutChangingExistingProjects() async throws {
        let (service, root, project, server) = try await makeService()
        let defaults = AttachmentSelection(
            tools: [.claude, .codex],
            skillIDs: ["demo"],
            serverIDs: [server.id],
            docIDs: ["zasady"]
        )

        try await service.setProjectDefaults(defaults)
        let savedDefaults = try await service.projectDefaults()
        XCTAssertEqual(savedDefaults, defaults)

        // The template is only a starting point for future editors; it never rewrites a project
        // that was already saved before the user changed defaults.
        let existing = try await service.selection(for: .project(project.id))
        XCTAssertEqual(existing.tools, [.claude])
        XCTAssertEqual(existing.serverIDs, [server.id])

        let reopened = try SkillboxService(root: root.appending(path: "data"))
        let reopenedDefaults = try await reopened.projectDefaults()
        XCTAssertEqual(reopenedDefaults, defaults)
    }
}
