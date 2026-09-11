import XCTest
@testable import SkillboxCore

final class ProjectConfigurationTests: AgentboxTestCase {
    func testExplainsInheritedTagsExclusionsDefinitionsAndActualDrift() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace"), folder = workspace.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "library"))
        for id in ["included", "excluded", "direct"] { _ = try await service.createSkill(id: id, content: "original", tags: id == "direct" ? [] : ["Swift"]) }
        let server = MCPServer(name: "demo", transport: .stdio, command: "echo", tags: ["swift"])
        let disabled = MCPServer(name: "disabled", transport: .stdio, command: "echo", enabled: false, tags: ["swift"])
        try await service.saveMCPServer(server); try await service.saveMCPServer(disabled)
        let doc = try await service.createDoc(id: "rules", content: "rules")
        let selection = AttachmentSelection(tools: [.claude], skillIDs: ["direct"], skillTags: ["SWIFT"], excludedSkillIDs: ["excluded"], serverTags: ["swift"], docIDs: [doc.id])
        let parent = try await service.addProjectRoot(ProjectRoot(name: "Workspace", path: workspace.path), folders: [folder.path], selection: selection)
        let projects = try await service.listProjects()
        let project = try XCTUnwrap(projects.first)

        let before = try await service.projectConfiguration(projectID: project.id)
        XCTAssertEqual(before.inheritedRoot?.id, parent.id)
        XCTAssertTrue(before.problems.isEmpty, "\(before.problems)")
        let included = try XCTUnwrap(before.items.first { $0.reference == .skill("included") })
        XCTAssertEqual(included.state, "Do dodania")
        XCTAssertTrue(included.reason.contains("Workspace"))
        XCTAssertTrue(included.reason.lowercased().contains("tag #swift"))
        XCTAssertTrue(before.items.first { $0.reference == .skill("direct") }?.reason.contains("bezpośredni") == true)
        XCTAssertEqual(before.items.first { $0.reference == .skill("excluded") }?.state, "Wykluczony")
        XCTAssertEqual(before.items.first { $0.reference == .server(disabled.id) }?.state, "Wyłączony w bibliotece")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: ".claude").path), "wyjaśnienie tylko odczytuje")

        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "project change".write(to: folder.appending(path: ".claude/skills/included/SKILL.md"), atomically: true, encoding: .utf8)
        let after = try await service.projectConfiguration(projectID: project.id)
        let drifted = try XCTUnwrap(after.items.first { $0.reference == .skill("included") })
        XCTAssertEqual(drifted.state, "Zmiana w projekcie")
        XCTAssertEqual(drifted.changes.first { $0.path == "SKILL.md" }?.oldText, "project change")
        XCTAssertEqual(after.items.first { $0.reference == .skill("direct") }?.state, "Aktualny")
        XCTAssertEqual(after.items.first { $0.reference == .server(server.id) }?.state, "Aktualny")
        XCTAssertEqual(after.items.first { $0.reference == .document(doc.id) }?.state, "Aktualny")

        let output = try await AgentboxCommand.run(["project", "explain", project.name], service: service)
        XCTAssertTrue(output.contains { $0.contains("Zmiana w projekcie") })
    }

    func testBlockedProjectStillExplainsSelectionAndOwnSettingsDoNotClaimInheritance() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "library"))
        _ = try await service.createSkill(id: "demo", content: "library")
        let project = try await service.addProject(Project(name: "Own", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        let unmanaged = folder.appending(path: ".claude/skills/demo")
        try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: true)
        try "user's own".write(to: unmanaged.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let report = try await service.projectConfiguration(projectID: project.id)
        XCTAssertNil(report.inheritedRoot)
        XCTAssertFalse(report.problems.isEmpty)
        XCTAssertTrue(report.items.first?.reason.contains("Own") == true)
        XCTAssertTrue(report.items.first?.state.contains("Zablokowany") == true)
        XCTAssertEqual(try String(contentsOf: unmanaged.appending(path: "SKILL.md"), encoding: .utf8), "user's own")
    }

    func testRemovedSkillsRemainVisibleUntilSynchronization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "library"))
        _ = try await service.createSkill(id: "demo", content: "library")
        let project = try await service.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try await service.setSelection(AttachmentSelection(tools: [.claude]), for: .project(project.id))
        let report = try await service.projectConfiguration(projectID: project.id)
        XCTAssertEqual(report.items.first { $0.name == "demo" }?.state, "Do usunięcia")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: ".claude/skills/demo/SKILL.md").path))
    }
}
