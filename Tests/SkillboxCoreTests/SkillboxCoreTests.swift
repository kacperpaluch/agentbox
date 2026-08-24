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
    func testAnalyzesClaudeBackupSeparatesSecretsWithoutInventingProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"n8n-mcp":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-one","N8N_API_URL":"http://lan:5678"}},"n8n-tailscale":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-two","N8N_API_URL":"http://tailnet:5678"}},"context7":{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"CONTEXT7_API_KEY":"secret-three"}}}"#
        let summary = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(summary.servers.count, 3)
        XCTAssertEqual(summary.secretCount, 3)
        XCTAssertNil(summary.servers.first(where: { $0.name == "n8n-mcp" })?.group)
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

    func testBackupCanRequireConfiguredRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        do {
            _ = try await service.backup(push: true, requireRemote: true)
            XCTFail("Backup wymagający remote powinien zakończyć się błędem")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("zdalnego repozytorium Git"))
        }
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

    func testSyncAllProjectsPreviewsEverythingBeforeWritingAndSyncsEveryProject() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let firstFolder = root.appending(path: "group/first")
        let secondFolder = root.appending(path: "group/second")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        for (name, folder) in [("first", firstFolder), ("second", secondFolder)] {
            let project = try await service.addProject(name: name, path: folder.path, tools: [.claude])
            try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        }

        let preview = try await service.previewAllProjectsSync()
        XCTAssertEqual(preview.map(\.project.name), ["first", "second"])
        XCTAssertTrue(preview.allSatisfy { $0.preview.skills.first?.added == ["demo"] })
        let result = try await service.syncAllProjectsTransactions()
        XCTAssertEqual(result.count, 2)
        for folder in [firstFolder, secondFolder] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: ".claude/skills/demo/SKILL.md").path))
        }
    }

    func testSyncAllProjectsDoesNotWriteWhenAnyPreviewFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let validFolder = root.appending(path: "valid")
        let missingFolder = root.appending(path: "missing")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        for (name, folder) in [("valid", validFolder), ("missing", missingFolder)] {
            let project = try await service.addProject(name: name, path: folder.path, tools: [.claude])
            try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        }
        try FileManager.default.removeItem(at: missingFolder)

        do { _ = try await service.syncAllProjectsTransactions(); XCTFail("Oczekiwano błędu podglądu") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: validFolder.appending(path: ".claude/skills/demo/SKILL.md").path))
    }

    func testLibrarySnapshotCanRestorePreviousMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "demo", tags: ["changed"])
        let snapshots = try await service.librarySnapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        _ = try await service.restoreLibrarySnapshot(named: snapshot.name)
        let restoredSkills = try await service.listSkills()
        let snapshotsAfterRestore = try await service.librarySnapshots()
        XCTAssertEqual(restoredSkills.first?.tags, [])
        XCTAssertGreaterThanOrEqual(snapshotsAfterRestore.count, 1)
    }

    func testProjectSyncBackupCanBeRestoredFromMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "version one".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "history", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "version two".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.update(skillID: "demo")
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".claude/skills/demo/SKILL.md"), encoding: .utf8), "version two")
        let backups = try await service.projectSyncBackups()
        let backup = try XCTUnwrap(backups.first)
        _ = try await service.restoreProjectSyncBackup(projectID: project.id, named: backup.name)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".claude/skills/demo/SKILL.md"), encoding: .utf8), "version one")
    }

    func testProjectSelectsMCPServersDirectlyAndByTagWithoutProfileExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "mcp-tags", path: projectURL.path, tools: [.claude])
        let direct = MCPServer(name: "n8n", transport: .http, url: "https://example.test/mcp", group: "n8n", profile: "Domyślny", tags: ["automation"])
        let tagged = MCPServer(name: "n8n-tailscale", transport: .http, url: "https://tailscale.example.test/mcp", group: "n8n", profile: "Tailscale", tags: ["private"])
        try await service.saveMCPServer(direct); try await service.saveMCPServer(tagged)
        try await service.setMCPServers(projectID: project.id, serverIDs: [direct.id], tags: ["private"])
        let previews = try await service.previewMCP(projectID: project.id)
        let preview = try XCTUnwrap(previews.first)
        XCTAssertTrue(preview.content.contains("\"n8n\""))
        XCTAssertTrue(preview.content.contains("\"n8n-tailscale\""))
    }

    func testExistingMCPFieldCanBeReclassifiedWithoutRevealingStoredSecret() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "api", transport: .http, url: "https://example.test/mcp", literalHeaders: ["Authorization": "initial"])
        try await service.saveMCPServer(server)
        var fields = try await service.managedFields(serverID: server.id)
        fields[0].classification = .secret
        fields[0].value = "dummy-secret"
        try await service.saveMCPServer(server, managedFields: fields)
        let managed = try await service.managedFields(serverID: server.id)
        var secretField = try XCTUnwrap(managed.first)
        XCTAssertTrue(secretField.hasStoredSecret); XCTAssertEqual(secretField.value, "")
        secretField.classification = .literal
        try await service.saveMCPServer(server, managedFields: [secretField])
        let config = try await service.mcpConfiguration()
        XCTAssertEqual(config.servers.first?.literalHeaders?["Authorization"], "dummy-secret")
        XCTAssertNil(config.servers.first?.secretHeaders?["Authorization"])
    }

    func testFullLocalBackupRestoresSkillsProjectsMCPAndSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "original skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        _ = try await service.addProject(name: "saved", path: projectURL.path, tools: [.claude])
        let server = MCPServer(name: "api", transport: .http, url: "https://example.test/mcp")
        try await service.saveMCPServer(server)
        try await service.saveMCPServer(server, managedFields: [MCPManagedField(location: .header, key: "Authorization", value: "dummy-secret", classification: .secret)])
        let backup = try await service.createFullBackup(applicationVersion: "test")
        try await service.deleteProject(id: (try await service.listProjects())[0].id)
        try await service.deleteMCPServer(id: server.id)
        try "changed".write(to: root.appending(path: "data/skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try await service.restoreFullBackup(named: backup.name)
        let restoredProjects = try await service.listProjects()
        XCTAssertEqual(restoredProjects.first?.name, "saved")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "data/skills/demo/SKILL.md"), encoding: .utf8), "original skill")
        let restoredMCP = try await service.mcpConfiguration()
        XCTAssertNotNil(restoredMCP.servers.first?.secretHeaders?["Authorization"])
        let secrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "data/mcp-secrets.json")))
        XCTAssertTrue(secrets.values.contains("dummy-secret"))
    }

    func testSyncRefusesToReplaceSkillDirectoryThatAgentboxDoesNotManage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        let manual = projectURL.appending(path: ".claude/skills/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "z biblioteki".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try "reczna praca".write(to: manual.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])

        // The preview must fail too, so "synchronizuj wszystko" stops before its first write.
        await XCTAssertThrowsErrorAsync(try await service.previewProjectSync(projectID: project.id))
        await XCTAssertThrowsErrorAsync(try await service.syncProject(id: project.id))
        XCTAssertEqual(try String(contentsOf: manual.appending(path: "SKILL.md"), encoding: .utf8), "reczna praca")
    }

    func testManagedSkillIsStillReplacedOnSecondSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "wersja 1".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
        _ = try await service.syncProject(id: project.id)
        try "wersja 2".write(to: root.appending(path: "data/skills/notes/SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.syncProject(id: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".claude/skills/notes/SKILL.md"), encoding: .utf8), "wersja 2")
    }

    func testSyncAllProjectsReportsSyncedFailedAndSkippedProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        var ids: [UUID] = []
        for name in ["a-first", "b-second", "c-third"] {
            let url = root.appending(path: "projects/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let project = try await service.addProject(name: name, path: url.path, tools: [.claude])
            try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
            ids.append(project.id)
        }
        // The middle project cannot be written: its skills path is occupied by a file.
        try FileManager.default.createDirectory(at: root.appending(path: "projects/b-second/.claude"), withIntermediateDirectories: true)
        try "blokada".write(to: root.appending(path: "projects/b-second/.claude/skills"), atomically: true, encoding: .utf8)

        let outcomes = try await service.syncAllProjectsTransactions()
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(outcomes[0].state, .synced)
        guard case .failed = outcomes[1].state else { return XCTFail("drugi projekt powinien zgłosić błąd") }
        XCTAssertEqual(outcomes[2].state, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "projects/a-first/.claude/skills/notes/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "projects/c-third/.claude/skills/notes").path))
    }

    func testGlobalSelectionIsPersistedAndSynchronizedIntoUserSkillDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "globalny".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "notes", tags: ["wszedzie"])
        try await service.setGlobalSelection(GlobalSkillSelection(tools: [.claude, .opencode], skillIDs: [], tags: ["wszedzie"]))

        let preview = try await service.previewGlobalSync(home: home)
        XCTAssertEqual(preview.map(\.added), [["notes"], ["notes"]])
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".claude/skills/notes/SKILL.md"), encoding: .utf8), "globalny")
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/opencode/skills/notes/SKILL.md"), encoding: .utf8), "globalny")
        // Codex was never selected, so its directory must stay untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".codex/skills").path))

        let reloaded = try await service.globalSelection()
        XCTAssertEqual(reloaded.tools, [.claude, .opencode])
        XCTAssertEqual(reloaded.tags, ["wszedzie"])

        // Deselecting removes the managed copy again.
        try await service.setGlobalSelection(GlobalSkillSelection(tools: [.claude], skillIDs: [], tags: []))
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/notes").path))
    }

    func testLibraryIsRestoredFromRemoteRepositoryWithoutTouchingLocalProjectsAndSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "zapasowy skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        // Library that plays the role of the backup repository.
        let origin = try SkillboxService(root: root.appending(path: "origin"))
        _ = try await origin.addLocal(path: source.path)
        try await origin.saveMCPServer(MCPServer(name: "api", transport: .http, url: "https://example.test/mcp"))
        _ = try await origin.backup(message: "kopia", push: false)

        // A fresh Mac: its own project and secret must survive the restore.
        let fresh = try SkillboxService(root: root.appending(path: "fresh"))
        let project = try await fresh.addProject(name: "lokalny", path: projectURL.path, tools: [.claude])
        try await fresh.saveMCPServer(MCPServer(name: "local", transport: .stdio, command: "echo"), managedFields: [
            MCPManagedField(location: .environment, key: "TOKEN", value: "dummy-secret", classification: .secret)
        ])

        _ = try await fresh.restoreLibraryFromRemote(root.appending(path: "origin").absoluteURL.absoluteString, applicationVersion: "test")

        let restoredSkills = try await fresh.listSkills().map(\.id)
        let restoredServers = try await fresh.mcpConfiguration().servers.map(\.name)
        let keptProjects = try await fresh.listProjects().map(\.id)
        let backupCount = try await fresh.fullBackups().count
        XCTAssertEqual(restoredSkills, ["notes"])
        XCTAssertEqual(try String(contentsOf: root.appending(path: "fresh/skills/notes/SKILL.md"), encoding: .utf8), "zapasowy skill")
        XCTAssertEqual(restoredServers, ["api"])
        XCTAssertEqual(keptProjects, [project.id])
        let secrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "fresh/mcp-secrets.json")))
        XCTAssertTrue(secrets.values.contains("dummy-secret"))
        XCTAssertEqual(backupCount, 1)
    }

    func testRestoreRejectsRepositoryThatIsNotAnAgentboxLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let origin = root.appending(path: "origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try "# zwykłe repo".write(to: origin.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: origin)
        try runGit(["-c", "user.email=t@t.test", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"], in: origin)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addProject(name: "zostaje", path: origin.path, tools: [.claude])
        await XCTAssertThrowsErrorAsync(try await service.restoreLibraryFromRemote(origin.absoluteURL.absoluteString, applicationVersion: "test"))
        let keptProjects = try await service.listProjects().map(\.name)
        XCTAssertEqual(keptProjects, ["zostaje"])
    }

    func testProcessRunnerRunsGitWithoutInteractivePrompts() throws {
        let environment = ProcessRunner.nonInteractiveEnvironment()
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
        XCTAssertNil(environment["GIT_ASKPASS"])
        XCTAssertTrue(environment["GIT_SSH_COMMAND"]?.contains("BatchMode=yes") == true)
        XCTAssertEqual(try ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$GIT_TERMINAL_PROMPT\""]), "0")
    }

    func testProcessRunnerStopsAProcessThatNeverFinishes() throws {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", ["-c", "sleep 30"], timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("limit"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("oczekiwano błędu", file: file, line: line) } catch {}
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
