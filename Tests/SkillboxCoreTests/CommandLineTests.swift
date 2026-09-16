import XCTest
@testable import SkillboxCore

final class CommandLineTests: AgentboxTestCase {
    /// A project inheriting a folder has no MCP selection of its own, so the CLI must be able to
    /// address the folder — and must say so, with the exact command, when it refuses the project.
    func testCommandLineTargetsFolderForGlobalServersAndExplainsInheritedProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let home = root.appending(path: "home")
        let folder = root.appending(path: "praca")
        try FileManager.default.createDirectory(at: folder.appending(path: "sklep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.apple-mail]\ncommand = \"npx\"\n".write(to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await AgentboxCommand.run(["project", "root-add", "praca", folder.path, "--tools", "codex", "--folders", "sklep"], service: service)
        let projects = try await service.listProjects()
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.name, "sklep")

        // The project follows the folder, so targeting it directly is refused — with directions.
        do {
            _ = try await AgentboxCommand.run(["mcp", "global", "disable", "sklep", "codex", "apple-mail"], service: service)
            XCTFail("Oczekiwano odmowy dla projektu dziedziczącego")
        } catch let error as SkillboxError {
            XCTAssertTrue(error.localizedDescription.contains("praca"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("--folder"), error.localizedDescription)
        }

        // `--folder` records the opt-out on the folder itself. (`list` is not asserted here: it
        // reads the real ~/.codex/config.toml, which a test cannot point elsewhere.)
        _ = try await AgentboxCommand.run(["mcp", "global", "disable", "praca", "codex", "apple-mail", "--folder"], service: service)
        let roots = try await service.projectRoots()
        let folderRoot = try XCTUnwrap(roots.first)
        let storedOptOut = try await service.disabledGlobalServers(selectionID: folderRoot.id)
        XCTAssertEqual(storedOptOut, [Tool.codex: ["apple-mail"]])
        // The folder's choice is what the inheriting project actually synchronizes.
        _ = try await service.syncMCP(projectID: project.id)
        let written = try String(contentsOf: folder.appending(path: "sklep/.codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(written.contains("[mcp_servers.apple-mail]") && written.contains("enabled = false"), written)

        _ = try await AgentboxCommand.run(["mcp", "global", "enable", "praca", "codex", "apple-mail", "--folder"], service: service)
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "sklep/.codex/config.toml").path))
    }
    func testCommandLineManagesGlobalServerDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let empty = try await AgentboxCommand.run(["mcp", "global", "defaults"], service: service)
        XCTAssertTrue(empty.joined().contains("nie startują"), empty.description)
        _ = try await AgentboxCommand.run(["mcp", "global", "defaults", "add", "codex", "apple_mail"], service: service)
        let listed = try await AgentboxCommand.run(["mcp", "global", "defaults"], service: service)
        XCTAssertEqual(listed, ["default\tcodex\tapple_mail"])
        _ = try await AgentboxCommand.run(["mcp", "global", "defaults", "remove", "codex", "apple_mail"], service: service)
        let afterRemove = try await service.defaultDisabledGlobalServers()
        XCTAssertEqual(afterRemove, [:])
    }
    func testCommandLineListsProjectStatusesAndSynchronizes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))

        _ = try await AgentboxCommand.run(["add", source.path], service: service)
        _ = try await AgentboxCommand.run(["project", "add", "app", projectURL.path, "--tools", "claude"], service: service)
        _ = try await AgentboxCommand.run(["project", "set", "app", "--skills", "notes"], service: service)

        let pending = try await AgentboxCommand.run(["project", "status"], service: service)
        XCTAssertTrue(pending[0].contains("●"), pending[0])

        let dry = try await AgentboxCommand.run(["sync", "project", "app", "--dry-run"], service: service)
        XCTAssertTrue(dry.contains { $0.contains("+1") }, "\(dry)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes").path), "--dry-run nie może zapisywać")

        _ = try await AgentboxCommand.run(["sync", "all"], service: service)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes/SKILL.md").path))
        let synced = try await AgentboxCommand.run(["project", "status"], service: service)
        XCTAssertTrue(synced[0].contains("✓"), synced[0])
    }
    func testCommandLineAdoptsSkillsOnlyWithConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let manual = projectURL.appending(path: ".claude/skills/reczny")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "moje".write(to: manual.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await AgentboxCommand.run(["project", "add", "app", projectURL.path, "--tools", "claude"], service: service)

        let listed = try await AgentboxCommand.run(["project", "adopt", "app"], service: service)
        XCTAssertTrue(listed.contains { $0.contains("reczny") }, "\(listed)")
        let stillEmpty = try await service.listSkills()
        XCTAssertTrue(stillEmpty.isEmpty, "bez --yes nic nie jest kopiowane")

        _ = try await AgentboxCommand.run(["project", "adopt", "app", "--yes"], service: service)
        let adopted = try await service.listSkills().map(\.id)
        XCTAssertEqual(adopted, ["reczny"])
    }
    func testCommandLineReportsUnknownProjectAsError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["sync", "project", "nieistniejacy"], service: service))
    }
    /// `delete`, `project remove` and `mcp server remove` are the CLI's counterpart to the GUI's
    /// only-in-app delete buttons — a CLI-first workflow should not need to open the app just to
    /// remove something it can already create.
    func testCommandLineDeletesSkillsProjectsAndMCPServers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))

        _ = try await AgentboxCommand.run(["add", source.path], service: service)
        let addedSkills = try await service.listSkills().map(\.id)
        XCTAssertEqual(addedSkills, ["notes"])

        _ = try await AgentboxCommand.run(["mcp", "server", "add", "context7", "--command", "npx"], service: service)
        let addedServers = try await service.mcpConfiguration().servers.map(\.name)
        XCTAssertEqual(addedServers, ["context7"])
        _ = try await AgentboxCommand.run(["mcp", "server", "remove", "context7"], service: service)
        let serversAfterRemoval = try await service.mcpConfiguration().servers
        XCTAssertTrue(serversAfterRemoval.isEmpty)
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["mcp", "server", "remove", "nieistniejacy"], service: service))

        _ = try await AgentboxCommand.run(["project", "add", "app", projectURL.path, "--tools", "claude"], service: service)
        _ = try await AgentboxCommand.run(["project", "set", "app", "--skills", "notes"], service: service)
        _ = try await AgentboxCommand.run(["sync", "project", "app"], service: service)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes").path))

        _ = try await AgentboxCommand.run(["project", "remove", "app", "--clean"], service: service)
        let projectsAfterRemoval = try await service.listProjects()
        XCTAssertTrue(projectsAfterRemoval.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes").path), "--clean sprząta pliki w folderze projektu")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path), "usunięcie projektu nigdy nie usuwa jego folderu")

        _ = try await AgentboxCommand.run(["delete", "notes"], service: service)
        let skillsAfterDeletion = try await service.listSkills()
        XCTAssertTrue(skillsAfterDeletion.isEmpty)
    }

    /// Plugins were the one thing `sync` and `refresh` installed but nothing outside the app could
    /// choose. A scripted setup has to be able to define one and point a project at it.
    func testPluginCommandsDefineChooseAndRemoveFromTheTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "sklep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await AgentboxCommand.run(["project", "add", "sklep", folder.path, "--tools", "claude"], service: service)

        let empty = try await AgentboxCommand.run(["plugin", "list"], service: service)
        XCTAssertEqual(empty, ["Biblioteka nie ma jeszcze definicji pluginów"])

        _ = try await AgentboxCommand.run(["plugin", "add", "SEO", "claude-seo@vendor", "--marketplace", "vendor/claude-seo"], service: service)
        let listed = try await AgentboxCommand.run(["plugin", "list"], service: service)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].contains("claude-seo@vendor"), listed[0])
        XCTAssertTrue(listed[0].contains("nieprzypisany"), "dopóki nikt go nie wybrał: \(listed[0])")

        // Chosen by the library name, because a UUID is not something anyone types.
        _ = try await AgentboxCommand.run(["plugin", "assign", "sklep", "--plugins", "SEO"], service: service)
        let assigned = try await AgentboxCommand.run(["plugin", "list"], service: service)
        XCTAssertTrue(assigned[0].contains("1 projekt"), assigned[0])
        let projects = try await service.listProjects()
        let selected = try await service.selectedClaudePluginIDs(projectID: try XCTUnwrap(projects.first).id)
        XCTAssertEqual(selected.count, 1)

        // The project's own preview is what synchronization acts on, so the choice has to reach it.
        let preview = try await service.previewProjectSync(projectID: try XCTUnwrap(projects.first).id)
        XCTAssertEqual(preview.missingPlugins.map(\.plugin), ["claude-seo@vendor"])

        let removal = try await AgentboxCommand.run(["plugin", "remove", "SEO"], service: service)
        XCTAssertTrue(removal[0].contains("1 projekt"), "usunięcie mówi, kogo dotyczy: \(removal[0])")
        let afterRemoval = try await service.selectedClaudePluginIDs(projectID: try XCTUnwrap(projects.first).id)
        XCTAssertTrue(afterRemoval.isEmpty, "definicja znika też z wyboru projektu")
    }

    func testPluginCommandRejectsAnUnknownScopeAndAnUnknownName() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))

        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["plugin", "add", "SEO", "seo@vendor", "--scope", "globalny"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["plugin", "remove", "nie-ma-takiego"], service: service))
        let lines = try await AgentboxCommand.run(["plugin"], service: service)
        XCTAssertTrue(lines[0].hasPrefix("Użycie: agentbox plugin"), lines[0])
    }


    private func cliLibrary() throws -> (SkillboxService, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try SkillboxService(root: root.appending(path: "data")), root)
    }

    /// A preview is a preview: the saved selection — exclusions included — stays as it was.
    func testGlobalDryRunDoesNotSaveTheSelection() async throws {
        let (service, root) = try cliLibrary()
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await AgentboxCommand.run(["add", source.path], service: service)
        let saved = AttachmentSelection(tools: [.claude], skillTags: ["x"], excludedSkillIDs: ["inny"])
        try await service.setSelection(saved, for: .global)
        let selections = root.appending(path: "data/selections.json")
        let before = try Data(contentsOf: selections)

        let lines = try await AgentboxCommand.run(["sync", "global", "--skills", "notes", "--dry-run"], service: service)
        XCTAssertTrue(lines.contains { $0.contains("+1") }, "\(lines)")
        XCTAssertEqual(try Data(contentsOf: selections), before)

        _ = try await service.previewGlobalSync()
        let kept = try await service.storedSelection(for: .global)
        XCTAssertEqual(kept.excludedSkillIDs, ["inny"])
    }

    func testMCPAssignWithAnUnknownNameChangesNothing() async throws {
        let (service, root) = try cliLibrary()
        let folder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await AgentboxCommand.run(["project", "add", "app", folder.path, "--tools", "claude"], service: service)
        _ = try await AgentboxCommand.run(["mcp", "server", "add", "context7", "--url", "https://example.test/mcp"], service: service)
        _ = try await AgentboxCommand.run(["mcp", "assign", "app", "--servers", "context7"], service: service)
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["mcp", "assign", "app", "--servers", "contex7"], service: service))
        let project = try await service.storedProjects().first { $0.name == "app" }
        let selection = try await service.storedSelection(for: .project(try XCTUnwrap(project).id))
        XCTAssertEqual(selection.serverIDs.count, 1, "literówka nie czyści przypisania")
    }

    /// Automation reads the exit status: a rolled-back project is a failure even though the command
    /// printed its report.
    func testSyncAllWithAFailedProjectIsAPartialFailure() async throws {
        let (service, root) = try cliLibrary()
        let folder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await AgentboxCommand.run(["project", "add", "app", folder.path, "--tools", "claude"], service: service)
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await AgentboxCommand.run(["add", source.path], service: service)
        _ = try await AgentboxCommand.run(["project", "set", "app", "--skills", "notes"], service: service)
        // The plan can be made; the write cannot.
        let locked = folder.appending(path: ".claude")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try await AgentboxCommand.run(["sync", "all"], service: service)
            XCTFail("oczekiwano PartialFailure")
        } catch let failure as AgentboxCommand.PartialFailure {
            XCTAssertTrue(failure.lines.contains { $0.contains("app") }, "\(failure.lines)")
        }
    }
}
