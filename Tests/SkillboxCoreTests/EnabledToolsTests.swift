import XCTest
@testable import SkillboxCore

/// The Mac-wide "which clients do I use" setting: a switched-off client is skipped by every
/// synchronization, its files are left alone, and the projects keep it in their selection.
final class EnabledToolsTests: AgentboxTestCase {
    func testSwitchedOffClientIsLeftAloneUntilSwitchedBackOn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        for id in ["first", "second"] {
            let source = root.appending(path: "source/\(id)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try id.write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: root.appending(path: "source/first").path)
        _ = try await service.addLocal(path: root.appending(path: "source/second").path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude, .codex])
        try await service.configureProject(id: project.id, skillIDs: ["first"], tags: [])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .stdio, command: "npx"))
        try await service.setMCPServers(projectID: project.id, serverIDs: try await service.mcpConfiguration().servers.map(\.id), tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let codexConfig = projectURL.appending(path: ".codex/config.toml")
        let before = try String(contentsOf: codexConfig, encoding: .utf8)

        try await service.setEnabledTools([.claude])
        try await service.configureProject(id: project.id, skillIDs: ["first", "second"], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        // Neither written nor removed: odznaczenie w projekcie usuwa pliki, wyłączenie w ustawieniach nie.
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills/first/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills/second").path))
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/second/SKILL.md").path))
        let status = try await service.projectStatuses().first { $0.projectID == project.id }
        XCTAssertEqual(status?.state, .synced, "wyłączony klient nie może wisieć jako zaległa zmiana")
        // The project's own record still names the client, so an editor saving it cannot drop it.
        let stored = try await service.storedProjects().first { $0.id == project.id }
        XCTAssertEqual(stored?.tools, [.claude, .codex])

        try await service.setEnabledTools([.claude, .codex])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills/second/SKILL.md").path))
    }

    func testUnsyncStillRemovesFilesOfSwitchedOffClient() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo"), projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude, .codex])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)

        try await service.setEnabledTools([.claude])
        _ = try await service.unsyncProject(id: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills/demo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/demo").path))
    }

    func testGlobalSyncLeavesSwitchedOffClientDirectoryAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"), home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "notes".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode], skillIDs: ["notes"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)

        try await service.setEnabledTools([.claude, .codex])
        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode]), for: .global)
        let previews = try await service.previewGlobalSync(home: home)
        XCTAssertEqual(previews.map(\.tool), [.claude])
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/notes").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: ".config/opencode/skills/notes/SKILL.md").path))
    }

    func testEveryClientOnLeavesNoSettingBehindAndNoneIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let enabledByDefault = try await service.enabledTools()
        XCTAssertEqual(enabledByDefault, Tool.allCases)
        try await service.setEnabledTools([.codex])
        try await service.setEnabledTools(Tool.allCases)
        let file = try String(contentsOf: root.appending(path: "projects.local.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("enabledTools"), file)
        await XCTAssertThrowsErrorAsync(try await service.setEnabledTools([]))
    }

    func testCommandLineDefaultsToEnabledClientsAndRefusesOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))

        let listed = try await AgentboxCommand.run(["tools", "set", "claude,codex"], service: service)
        XCTAssertEqual(listed, ["✓ claude", "✓ codex", "– opencode", "– vibe"])
        _ = try await AgentboxCommand.run(["project", "add", "app", projectURL.path], service: service)
        let tools = try await service.storedProjects().first?.tools
        XCTAssertEqual(tools, [.claude, .codex])
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["project", "add", "other", projectURL.path, "--tools", "opencode"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["project", "add", "other", projectURL.path, "--tools", "claud"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["tools", "set", "claude,nope"], service: service))
    }

    func testFolderAdoptedFromCommandLineKeepsSwitchedOffClientOfItsProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace.appending(path: "app"), withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addProject(name: "app", path: workspace.appending(path: "app").path, tools: [.claude, .vibe])
        try await service.setEnabledTools([.claude])
        _ = try await AgentboxCommand.run(["project", "root-adopt", "ws", workspace.path], service: service)
        let folder = try await service.projectRoots().first
        XCTAssertEqual(folder?.tools, [.claude, .vibe])
    }
}
