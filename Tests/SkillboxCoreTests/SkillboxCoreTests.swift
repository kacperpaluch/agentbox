import XCTest
@testable import SkillboxCore

final class SkillboxCoreTests: XCTestCase {
    func testExistingMVPLibraryCanBeRecognizedAndOpened() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/legacy")
        let library = root.appending(path: "old-mvp-library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: Legacy\ndescription: MVP skill\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let original = try SkillboxService(root: library)
        _ = try await original.addLocal(path: source.path)

        XCTAssertTrue(SkillboxService.isExistingLibrary(at: library))
        let reopened = try SkillboxService(root: library)
        try await reopened.validateLibrary()
        let reopenedIDs = try await reopened.listSkills().map(\.id)
        XCTAssertEqual(reopenedIDs, ["legacy"])
    }

    func testGitHubTreeURLIsNormalizedToRepositoryBranchAndSubpath() {
        let value = SkillboxService.normalizeGitInput(url: "https://github.com/anthropics/skills/tree/main/skills/docx", subpath: nil, branch: nil)
        XCTAssertEqual(value.url, "https://github.com/anthropics/skills.git")
        XCTAssertEqual(value.branch, "main")
        XCTAssertEqual(value.subpath, "skills/docx")
    }
    func testDeletingSkillAndProjectCleansCatalogAssignmentsButKeepsProjectFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectFolder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "sample", path: projectFolder.path, tools: [.claude])
        try await service.configureProject(name: project.name, skillIDs: ["demo"], tags: [])
        try await service.deleteSkill(skillID: "demo")
        let skillsAfterDelete = try await service.listSkills()
        let projectsAfterSkillDelete = try await service.listProjects()
        XCTAssertTrue(skillsAfterDelete.isEmpty)
        XCTAssertTrue(projectsAfterSkillDelete.first?.skillIDs.isEmpty == true)
        try await service.deleteProject(id: project.id)
        let projectsAfterDelete = try await service.listProjects()
        XCTAssertTrue(projectsAfterDelete.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFolder.path))
    }
    func testAnalyzesClaudeBackupSeparatesSecretsAndDetectsProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"n8n-mcp":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-one","N8N_API_URL":"http://lan:5678"}},"n8n-tailscale":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-two","N8N_API_URL":"http://tailnet:5678"}},"context7":{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"CONTEXT7_API_KEY":"secret-three"}}}"#
        let summary = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(summary.servers.count, 3)
        XCTAssertEqual(summary.secretCount, 3)
        XCTAssertEqual(summary.profileGroups, ["n8n"])
        XCTAssertEqual(summary.servers.first(where: { $0.name == "n8n-mcp" })?.literalEnvironment?["N8N_API_URL"], "http://lan:5678")
        XCTAssertNotNil(summary.servers.first(where: { $0.name == "context7" })?.secretHeaders?["CONTEXT7_API_KEY"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "mcp-secrets.json").path))
    }
    func testLocalImportTagsAndProjectSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "demo", tags: ["test"])
        _ = try await service.addProject(name: "sample", path: project.path, tools: [.claude, .codex, .opencode])
        try await service.configureProject(name: "sample", skillIDs: [], tags: ["test"])
        let result = try await service.syncProject(name: "sample")
        XCTAssertEqual(result.count, 3)
        for tool in Tool.allCases { XCTAssertTrue(FileManager.default.fileExists(atPath: project.appending(path: tool.projectSkillsPath).appending(path: "demo/SKILL.md").path)) }
    }

    func testImportsMultipleSkillsFromGitSubfolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        for name in ["seo", "seo-page"] {
            let folder = repo.appending(path: "skills/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(imported.map(\.id).sorted(), ["seo", "seo-page"])
        XCTAssertEqual(imported.map(\.source.subpath).compactMap { $0 }.sorted(), ["skills/seo", "skills/seo-page"])
    }

    func testImportsSkillFromGitRepositoryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "root-skill")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: root-skill\ndescription: Demo\n---\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].id, "root-skill")
        XCTAssertNil(imported[0].source.subpath)
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        let skillsAfterReimport = try await service.listSkills()
        XCTAssertEqual(skillsAfterReimport.map(\.id), ["root-skill"])
    }

    func testBackupWorksOnEmptyLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let result = try await service.backup(push: false)
        XCTAssertEqual(result, "Utworzono lokalny commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: ".gitignore").path))
    }

    func testExistingProjectExcludeBlockIsCompletedWithSkillboxDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let info = root.appending(path: ".git/info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let old = "# Skillbox MCP configs (mogą zawierać lokalne sekrety)\n.mcp.json\n.codex/config.toml\nopencode.json\nopencode.jsonc\n"
        try old.write(to: info.appending(path: "exclude"), atomically: true, encoding: .utf8)
        try MCPRenderer.apply(previews: [], project: root)
        let updated = try String(contentsOf: info.appending(path: "exclude"), encoding: .utf8)
        XCTAssertTrue(updated.split(whereSeparator: \.isNewline).contains(".skillbox/"))
    }

    func testBackupTwiceReportsNoChangesAndIgnoresLocalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let data = root.appending(path: "data")
        let service = try SkillboxService(root: data)
        _ = try await service.addLocal(path: source.path)
        _ = try await service.backup()
        let secondBackup = try await service.backup()
        XCTAssertEqual(secondBackup, "Brak zmian")
        let ignore = try String(contentsOf: data.appending(path: ".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("projects.local.json") && ignore.contains("mcp-secrets.json"))
    }

    func testAutomaticBackupRequiresInitializationAndCommitsOnlyNewChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let beforeInitialization = try await service.automaticBackup(push: false)
        XCTAssertNil(beforeInitialization)
        _ = try await service.backup(push: false)
        try await service.setTags(skillID: "demo", tags: ["changed"])
        let changed = try await service.automaticBackup(push: false)
        let unchanged = try await service.automaticBackup(push: false)
        XCTAssertEqual(changed, "Utworzono lokalny commit")
        XCTAssertEqual(unchanged, "Brak zmian")
    }

    func testOpenCodeUsesDirectMCPMapAndMixedEnvironmentValuesSurviveImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.importMCPJSON(#"{"mixed":{"command":"npx","args":["-y","mixed"],"env":{"COUNT":3,"ENABLED":true}}}"#)
        XCTAssertEqual(imported.servers[0].literalEnvironment?["COUNT"], "3")
        XCTAssertEqual(imported.servers[0].literalEnvironment?["ENABLED"], "1")
        let project = try await service.addProject(name: "open", path: projectURL.path, tools: [.opencode])
        let preset = MCPPreset(name: "all", serverIDs: imported.servers.map(\.id))
        try await service.saveMCPPreset(preset); try await service.setMCPPresets(projectID: project.id, presetIDs: [preset.id])
        let preview = try await service.previewMCP(projectID: project.id)[0]
        let object = try JSONSerialization.jsonObject(with: Data(preview.content.utf8)) as! [String: Any]
        let mcp = object["mcp"] as! [String: Any]
        XCTAssertNotNil(mcp["mixed"])
        XCTAssertNil(mcp["servers"])
    }

    func testProcessRunnerDrainsLargeOutput() throws {
        let output = try ProcessRunner.run("/usr/bin/head", ["-c", "200000", "/dev/zero"])
        XCTAssertEqual(output.utf8.count, 200_000)
    }

    func testGoldenMCPFilesForAllToolsWithEnvironmentAndSecret() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let json = #"{"local":{"command":"npx","args":["-y","pkg"],"env":{"TOKEN":"${TOKEN}"}},"remote":{"type":"http","url":"https://example.com/mcp","headers":{"Authorization":"Bearer dummy-secret"}}}"#
        let imported = try await service.importMCPJSON(json)
        let project = try await service.addProject(name: "golden", path: projectURL.path, tools: Tool.allCases)
        let preset = MCPPreset(name: "all", serverIDs: imported.servers.map(\.id))
        try await service.saveMCPPreset(preset); try await service.setMCPPresets(projectID: project.id, presetIDs: [preset.id])
        let previews = try await service.previewMCP(projectID: project.id)
        let fixtures: [Tool: String] = [.claude: "claude-mcp.json", .codex: "codex-mcp.toml", .opencode: "opencode-mcp.json"]
        for preview in previews {
            let expectedURL = try XCTUnwrap(Bundle.module.url(forResource: fixtures[preview.tool]!, withExtension: nil, subdirectory: "Fixtures"))
            let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            XCTAssertEqual(preview.content.trimmingCharacters(in: .whitespacesAndNewlines), expected.trimmingCharacters(in: .whitespacesAndNewlines), "Niezgodny format \(preview.tool)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: "data/mcp-secrets.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMCPApplyRollsBackEarlierFileWhenLaterWriteFails() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: ".mcp.json")
        let blocker = root.appending(path: "blocker")
        try "original".write(to: first, atomically: true, encoding: .utf8)
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let previews = [
            MCPPreview(tool: .claude, file: first.path, content: "changed", added: [], removed: []),
            MCPPreview(tool: .opencode, file: blocker.appending(path: "opencode.json").path, content: "new", added: [], removed: [])
        ]
        XCTAssertThrowsError(try MCPRenderer.apply(previews: previews, project: root))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
    }

    func testDuplicateProjectAndRenamedServerAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addProject(name: "web", path: folder.path, tools: [.claude])
        do { _ = try await service.addProject(name: "WEB", path: folder.path, tools: [.codex]); XCTFail("Oczekiwano odrzucenia duplikatu") } catch {}
        let one = MCPServer(name: "one", transport: .http, url: "https://one.example")
        let two = MCPServer(name: "two", transport: .http, url: "https://two.example")
        try await service.saveMCPServer(one); try await service.saveMCPServer(two)
        var renamed = two; renamed.name = "one"
        do { try await service.saveMCPServer(renamed); XCTFail("Oczekiwano konfliktu nazwy") } catch {}
    }

    func testMCPPresetPreviewAndThreeToolSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".codex"), withIntermediateDirectories: true)
        try "{\"custom\":true}".write(to: projectURL.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        try "{\n// existing user setting\n\"theme\": \"dark\",\n}".write(to: projectURL.appending(path: "opencode.jsonc"), atomically: true, encoding: .utf8)
        try "model = \"test\"\n".write(to: projectURL.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "mcp", path: projectURL.path, tools: Tool.allCases)
        let server = MCPServer(name: "context7", transport: .stdio, command: "npx", arguments: ["-y", "context7"], environment: ["CONTEXT7_TOKEN": "CONTEXT7_TOKEN"])
        try await service.saveMCPServer(server)
        let preset = MCPPreset(name: "Web", serverIDs: [server.id])
        try await service.saveMCPPreset(preset)
        try await service.setMCPPresets(projectID: project.id, presetIDs: [preset.id])
        let previews = try await service.previewMCP(projectID: project.id)
        XCTAssertEqual(previews.count, 3)
        _ = try await service.syncMCP(projectID: project.id)
        let claude = try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8)
        let codex = try String(contentsOf: projectURL.appending(path: ".codex/config.toml"), encoding: .utf8)
        let opencode = try String(contentsOf: projectURL.appending(path: "opencode.jsonc"), encoding: .utf8)
        XCTAssertTrue(claude.contains("context7") && claude.contains("custom"))
        XCTAssertTrue(codex.contains("[mcp_servers.context7]") && codex.contains("model = \"test\""))
        XCTAssertTrue(opencode.contains("context7") && opencode.contains("theme"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/mcp-manifest.json").path))

        try await service.saveMCPPreset(MCPPreset(id: preset.id, name: preset.name, serverIDs: []))
        _ = try await service.syncMCP(projectID: project.id)
        let claudeAfterRemoval = try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8)
        XCTAssertFalse(claudeAfterRemoval.contains("context7"))
        XCTAssertTrue(claudeAfterRemoval.contains("custom"))
    }

    func testMCPConflictDoesNotOverwriteManualServer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let manual = "{\"mcpServers\":{\"context7\":{\"command\":\"manual\"}}}"
        try manual.write(to: projectURL.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "conflict", path: projectURL.path, tools: [.claude])
        let server = MCPServer(name: "context7", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        let preset = MCPPreset(name: "Web", serverIDs: [server.id])
        try await service.saveMCPPreset(preset)
        try await service.setMCPPresets(projectID: project.id, presetIDs: [preset.id])
        do { _ = try await service.previewMCP(projectID: project.id); XCTFail("Oczekiwano konfliktu") }
        catch let error as SkillboxError { XCTAssertTrue(error.localizedDescription.contains("Konflikt MCP")) }
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8), manual)
    }

    func testImportClassificationCanBeOverriddenByUser() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"custom":{"command":"tool","env":{"CREDENTIAL":"hidden-value","TOKEN_LIMIT":"4096"}}}"#
        let analyzed = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(analyzed.fields.first(where: { $0.key == "CREDENTIAL" })?.classification, .literal)
        XCTAssertEqual(analyzed.fields.first(where: { $0.key == "TOKEN_LIMIT" })?.classification, .secret)
        let overrides: [String: MCPValueClassification] = [
            "custom|environment|CREDENTIAL": .secret,
            "custom|environment|TOKEN_LIMIT": .literal
        ]
        let imported = try await service.importMCPJSON(json, classifications: overrides)
        let server = try XCTUnwrap(imported.servers.first)
        XCTAssertNotNil(server.secretEnvironment?["CREDENTIAL"])
        XCTAssertEqual(server.literalEnvironment?["TOKEN_LIMIT"], "4096")
        let secrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "mcp-secrets.json")))
        XCTAssertEqual(secrets["mcp/custom/env/CREDENTIAL"], "hidden-value")
    }

    func testProjectTransactionRollsBackSkillsWhenLaterToolFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "version one".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "rollback", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        _ = try await service.syncProject(id: project.id)
        try "version two".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.update(skillID: "demo")

        var changedProject = project; changedProject.tools = [.claude, .codex]
        try await service.updateProject(changedProject)
        try "blocks directory creation".write(to: projectURL.appending(path: ".codex"), atomically: true, encoding: .utf8)
        do { _ = try await service.syncProjectTransaction(projectID: project.id); XCTFail("Oczekiwano błędu zapisu") } catch {}
        let restored = try String(contentsOf: projectURL.appending(path: ".claude/skills/demo/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(restored, "version one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "data/.agentbox-snapshots").path))
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
