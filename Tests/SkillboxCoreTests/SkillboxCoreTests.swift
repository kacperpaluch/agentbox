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

    /// Presets were removed as a feature in 0.3.1, but `mcp.json` written by older versions can
    /// still carry `presets`/`projectPresetIDs` — the only thing resolving a project's servers.
    /// Opening that library must not silently drop its MCP assignment.
    func testLegacyMCPPresetsAreMigratedToDirectServerAssignmentOnLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectID = UUID().uuidString
        let presetID = UUID().uuidString
        let serverID = UUID().uuidString
        let alreadyDirectServerID = UUID().uuidString
        let legacyJSON = """
        {
          "version": 1,
          "servers": [{"id": "\(serverID)", "name": "context7", "transport": "stdio", "command": "npx", "arguments": [], "url": "", "environment": {}, "headers": {}, "enabled": true}],
          "presets": [{"id": "\(presetID)", "name": "seo", "serverIDs": ["\(serverID)"]}],
          "projectPresetIDs": {"\(projectID)": ["\(presetID)"]},
          "projectServerIDs": {"\(projectID)": ["\(alreadyDirectServerID)"]}
        }
        """
        try legacyJSON.write(to: root.appending(path: "mcp.json"), atomically: true, encoding: .utf8)

        let service = try SkillboxService(root: root)
        let config = try await service.mcpConfiguration()
        let assigned = Set(config.projectServerIDs?[projectID] ?? [])
        XCTAssertEqual(assigned, [UUID(uuidString: serverID)!, UUID(uuidString: alreadyDirectServerID)!])

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "mcp.json"))) as! [String: Any]
        XCTAssertNil(raw["presets"])
        XCTAssertNil(raw["projectPresetIDs"])
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
    func testAnalyzesClaudeBackupSeparatesSecretsFromLiteralValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"n8n-mcp":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-one","N8N_API_URL":"http://lan:5678"}},"n8n-tailscale":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-two","N8N_API_URL":"http://tailnet:5678"}},"context7":{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"CONTEXT7_API_KEY":"secret-three"}}}"#
        let summary = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(summary.servers.count, 3)
        XCTAssertEqual(summary.secretCount, 3)
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
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills").imported
        XCTAssertEqual(imported.map(\.id).sorted(), ["seo", "seo-page"])
        XCTAssertEqual(imported.map(\.source.subpath).compactMap { $0 }.sorted(), ["skills/seo", "skills/seo-page"])
    }

    func testGitImportSkipsConflictingCandidateButSavesTheRestOfTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        for name in ["conflict", "seo-a", "seo-b"] {
            let folder = repo.appending(path: "skills/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        // A local, unrelated skill already occupies the id one of the repo's candidates wants.
        let local = root.appending(path: "local/conflict")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "---\nname: conflict\ndescription: Local\n---\n".write(to: local.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: local.path)

        let result = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(result.imported.map(\.id).sorted(), ["seo-a", "seo-b"])
        XCTAssertEqual(result.skipped.map(\.id), ["conflict"])
        let afterSkills = try await service.listSkills()
        XCTAssertEqual(afterSkills.map(\.id).sorted(), ["conflict", "seo-a", "seo-b"])
        // The pre-existing local skill was left alone, not overwritten by the repo's copy.
        XCTAssertEqual(afterSkills.first { $0.id == "conflict" }?.source.kind, .local)
    }

    func testReimportingRepositoryWithDifferentlyFormattedURLIsStillRecognizedAsTheSameSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        // Named with a trailing ".git" so the two ways of referring to it below — with and without
        // that suffix — are both real, clonable paths, mirroring GitHub's "Copy" URL (with `.git`)
        // versus the address-bar URL (without it) for the same repository.
        let repo = root.appending(path: "demo.git")
        let alias = root.appending(path: "demo")
        let folder = repo.appending(path: "skills/one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: one\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))

        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        // Re-adding via the alias without ".git" must update in place, not throw a duplicate — it
        // is the same repository, just typed differently.
        let result = try await service.addGitCollection(url: alias.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(result.imported.map(\.id), ["one"])
        XCTAssertTrue(result.skipped.isEmpty)
        let ids = try await service.listSkills().map(\.id)
        XCTAssertEqual(ids, ["one"])
    }

    func testImportsSkillFromGitRepositoryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "root-skill")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: root-skill\ndescription: Demo\n---\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString).imported
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
        try await service.setMCPServers(projectID: project.id, serverIDs: imported.servers.map(\.id), tags: [])
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
        try await service.setMCPServers(projectID: project.id, serverIDs: imported.servers.map(\.id), tags: [])
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

    func testAddMCPServerTagsMergesWithExistingAndNormalizesCase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let one = MCPServer(name: "one", transport: .http, url: "https://one.example", tags: ["seo"])
        let two = MCPServer(name: "two", transport: .http, url: "https://two.example")
        try await service.saveMCPServer(one); try await service.saveMCPServer(two)
        try await service.addMCPServerTags(serverIDs: [one.id, two.id], tags: ["Audit", "seo"])
        let servers = try await service.mcpConfiguration().servers
        XCTAssertEqual(servers.first { $0.id == one.id }?.tags?.sorted(), ["audit", "seo"])
        XCTAssertEqual(servers.first { $0.id == two.id }?.tags?.sorted(), ["audit", "seo"])
        await XCTAssertThrowsErrorAsync(try await service.addMCPServerTags(serverIDs: [UUID()], tags: ["x"]))
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

    func testDirectMCPAssignmentPreviewAndThreeToolSync() async throws {
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
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])
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

        try await service.setMCPServers(projectID: project.id, serverIDs: [], tags: [])
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
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])
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
            MCPImportField.fieldID(serverName: "custom", location: .environment, key: "CREDENTIAL"): .secret,
            MCPImportField.fieldID(serverName: "custom", location: .environment, key: "TOKEN_LIMIT"): .literal
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

        // The stored record, not the stale local copy: updateProject would otherwise wipe the
        // skill selection and the codex target would have nothing to fail on.
        let storedRecords = try await service.storedProjects()
        var changedProject = try XCTUnwrap(storedRecords.first { $0.id == project.id })
        changedProject.tools = [.claude, .codex]
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


    func testProjectSelectsMCPServersDirectlyAndByTagWithoutProfileExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "mcp-tags", path: projectURL.path, tools: [.claude])
        let direct = MCPServer(name: "n8n", transport: .http, url: "https://example.test/mcp", tags: ["automation"])
        let tagged = MCPServer(name: "n8n-tailscale", transport: .http, url: "https://tailscale.example.test/mcp", tags: ["private"])
        try await service.saveMCPServer(direct); try await service.saveMCPServer(tagged)
        try await service.setMCPServers(projectID: project.id, serverIDs: [direct.id], tags: ["private"])
        let previews = try await service.previewMCP(projectID: project.id)
        let preview = try XCTUnwrap(previews.first)
        XCTAssertTrue(preview.content.contains("\"n8n\""))
        XCTAssertTrue(preview.content.contains("\"n8n-tailscale\""))
    }

    func testExistingMCPFieldShowsRealSecretValueAndKeepsItWhenReclassified() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "api", transport: .http, url: "https://example.test/mcp", literalHeaders: ["Authorization": "initial"])
        try await service.saveMCPServer(server)
        var fields = try await service.managedFields(serverID: server.id)
        fields[0].classification = .secret
        fields[0].value = "dummy-secret"
        try await service.saveMCPServer(server, managedFields: fields)
        // The editor shows the secret's real value — nothing is masked in this local, single-user app.
        let managed = try await service.managedFields(serverID: server.id)
        var secretField = try XCTUnwrap(managed.first)
        XCTAssertEqual(secretField.value, "dummy-secret")
        // Switching its type to "literal" carries the same visible value forward — it now goes
        // into the Git-backed backup, which is the point of the classification.
        secretField.classification = .literal
        try await service.saveMCPServer(server, managedFields: [secretField])
        let config = try await service.mcpConfiguration()
        XCTAssertEqual(config.servers.first?.literalHeaders?["Authorization"], "dummy-secret")
        XCTAssertNil(config.servers.first?.secretHeaders?["Authorization"])
    }

    func testMCPServerJSONExportIncludesSecretsPlainlyAndReclassifiesOnSave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "api", transport: .stdio, command: "npx", arguments: ["-y", "pkg"], environment: ["TOKEN": "MY_TOKEN"], enabled: true, tags: ["seo"])
        try await service.saveMCPServer(server)
        var fields = try await service.managedFields(serverID: server.id)
        fields.append(MCPManagedField(location: .environment, key: "API_KEY", value: "sk-secret", classification: .secret))
        try await service.saveMCPServer(server, managedFields: fields)

        // The exported JSON shows every value as it really is, secrets included.
        let exported = try await service.exportMCPServerJSON(server.id)
        XCTAssertTrue(exported.contains("sk-secret"))
        XCTAssertTrue(exported.contains("API_KEY"))
        XCTAssertTrue(exported.contains("${MY_TOKEN}"))

        // Saving re-derives classification from scratch: API_KEY still looks like a secret, so it
        // stays local-only (now under its own name-based account) even though nothing masked it.
        let editedCommand = exported.replacingOccurrences(of: "\"npx\"", with: "\"npx2\"")
        let updated = try await service.updateMCPServerJSON(server.id, name: "api", json: editedCommand, enabled: true, tags: ["seo"])
        XCTAssertEqual(updated.command, "npx2")
        XCTAssertEqual(updated.secretEnvironment?["API_KEY"], "mcp/api/env/API_KEY")
        let managedAfterUpdate = try await service.managedFields(serverID: server.id)
        XCTAssertEqual(managedAfterUpdate.first { $0.key == "API_KEY" }?.value, "sk-secret")

        // Typing a value for a key that does not look like a secret keeps it a plain, backed-up value.
        let plain = #"{"command":"npx2","args":["-y","pkg"],"env":{"REGION":"eu-west-1"}}"#
        let final = try await service.updateMCPServerJSON(server.id, name: "api", json: plain, enabled: true, tags: ["seo"])
        XCTAssertEqual(final.literalEnvironment?["REGION"], "eu-west-1")
        XCTAssertNil(final.secretEnvironment)
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

    /// Full backups used to accumulate forever — the only cleanup was the user remembering to
    /// delete old ones by hand. Now that one is created automatically every day, it must cap itself
    /// the same way library snapshots already do.
    func testFullLocalBackupsArePrunedToTheFourteenMostRecent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        for _ in 0..<16 { _ = try await service.createFullBackup(applicationVersion: "test") }
        let backups = try await service.fullBackups()
        XCTAssertEqual(backups.count, 14)
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

    // MARK: - 0.7.0

    func testReimportingServerDropsSecretAccountsOfTheDefinitionItReplaces() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "api", transport: .http, url: "https://example.test/mcp")
        try await service.saveMCPServer(server)
        try await service.saveMCPServer(server, managedFields: [MCPManagedField(location: .header, key: "Authorization", value: "dummy-old", classification: .secret)])
        let editorAccount = try await service.mcpConfiguration().servers[0].secretHeaders?["Authorization"]
        XCTAssertNotNil(editorAccount)

        _ = try await service.importMCPJSON(#"{"api":{"type":"http","url":"https://example.test/mcp","headers":{"Authorization":"Bearer dummy-new"}}}"#)
        let secrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "mcp-secrets.json")))
        XCTAssertFalse(secrets.values.contains("dummy-old"), "stary sekret został osierocony: \(secrets.keys.sorted())")
        XCTAssertTrue(secrets.values.contains("dummy-new"))
        XCTAssertEqual(secrets.count, 1)
    }

    func testDeletingSkillWritesCatalogAndProjectsUnderOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        let before = try await service.librarySnapshots().count
        try await service.deleteSkill(skillID: "demo")
        let after = try await service.librarySnapshots().count
        XCTAssertEqual(after - before, 1, "usunięcie skilla powinno zająć jeden slot snapshotu, nie dwa")
        let projects = try await service.listProjects()
        XCTAssertTrue(projects[0].skillIDs.isEmpty)
    }

    func testCodexConflictIsDetectedForQuotedTableKey() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.\"api\"]\ncommand = \"ręcznie\"\n".write(to: projectURL.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.codex])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        await XCTAssertThrowsErrorAsync(try await service.previewMCP(projectID: project.id))
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: ".codex/config.toml"), encoding: .utf8).contains("ręcznie"))
    }

    func testCodexRendersDifferentlyNamedEnvironmentVariableWithSourceField() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.codex])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .stdio, command: "npx", environment: ["SERVER_TOKEN": "HOST_TOKEN", "SAME": "SAME"]))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        let content = try await service.previewMCP(projectID: project.id)[0].content
        XCTAssertTrue(content.contains(#"{ name = "SERVER_TOKEN", source = "HOST_TOKEN" }"#), content)
        XCTAssertTrue(content.contains(#""SAME""#), content)
    }

    func testGlobalMCPDiscoveryParsesCodexAndClaudeGlobalServerNames() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try #"""
        model = "gpt"

        [mcp_servers.apple-mail]
        command = "npx"
        args = ["apple-mail-mcp"]

        [mcp_servers."quoted-name"]
        command = "npx"
        """#.write(to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"hubspot":{"type":"http","url":"https://mcp.hubspot.com"}},"projects":{"/some/path":{"mcpServers":{"local-only":{"command":"x"}}}}}"#
            .write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(Set(GlobalMCPDiscovery.codexGlobalServerNames(home: home)), ["apple-mail", "quoted-name"])
        XCTAssertEqual(GlobalMCPDiscovery.claudeGlobalServerNames(home: home), ["hubspot"])

        let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertEqual(GlobalMCPDiscovery.codexGlobalServerNames(home: empty), [])
        XCTAssertEqual(GlobalMCPDiscovery.claudeGlobalServerNames(home: empty), [])
    }

    func testGlobalMCPServersExcludesAlreadyAssignedNamesAndUnrelatedTools() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.apple-mail]\ncommand = \"npx\"\n\n[mcp_servers.assigned]\ncommand = \"npx\"\n".write(to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        // Codex only: a project without .claude among its tools should not see Claude's globals.
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.codex])
        try await service.saveMCPServer(MCPServer(name: "assigned", transport: .stdio, command: "npx"))
        let assignedID = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: assignedID, tags: [])

        let refs = try await service.globalMCPServers(projectID: project.id, home: home)
        XCTAssertEqual(refs, [GlobalMCPServerRef(tool: .codex, name: "apple-mail")])
    }

    func testDisablingGlobalCodexServerWritesOverrideAndReenablingRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.apple-mail]\ncommand = \"npx\"\nargs = [\"apple-mail-mcp\"]\n".write(to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.codex])

        let refs = try await service.globalMCPServers(projectID: project.id, home: home)
        XCTAssertEqual(refs, [GlobalMCPServerRef(tool: .codex, name: "apple-mail")])

        try await service.setDisabledGlobalServers(projectID: project.id, tool: .codex, names: ["apple-mail"])
        let stored = try await service.disabledGlobalServers(projectID: project.id)
        XCTAssertEqual(stored, [.codex: ["apple-mail"]])
        _ = try await service.syncMCP(projectID: project.id)
        let disabled = try String(contentsOf: projectURL.appending(path: ".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(disabled.contains("[mcp_servers.apple-mail]") && disabled.contains("enabled = false"), disabled)
        // The override never redeclares command/args — Codex keeps inheriting those from the global
        // definition and only the `enabled` flag is overridden for this project.
        XCTAssertFalse(disabled.contains("apple-mail-mcp"), disabled)

        try await service.setDisabledGlobalServers(projectID: project.id, tool: .codex, names: [])
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/config.toml").path))
    }

    func testDisablingGlobalClaudeServerWritesDisabledMcpServersAndPreservesOtherSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "{\"mcpServers\":{\"hubspot\":{\"type\":\"http\",\"url\":\"https://mcp.hubspot.com\"}}}".write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        try "{\"permissions\":{\"allow\":[\"Bash\"]}}".write(to: projectURL.appending(path: ".claude/settings.local.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])

        let refs = try await service.globalMCPServers(projectID: project.id, home: home)
        XCTAssertEqual(refs, [GlobalMCPServerRef(tool: .claude, name: "hubspot")])

        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: ["hubspot"])
        _ = try await service.syncMCP(projectID: project.id)
        let settings = try String(contentsOf: projectURL.appending(path: ".claude/settings.local.json"), encoding: .utf8)
        XCTAssertTrue(settings.contains("\"disabledMcpServers\"") && settings.contains("hubspot"), settings)
        XCTAssertTrue(settings.contains("\"permissions\""), settings)
        // .mcp.json is untouched by a disable toggle — nothing was ever assigned in this project.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".mcp.json").path))

        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: [])
        _ = try await service.syncMCP(projectID: project.id)
        let reenabled = try String(contentsOf: projectURL.appending(path: ".claude/settings.local.json"), encoding: .utf8)
        XCTAssertFalse(reenabled.contains("disabledMcpServers"), reenabled)
        XCTAssertTrue(reenabled.contains("\"permissions\""), reenabled)
    }

    func testSwitchingToJsoncStripsEntriesLeftBehindInOpencodeJson() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.opencode])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .http, url: "https://example.test/mcp"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: "opencode.json"), encoding: .utf8).contains("api"))

        try "{ \"mcp\": {} }".write(to: projectURL.appending(path: "opencode.jsonc"), atomically: true, encoding: .utf8)
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: "opencode.jsonc"), encoding: .utf8).contains("api"))
        // The old file held nothing beyond the managed entry, so it disappears entirely instead
        // of lingering as an empty scaffold.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "opencode.json").path), "opencode.json zawierał tylko wpisy Agentbox, więc znika w całości")
    }

    func testProjectStatusReportsSyncedOutdatedBlockedAndMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "wersja 1".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)

        var ids: [String: UUID] = [:]
        for name in ["aktualny", "nieaktualny", "zablokowany", "znikniety"] {
            let url = root.appending(path: "projects/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let project = try await service.addProject(name: name, path: url.path, tools: [.claude])
            try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
            ids[name] = project.id
        }
        for name in ["aktualny", "nieaktualny"] { _ = try await service.syncProjectTransaction(projectID: ids[name]!) }
        // catalog.json i manifest zapisują daty ISO8601 z dokładnością do sekundy, więc test musi
        // przekroczyć granicę sekundy, żeby aktualizacja była odróżnialna od ostatniej synchronizacji.
        try await Task.sleep(for: .milliseconds(1100))
        // Biblioteka rusza do przodu tylko dla jednego projektu.
        try "wersja 2".write(to: root.appending(path: "data/skills/notes/SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.update(skillID: "notes")
        _ = try await service.syncProjectTransaction(projectID: ids["aktualny"]!)

        let manual = root.appending(path: "projects/zablokowany/.claude/skills/notes")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "ręczne".write(to: manual.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "projects/znikniety"))

        let statuses = Dictionary(uniqueKeysWithValues: try await service.projectStatuses().map { ($0.projectID, $0.state) })
        XCTAssertEqual(statuses[ids["aktualny"]!], .synced)
        guard case .pending(_, let outdated, _) = statuses[ids["nieaktualny"]!] else { return XCTFail("oczekiwano zmian do synchronizacji") }
        XCTAssertEqual(outdated, 1)
        guard case .blocked = statuses[ids["zablokowany"]!] else { return XCTFail("oczekiwano statusu zablokowanego") }
        XCTAssertEqual(statuses[ids["znikniety"]!], .missing)
    }

    func testUnsyncRemovesOnlyWhatAgentboxManagesAndKeepsTheRest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try "{\n  \"mcpServers\": { \"reczny\": { \"command\": \"echo\" } }\n}\n".write(to: projectURL.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
        try await service.saveMCPServer(MCPServer(name: "zarzadzany", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)

        // Coś, czego Agentbox nie zapisał, musi przetrwać sprzątanie.
        let ownSkill = projectURL.appending(path: ".claude/skills/wlasny")
        try FileManager.default.createDirectory(at: ownSkill, withIntermediateDirectories: true)
        try "moje".write(to: ownSkill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let removed = try await service.unsyncProject(id: project.id)
        XCTAssertTrue(removed.contains(".claude/skills/notes"), "\(removed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownSkill.appending(path: "SKILL.md").path))
        let mcp = try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8)
        XCTAssertTrue(mcp.contains("reczny"), mcp)
        XCTAssertFalse(mcp.contains("zarzadzany"), mcp)
    }

    func testAdoptingSkillFromProjectResolvesTheConflictThatBlockedSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let manual = projectURL.appending(path: ".claude/skills/reczny")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "napisane ręcznie".write(to: manual.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])

        let candidates = try await service.adoptableSkills(projectID: project.id)
        XCTAssertEqual(candidates.map(\.suggestedID), ["reczny"])
        _ = try await service.adoptSkills(candidates)
        let library = try await service.listSkills().map(\.id)
        XCTAssertEqual(library, ["reczny"])
        XCTAssertEqual(try String(contentsOf: root.appending(path: "data/skills/reczny/SKILL.md"), encoding: .utf8), "napisane ręcznie")

        // Po przejęciu skill jest już znany, więc nie jest ponownie kandydatem.
        let after = try await service.adoptableSkills(projectID: project.id)
        XCTAssertTrue(after.isEmpty)

        // Sedno przejęcia: przejęty skill można przypisać i zsynchronizować w projekcie, z którego
        // pochodzi. Katalog w projekcie jest identyczny z kopią biblioteczną, więc przestaje być
        // konfliktem i przechodzi pod zarząd Agentbox.
        try await service.configureProject(id: project.id, skillIDs: ["reczny"], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: manual.appending(path: "SKILL.md"), encoding: .utf8), "napisane ręcznie")
        XCTAssertTrue(SkillboxService.managedSkillIDs(at: projectURL.appending(path: ".claude/skills")).contains("reczny"))
        let statuses = try await service.projectStatuses()
        XCTAssertEqual(statuses.first { $0.projectID == project.id }?.state, .synced)
    }

    func testUnmanagedSkillDirectoryWithDifferentContentStillBlocksSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/inny")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "wersja biblioteczna".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let manual = projectURL.appending(path: ".claude/skills/inny")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "inna treść użytkownika".write(to: manual.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["inny"], tags: [])
        do {
            _ = try await service.syncProjectTransaction(projectID: project.id)
            XCTFail("Oczekiwano konfliktu skilla")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nie jest zarządzany"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: manual.appending(path: "SKILL.md"), encoding: .utf8), "inna treść użytkownika")
    }

    func testProjectWithNothingSelectedGetsNoGeneratedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "czysty", path: projectURL.path, tools: Tool.allCases)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let files = try FileManager.default.subpathsOfDirectory(atPath: projectURL.path)
        XCTAssertTrue(files.isEmpty, "projekt bez skilli i MCP musi pozostać nietknięty, a jest: \(files)")
        let statuses = try await service.projectStatuses()
        XCTAssertEqual(statuses.first { $0.projectID == project.id }?.state, .synced)
    }

    func testSyncRemovesEmptyScaffoldsLeftByOlderVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        // Stan, jaki zostawiały wersje do 0.9.2 w projekcie bez wybranych skilli i MCP.
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".skillbox"), withIntermediateDirectories: true)
        try #"{"skills" : {},"version" : 2}"#.write(to: projectURL.appending(path: ".claude/skills/.skillbox.json"), atomically: true, encoding: .utf8)
        try "{\n  \"mcpServers\" : {\n\n  }\n}\n".write(to: projectURL.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        try "# >>> skillbox managed MCP >>>\n# <<< skillbox managed MCP <<<\n".write(to: projectURL.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"claude" : [],"codex" : []}"#.write(to: projectURL.appending(path: ".skillbox/mcp-manifest.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "legacy", path: projectURL.path, tools: [.claude, .codex])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let files = try FileManager.default.subpathsOfDirectory(atPath: projectURL.path).filter { !$0.hasSuffix(".DS_Store") }
        XCTAssertTrue(files.allSatisfy { !$0.contains(".skillbox") && !$0.contains(".mcp.json") && !$0.contains("config.toml") }, "puste szkielety mają zniknąć, a zostało: \(files)")
    }

    func testUnsyncRemovesGeneratedFileThatHoldsOnlyManagedEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8).contains("api"))
        _ = try await service.unsyncProject(id: project.id)
        // Plik powstał w całości w Agentbox, więc sprzątanie usuwa go razem z manifestami.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".mcp.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox").path))
    }

    func testUntickingToolCleansItsFilesOnNextSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude, .codex])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills/demo").path))
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: ".codex/config.toml"), encoding: .utf8).contains("api"))

        let storedRecords = try await service.storedProjects()
        var changed = try XCTUnwrap(storedRecords.first { $0.id == project.id })
        changed.tools = [.claude]
        try await service.updateProject(changed)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        // Odznaczone narzędzie nie zostawia po sobie osieroconych plików.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/skills").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".codex/config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/demo").path))
        XCTAssertTrue(try String(contentsOf: projectURL.appending(path: ".mcp.json"), encoding: .utf8).contains("api"))
        let manifest = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: projectURL.appending(path: ".skillbox/mcp-manifest.json")))
        XCTAssertNil(manifest["codex"], "manifest nie może dalej twierdzić, że codex ma wpisy")
    }

    func testTagSelectedSkillCanBeExcludedFromOneProject() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        for name in ["chciany", "niechciany"] {
            let source = root.appending(path: "source/\(name)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let service = try SkillboxService(root: root.appending(path: "data"))
        for name in ["chciany", "niechciany"] {
            _ = try await service.addLocal(path: root.appending(path: "source/\(name)").path)
            try await service.setTags(skillID: name, tags: ["web"])
        }
        var project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        project.tags = ["web"]; project.excludedSkillIDs = ["niechciany"]
        try await service.updateProject(project, serverIDs: [], serverTags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/chciany").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/niechciany").path))
    }

    func testProjectGitignoreIsExtendedOnlyWhenTheProjectOptedIn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "node_modules/\n".write(to: projectURL.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        var project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".gitignore"), encoding: .utf8), "node_modules/\n")

        project.manageGitignore = true
        try await service.updateProject(project, serverIDs: [], serverTags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let text = try String(contentsOf: projectURL.appending(path: ".gitignore"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("node_modules/\n"), text)
        XCTAssertTrue(text.contains(".mcp.json"), text)
        XCTAssertTrue(text.contains(".skillbox/"), text)
    }

    func testLegacySkillManifestStillDecodesAndIsUpgradedOnNextSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = projectURL.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: target.appending(path: "notes"), withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try "skill".write(to: target.appending(path: "notes/SKILL.md"), atomically: true, encoding: .utf8)
        // Manifest w formacie 0.6.x.
        try #"["notes"]"#.write(to: target.appending(path: ".skillbox.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])

        // Stary manifest jest respektowany: to nie jest konflikt, tylko skill do odświeżenia.
        let preview = try await service.previewProjectSync(projectID: project.id)
        XCTAssertEqual(preview.skills[0].added, [])
        XCTAssertEqual(preview.skills[0].updated, ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let upgraded = try await service.previewProjectSync(projectID: project.id)
        XCTAssertEqual(upgraded.skills[0].updated, [], "po synchronizacji projekt jest aktualny")
    }


    func testLocalSkillCanBeEditedInPlaceAndMarksProjectsOutdated() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "wersja 1".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try await Task.sleep(for: .milliseconds(1100))

        try await service.saveSkillMarkdown(skillID: "notes", content: "wersja 2 z aplikacji")
        let stored = try await service.skillMarkdown(skillID: "notes")
        XCTAssertEqual(stored, "wersja 2 z aplikacji")
        // Edycja od razu odznacza projekty jako nieaktualne.
        guard case .pending(_, let outdated, _) = try await service.projectStatuses()[0].state else { return XCTFail("oczekiwano statusu do synchronizacji") }
        XCTAssertEqual(outdated, 1)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".claude/skills/notes/SKILL.md"), encoding: .utf8), "wersja 2 z aplikacji")
    }

    func testGitSkillCannotBeEditedInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo-skill")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "z repozytorium".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        await XCTAssertThrowsErrorAsync(try await service.saveSkillMarkdown(skillID: "repo-skill", content: "podmiana"))
        let unchanged = try await service.skillMarkdown(skillID: "repo-skill")
        XCTAssertEqual(unchanged, "z repozytorium")
    }


    func testSyncAllReportsUnchangedProjectsSeparatelyFromSynchronizedOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        var ids: [String: UUID] = [:]
        for name in ["pierwszy", "drugi"] {
            let url = root.appending(path: "projects/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let project = try await service.addProject(name: name, path: url.path, tools: [.claude])
            try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
            ids[name] = project.id
        }
        _ = try await service.syncProjectTransaction(projectID: ids["pierwszy"]!)
        let outcomes = try await service.syncAllProjectsTransactions()
        let byName = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.plan.project.name, $0.state) })
        XCTAssertEqual(byName["pierwszy"], .upToDate)
        XCTAssertEqual(byName["drugi"], .synced)
    }



    func testSyncLeavesNoBackupCopiesAnywhereAndClearsOnesLeftByOlderVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let library = root.appending(path: "data")
        let service = try SkillboxService(root: library)
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])

        // Pozostałość po wersji, która trzymała historię kopii w repozytorium.
        let legacy = projectURL.appending(path: ".skillbox/sync-backups/stara-kopia")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "x".write(to: legacy.appending(path: "metadata.json"), atomically: true, encoding: .utf8)

        _ = try await service.syncProjectTransaction(projectID: project.id)

        // Ani repozytorium, ani biblioteka nie przechowują kopii po udanym zapisie.
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/sync-backups").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/mcp-backups").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "backups/projects").path))
        // Zostaje wyłącznie to, co mówi, czym Agentbox zarządza.
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/.skillbox.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".claude/skills/notes/SKILL.md").path))
    }

    func testSecondSyncOfUnchangedProjectDoesNotRewriteAnyFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude, .codex, .opencode])
        try await service.configureProject(id: project.id, skillIDs: ["notes"], tags: [])
        try await service.saveMCPServer(MCPServer(name: "api", transport: .http, url: "https://example.test/mcp"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)

        func stamp(_ relative: String) throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: projectURL.appending(path: relative).path)[.modificationDate] as? Date
        }
        let before = (try stamp(".mcp.json"), try stamp(".claude/skills/notes/SKILL.md"))
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try stamp(".mcp.json"), before.0, "plik MCP nie powinien zostać przepisany")
        XCTAssertEqual(try stamp(".claude/skills/notes/SKILL.md"), before.1, "skill nie powinien zostać przekopiowany")

        // Realna zmiana nadal przechodzi normalną ścieżką zapisu.
        try await service.saveSkillMarkdown(skillID: "notes", content: "nowa treść")
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: ".claude/skills/notes/SKILL.md"), encoding: .utf8), "nowa treść")
    }

    // MARK: - CLI

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

    func testTagsMatchRegardlessOfLetterCase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "demo", tags: ["Web"])
        let added = try await service.addProject(name: "sample", path: project.path, tools: [.claude])
        // The CLI could save a project tag with different casing than the skill tag.
        try await service.configureProject(name: "sample", skillIDs: [], tags: ["WEB"])
        _ = try await service.syncProject(name: "sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appending(path: ".claude/skills/demo/SKILL.md").path))

        // An MCP server tagged "SEO" must match a project assignment stored lowercased.
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo", tags: ["SEO"]))
        try await service.setMCPServers(projectID: added.id, serverIDs: [], tags: ["Seo"])
        let previews = try await service.previewMCP(projectID: added.id)
        XCTAssertTrue(previews.contains { $0.added.contains("probe") }, "\(previews.map(\.added))")
        let stored = try await service.mcpConfiguration().servers.first { $0.name == "probe" }
        XCTAssertEqual(stored?.tags, ["seo"], "tagi serwera są zapisywane małymi literami")
    }

    func testTagSelectionDropsRedundantIndividualSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "demo")
        let folder = root.appending(path: "sample")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "demo", tags: ["SEO"])
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo", tags: ["SEO"]))
        let server = try await service.mcpConfiguration().servers.first { $0.name == "probe" }!

        // Both are picked individually *and* covered by a tag — the tag owns them from now on.
        let project = Project(name: "sample", path: folder.path, tools: [.claude], skillIDs: ["demo"], tags: ["seo"])
        let added = try await service.addProject(project, serverIDs: [server.id], serverTags: ["seo"])
        var stored = try await service.listProjects().first { $0.id == added.id }!
        XCTAssertEqual(stored.skillIDs, [], "tag wciąga skilla, więc pojedyncze zaznaczenie jest zbędne")
        let mcp = try await service.mcpConfiguration()
        XCTAssertEqual(mcp.projectServerIDs?[added.id.uuidString], [], "tag wciąga serwer, więc jego id jest zbędne")

        // The project still gets both — only the duplicate bookkeeping is gone.
        _ = try await service.syncProject(name: "sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: ".claude/skills/demo/SKILL.md").path))
        let previews = try await service.previewMCP(projectID: added.id)
        XCTAssertTrue(previews.contains { $0.added.contains("probe") }, "\(previews.map(\.added))")

        // An excluded skill loses its individual id too, otherwise the store keeps a selection
        // that synchronization ignores.
        stored.tags = []; stored.skillIDs = ["demo"]; stored.excludedSkillIDs = ["demo"]
        try await service.updateProject(stored, serverIDs: [], serverTags: [])
        let reloaded = try await service.listProjects().first { $0.id == added.id }!
        XCTAssertEqual(reloaded.skillIDs, [], "wykluczony skill nie zostaje zaznaczony pojedynczo")
    }

    func testImportingManySkillsTakesOneRecoverySnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        for name in ["a", "b", "c"] {
            let folder = repo.appending(path: "skills/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: repo.appending(path: "skills/a").path, id: "seed")
        let before = try await service.librarySnapshots().count
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills").imported
        XCTAssertEqual(imported.count, 3)
        let after = try await service.librarySnapshots().count
        XCTAssertEqual(after - before, 1, "cały import to jeden zapis katalogu i jeden snapshot")
    }

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("oczekiwano błędu", file: file, line: line) } catch {}
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: Parent folders

    /// A parent folder added in a batch, plus a subfolder that appears afterwards: the folder's
    /// settings reach every project without being copied into any of them, and the new subfolder is
    /// offered instead of being noticed only when something is missing from it.
    func testParentFolderSettingsReachEveryProjectAndNewSubfoldersAreDetected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true) }
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo"))
        let server = try await service.mcpConfiguration().servers.first { $0.name == "probe" }!

        let folder = ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude], skillIDs: ["demo"])
        let stored = try await service.addProjectRoot(folder, folders: [workspace.appending(path: "alpha").path, workspace.appending(path: "beta").path], serverIDs: [server.id], serverTags: [])
        let projects = try await service.listProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects.allSatisfy { $0.skillIDs == ["demo"] && $0.tools == [.claude] }, "projekty czytają ustawienia folderu")
        let rawProjects = try await service.storedProjects()
        XCTAssertTrue(rawProjects.allSatisfy { $0.skillIDs.isEmpty }, "ustawienia zostają w folderze, a nie w kopii na każdym projekcie")
        let mcpPreviews = try await service.previewMCP(projectID: projects[0].id)
        XCTAssertTrue(mcpPreviews.contains { $0.added.contains("probe") }, "serwer MCP folderu wchodzi do projektu: \(mcpPreviews.map(\.added))")

        // A subfolder cloned in outside Agentbox is reported once, adopted as a project of the same
        // folder, and then stops being reported.
        try FileManager.default.createDirectory(at: workspace.appending(path: "gamma"), withIntermediateDirectories: true)
        let detected = try await service.scanProjectRoots()
        XCTAssertEqual(detected.map(\.name), ["gamma"])
        let added = try await service.addDetectedFolders(detected)
        XCTAssertEqual(added.map(\.name), ["gamma"])
        let afterAdopting = try await service.scanProjectRoots()
        XCTAssertEqual(afterAdopting.count, 0)
        _ = try await service.syncProjectTransaction(projectID: added[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appending(path: "gamma/.claude/skills/demo/SKILL.md").path))

        // Changing the folder changes every project that follows it, with one edit.
        var updated = try await service.projectRoots()[0]
        updated.tools = [.claude, .codex]
        try await service.updateProjectRoot(updated, serverIDs: [server.id], serverTags: [])
        let afterFolderChange = try await service.listProjects()
        XCTAssertTrue(afterFolderChange.allSatisfy { $0.tools == [.claude, .codex] })
        XCTAssertEqual(stored.id, updated.id)
    }

    /// The escape hatch: one project in the folder gets settings of its own and stops following it.
    func testProjectCanLeaveParentFolderSettingsWithoutAffectingTheOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true) }
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let folder = ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude], skillIDs: ["demo"])
        _ = try await service.addProjectRoot(folder, folders: [workspace.appending(path: "alpha").path, workspace.appending(path: "beta").path], serverIDs: [], serverTags: [])

        var alpha = try await service.storedProjects().first { $0.name == "alpha" }!
        alpha.overridesRoot = true; alpha.tools = [.codex]; alpha.skillIDs = []
        try await service.updateProject(alpha, serverIDs: [], serverTags: [])
        let resolved = try await service.listProjects()
        XCTAssertEqual(resolved.first { $0.name == "alpha" }?.tools, [.codex])
        XCTAssertTrue(resolved.first { $0.name == "alpha" }?.skillIDs.isEmpty == true)
        XCTAssertEqual(resolved.first { $0.name == "beta" }?.skillIDs, ["demo"], "drugi projekt nadal korzysta z folderu")

        // Configuring a project that still follows the folder would write a selection nothing reads.
        let beta = resolved.first { $0.name == "beta" }!
        do { try await service.configureProject(id: beta.id, skillIDs: [], tags: []); XCTFail("oczekiwano błędu") }
        catch { XCTAssertTrue("\(error)".contains("folderu nadrzędnego"), "\(error)") }
    }

    /// Dismissing a subfolder — explicitly, or by removing the project made from it — is an answer
    /// Agentbox has to remember, otherwise the same question comes back at every refresh.
    func testDismissedAndDeletedSubfoldersAreNotOfferedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace.appending(path: "alpha"), withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let folder = ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude])
        _ = try await service.addProjectRoot(folder, folders: [workspace.appending(path: "alpha").path], serverIDs: [], serverTags: [])

        // Appears after the folder exists, so it is genuinely new.
        try FileManager.default.createDirectory(at: workspace.appending(path: "beta"), withIntermediateDirectories: true)
        let detected = try await service.scanProjectRoots()
        XCTAssertEqual(detected.map(\.name), ["beta"])
        try await service.ignoreDetectedFolders(detected)
        let afterIgnoring = try await service.scanProjectRoots()
        XCTAssertTrue(afterIgnoring.isEmpty)

        let alpha = try await service.listProjects().first { $0.name == "alpha" }!
        try await service.deleteProject(id: alpha.id)
        let afterDeletion = try await service.scanProjectRoots()
        XCTAssertTrue(afterDeletion.isEmpty, "usunięty projekt nie wraca jako propozycja")

        let watched = try await service.projectRoots()[0]
        try await service.clearIgnoredFolders(rootID: watched.id)
        let afterClearing = try await service.scanProjectRoots()
        XCTAssertEqual(afterClearing.map(\.name).sorted(), ["alpha", "beta"], "wyczyszczenie listy przywraca też folder usuniętego projektu")
    }

    /// Removing the shared settings must not change what any project synchronizes: each one that
    /// was following the folder keeps a copy of exactly what it was getting.
    func testDeletingParentFolderLeavesProjectsWithWhatTheyInherited() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appending(path: "alpha"), withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo"))
        let server = try await service.mcpConfiguration().servers.first { $0.name == "probe" }!
        let folder = ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude], skillIDs: ["demo"])
        let stored = try await service.addProjectRoot(folder, folders: [workspace.appending(path: "alpha").path], serverIDs: [server.id], serverTags: [])

        try await service.deleteProjectRoot(id: stored.id)
        let alpha = try await service.listProjects().first { $0.name == "alpha" }!
        XCTAssertNil(alpha.rootID)
        XCTAssertEqual(alpha.skillIDs, ["demo"])
        XCTAssertEqual(alpha.tools, [.claude])
        let mcpAfterDeletion = try await service.mcpConfiguration()
        XCTAssertEqual(mcpAfterDeletion.projectServerIDs?[alpha.id.uuidString], [server.id])
        let remainingRoots = try await service.projectRoots()
        XCTAssertTrue(remainingRoots.isEmpty)
    }

    /// A library written before parent folders existed must keep working, and a folder must not be
    /// able to hand a project a skill that was deleted from the library.
    func testLibraryWithoutParentFoldersKeepsDecodingAndDeletedSkillLeavesTheFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = root.appending(path: "data")
        let source = root.appending(path: "source/demo")
        let folderPath = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderPath.appending(path: "alpha"), withIntermediateDirectories: true)
        let legacy = """
        {"projects":[{"id":"\(UUID().uuidString)","name":"legacy","path":"\(folderPath.appending(path: "alpha").path)","tools":["claude"],"skillIDs":[],"tags":[]}]}
        """
        try legacy.write(to: library.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: library)
        let legacyProjects = try await service.listProjects()
        XCTAssertEqual(legacyProjects.map(\.name), ["legacy"])
        let legacyRoots = try await service.projectRoots()
        XCTAssertTrue(legacyRoots.isEmpty)
        let legacyScan = try await service.scanProjectRoots()
        XCTAssertTrue(legacyScan.isEmpty)

        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: source.path)
        try FileManager.default.createDirectory(at: folderPath.appending(path: "beta"), withIntermediateDirectories: true)
        let folder = ProjectRoot(name: "workspace", path: folderPath.path, tools: [.claude], skillIDs: ["demo"])
        _ = try await service.addProjectRoot(folder, folders: [folderPath.appending(path: "beta").path], serverIDs: [], serverTags: [])
        try await service.deleteSkill(skillID: "demo")
        let rootsAfterSkillDelete = try await service.projectRoots()
        XCTAssertTrue(rootsAfterSkillDelete[0].skillIDs.isEmpty, "usunięty skill znika też z folderu nadrzędnego")
        let projectsAfterSkillDelete = try await service.listProjects()
        XCTAssertTrue(projectsAfterSkillDelete.allSatisfy { $0.skillIDs.isEmpty })
    }

    /// Writing a skill in the app instead of importing one: it lands in the library as a valid
    /// `SKILL.md`, stays editable, and reaches projects like any other skill.
    func testSkillWrittenInTheAppIsStoredEditableAndSynchronizes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectFolder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))

        let created = try await service.createSkill(id: "Moje Notatki", name: "Moje notatki", description: "Zasady: krótko", content: "Pisz zwięźle.", tags: ["Praca"])
        XCTAssertEqual(created.id, "moje-notatki")
        XCTAssertEqual(created.tags, ["praca"])
        let markdown = try await service.skillMarkdown(skillID: "moje-notatki")
        XCTAssertTrue(markdown.hasPrefix("---\nname: Moje notatki\ndescription: \"Zasady: krótko\"\n---"), markdown)
        XCTAssertTrue(markdown.contains("Pisz zwięźle."))

        // A local skill stays editable, unlike one replaced wholesale by a Git update.
        try await service.saveSkillMarkdown(skillID: "moje-notatki", content: markdown + "\nDopisek.\n")
        let edited = try await service.skillMarkdown(skillID: "moje-notatki")
        XCTAssertTrue(edited.contains("Dopisek."))

        let project = try await service.addProject(name: "sample", path: projectFolder.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["moje-notatki"], tags: [])
        _ = try await service.syncProject(id: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFolder.appending(path: ".claude/skills/moje-notatki/SKILL.md").path))

        // A pasted file that already has its own header is stored exactly as pasted.
        let pasted = "---\nname: gotowy\ndescription: Wklejony\n---\n\nTreść.\n"
        _ = try await service.createSkill(id: "gotowy", name: "ignorowana", content: pasted)
        let storedPaste = try await service.skillMarkdown(skillID: "gotowy")
        XCTAssertEqual(storedPaste, pasted)

        // A taken identifier is refused and leaves nothing behind in the library.
        do { _ = try await service.createSkill(id: "gotowy", content: "inne"); XCTFail("oczekiwano błędu") }
        catch { XCTAssertTrue("\(error)".contains("gotowy"), "\(error)") }
        let ids = try await service.listSkills().map(\.id)
        XCTAssertEqual(ids.sorted(), ["gotowy", "moje-notatki"])
    }

    /// `/var` is a symlink to `/private/var`, so a library can be reached by two spellings of the
    /// same path. Standardizing only one side of a path comparison made every edit in such a
    /// library fail with "unsafe path".
    func testLibraryReachedThroughASymlinkedPathStaysEditable() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try XCTSkipUnless(temporary.path.hasPrefix("/var/"), "ten system nie mapuje /var na /private/var")
        let library = URL(fileURLWithPath: "/private" + temporary.path)
        let service = try SkillboxService(root: library)

        _ = try await service.createSkill(id: "notatki", content: "Treść.")
        try await service.saveSkillMarkdown(skillID: "notatki", content: "---\nname: notatki\n---\n\nInna treść.\n")
        let markdown = try await service.skillMarkdown(skillID: "notatki")
        XCTAssertTrue(markdown.contains("Inna treść."))
        try await service.deleteSkill(skillID: "notatki")
        let remaining = try await service.listSkills()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// Projects added before parent folders existed must be able to get one, otherwise the shared
    /// settings are reachable only for folders created from scratch.
    func testExistingProjectsCanBeTurnedIntoAParentFolderWithSharedSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true) }
        for name in ["demo", "extra"] {
            let source = root.appending(path: "source/\(name)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: root.appending(path: "source/demo").path)
        _ = try await service.addLocal(path: root.appending(path: "source/extra").path)
        try await service.saveMCPServer(MCPServer(name: "probe", transport: .stdio, command: "echo"))
        let server = try await service.mcpConfiguration().servers.first { $0.name == "probe" }!

        // Two projects added the old way, each with its own settings.
        let alpha = try await service.addProject(Project(name: "alpha", path: workspace.appending(path: "alpha").path, tools: [.claude], skillIDs: ["demo"]), serverIDs: [server.id], serverTags: [])
        let beta = try await service.addProject(Project(name: "beta", path: workspace.appending(path: "beta").path, tools: [.codex], skillIDs: ["extra"]), serverIDs: [], serverTags: [])

        let folder = ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude, .codex], skillIDs: ["demo", "extra"])
        let stored = try await service.adoptProjectsIntoRoot(folder, following: [alpha.id], keepingOwnSettings: [beta.id], serverIDs: [server.id], serverTags: [])

        let resolved = try await service.listProjects()
        let adopted = resolved.first { $0.id == alpha.id }!
        XCTAssertEqual(adopted.rootID, stored.id)
        XCTAssertEqual(adopted.skillIDs.sorted(), ["demo", "extra"], "projekt przechodzi na ustawienia folderu")
        XCTAssertEqual(adopted.tools.sorted { $0.rawValue < $1.rawValue }, [.claude, .codex])
        let untouched = resolved.first { $0.id == beta.id }!
        XCTAssertEqual(untouched.rootID, stored.id, "projekt należy do folderu…")
        XCTAssertEqual(untouched.skillIDs, ["extra"], "…ale zachowuje własne ustawienia")
        XCTAssertEqual(untouched.tools, [.codex])

        // The folder answers for MCP of the project that follows it; the other keeps its own record.
        let mcp = try await service.mcpConfiguration()
        XCTAssertEqual(mcp.projectServerIDs?[stored.id.uuidString], [server.id])
        XCTAssertNil(mcp.projectServerIDs?[alpha.id.uuidString], "stary wybór MCP nie zostaje jako druga prawda")
        let previews = try await service.previewMCP(projectID: alpha.id)
        XCTAssertTrue(previews.contains { $0.added.contains("probe") }, "\(previews.map(\.added))")

        // One edit on the folder reaches the project that follows it.
        var updated = stored
        updated.skillIDs = ["demo"]
        try await service.updateProjectRoot(updated, serverIDs: [server.id], serverTags: [])
        let afterEdit = try await service.listProjects()
        XCTAssertEqual(afterEdit.first { $0.id == alpha.id }?.skillIDs, ["demo"])
        XCTAssertEqual(afterEdit.first { $0.id == beta.id }?.skillIDs, ["extra"])

        // The same folder cannot become a second parent folder.
        do { _ = try await service.adoptProjectsIntoRoot(ProjectRoot(name: "inna", path: workspace.path, tools: [.claude]), following: [], keepingOwnSettings: [], serverIDs: [], serverTags: []); XCTFail("oczekiwano błędu") }
        catch { XCTAssertTrue("\(error)".contains("już dodany jako nadrzędny"), "\(error)") }
    }

    /// The closing block of `refresh`. A rolled-back project used to be reported only in the middle
    /// of a long run, so the summary has to name it — this is the case that is hard to reach by
    /// hand, because a project that fails validation stops the run before any write.
    func testRefreshSummaryNamesRolledBackAndSkippedProjects() throws {
        func outcome(_ name: String, _ state: ProjectSyncOutcome.State) -> ProjectSyncOutcome {
            ProjectSyncOutcome(plan: ProjectSyncPlan(project: Project(name: name, path: "/tmp/\(name)", tools: [.claude]), preview: ProjectSyncPreview(skills: [], mcp: [])), state: state)
        }
        let lines = AgentboxCommand.summary(
            updates: ["docx"],
            backupName: "2026-08-26-abc",
            gitBackup: "To github.com:user/repo.git\n   abc..def  main -> main",
            outcomes: [outcome("alpha", .synced), outcome("beta", .upToDate), outcome("gamma", .failed("konflikt")), outcome("delta", .skipped)])
        let text = lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("zaktualizowano 1: docx"), text)
        XCTAssertTrue(text.contains("2026-08-26-abc"), text)
        XCTAssertTrue(text.contains("4 — ✓ 1 zsynchronizowano, = 1 bez zmian, ✗ 1 cofnięto, – 1 pominięto"), text)
        XCTAssertTrue(text.contains("✗ gamma — konflikt"), text)
        XCTAssertTrue(text.contains("– delta"), text)
        // Multi-line Git output must not break the aligned block.
        XCTAssertFalse(lines.contains { $0.contains("\n") })
        XCTAssertTrue(text.contains("To github.com:user/repo.git · abc..def  main -> main"), text)

        // A clean run says so without a "wymaga uwagi" section.
        let clean = AgentboxCommand.summary(updates: [], backupName: "b", gitBackup: "Everything up-to-date", outcomes: [outcome("alpha", .upToDate)]).joined(separator: "\n")
        XCTAssertTrue(clean.contains("bez aktualizacji"), clean)
        XCTAssertFalse(clean.contains("Wymaga uwagi"), clean)
    }

    /// "Nowy podfolder" must mean "pojawił się od kiedy folder istnieje". A subfolder deliberately
    /// left unticked while adding the batch is an answer, not a pending question.
    func testSubfoldersPresentWhenTheFolderIsCreatedAreNotProposedAsNew() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        for name in ["alpha", "beta", "archiwum"] { try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true) }
        let service = try SkillboxService(root: root.appending(path: "data"))

        // Only alpha becomes a project; beta and archiwum were seen and left out.
        let stored = try await service.addProjectRoot(ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude]), folders: [workspace.appending(path: "alpha").path], serverIDs: [], serverTags: [])
        let rightAfter = try await service.scanProjectRoots()
        XCTAssertTrue(rightAfter.isEmpty, "odznaczone podfoldery nie wracają jako pytanie: \(rightAfter.map(\.name))")
        XCTAssertEqual(stored.ignoredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(), ["archiwum", "beta"])
        XCTAssertFalse(stored.ignoredPaths.contains { $0.hasSuffix("/alpha") }, "projekt nie jest folderem pominiętym")

        // Only what shows up later counts as new.
        try FileManager.default.createDirectory(at: workspace.appending(path: "gamma"), withIntermediateDirectories: true)
        let detected = try await service.scanProjectRoots()
        XCTAssertEqual(detected.map(\.name), ["gamma"])

        // And the folders left out at the start can be brought back deliberately.
        try await service.clearIgnoredFolders(rootID: stored.id)
        let afterClearing = try await service.scanProjectRoots()
        XCTAssertEqual(afterClearing.map(\.name).sorted(), ["archiwum", "beta", "gamma"])
    }

    /// The same rule when an existing folder is turned into a parent folder.
    func testAdoptingAnExistingFolderDoesNotProposeItsCurrentSubfolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        for name in ["alpha", "notatki"] { try FileManager.default.createDirectory(at: workspace.appending(path: name), withIntermediateDirectories: true) }
        let service = try SkillboxService(root: root.appending(path: "data"))
        let alpha = try await service.addProject(name: "alpha", path: workspace.appending(path: "alpha").path, tools: [.claude])

        let stored = try await service.adoptProjectsIntoRoot(ProjectRoot(name: "workspace", path: workspace.path, tools: [.claude]), following: [alpha.id], keepingOwnSettings: [], serverIDs: [], serverTags: [])
        XCTAssertEqual(stored.ignoredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["notatki"])
        let rightAfter = try await service.scanProjectRoots()
        XCTAssertTrue(rightAfter.isEmpty, "\(rightAfter.map(\.name))")

        // Opting out asks about what is already there.
        let other = root.appending(path: "inny")
        try FileManager.default.createDirectory(at: other.appending(path: "stare"), withIntermediateDirectories: true)
        let asking = try await service.adoptProjectsIntoRoot(ProjectRoot(name: "inny", path: other.path, tools: [.claude]), following: [], keepingOwnSettings: [], serverIDs: [], serverTags: [], treatingExistingAsKnown: false)
        XCTAssertTrue(asking.ignoredPaths.isEmpty)
        let asked = try await service.scanProjectRoots()
        XCTAssertEqual(asked.map(\.name), ["stare"])
    }

    // MARK: - Documents (AGENTS.md / CLAUDE.md)

    func testDocCreateAssignPreviewAndSyncGeneratesClaudeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "docs-project", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "# Guidelines\nDo the thing.")

        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        let preview = try await service.previewDocs(projectID: project.id)
        XCTAssertEqual(preview.count, 2)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        let claude = try XCTUnwrap(preview.first { $0.file.hasSuffix("CLAUDE.md") })
        XCTAssertEqual(agents.content, "# Guidelines\nDo the thing.\n")
        XCTAssertEqual(claude.content, "@AGENTS.md\n")
        XCTAssertEqual(agents.added, ["standard"])
        XCTAssertEqual(claude.added, ["standard"])

        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "# Guidelines\nDo the thing.\n")
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
    }

    func testDocTagAssignmentAndSwitchingSelectionReplacesContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let first = try await service.createDoc(id: "first", name: "First", tags: ["backend"], content: "one")
        let second = try await service.createDoc(id: "second", name: "Second", tags: [], content: "two")

        try await service.setDocs(projectID: project.id, docIDs: [], tags: ["Backend"])
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "one\n")

        try await service.setDocs(projectID: project.id, docIDs: [second.id], tags: [])
        let preview = try await service.previewDocs(projectID: project.id)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        XCTAssertEqual(agents.added, [second.id])
        XCTAssertEqual(agents.removed, [first.id])
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "two\n")
    }

    func testMultipleMatchingDocumentsIsAConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        _ = try await service.createDoc(id: "a", name: "A", tags: ["shared"], content: "a")
        _ = try await service.createDoc(id: "b", name: "B", tags: ["shared"], content: "b")
        try await service.setDocs(projectID: project.id, docIDs: [], tags: ["shared"])

        do { _ = try await service.previewDocs(projectID: project.id); XCTFail("Oczekiwano konfliktu") }
        catch let error as SkillboxError { XCTAssertTrue(error.localizedDescription.contains("Konflikt dokumentu")) }
    }

    func testUnmanagedAgentsFileWithDifferentContentBlocksDocSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "hand written".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "d", name: "D", tags: [], content: "generated")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        do { _ = try await service.previewDocs(projectID: project.id); XCTFail("Oczekiwano konfliktu") }
        catch let error as SkillboxError { XCTAssertTrue(error.localizedDescription.contains("Konflikt dokumentu")) }
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "hand written")
    }

    /// The one exception to the conflict above: a hand-written file that already holds byte-identical
    /// text is adopted silently, the same leniency `directoryMatches` gives skills.
    func testUnmanagedFileByteIdenticalToDocumentIsAdoptedWithoutConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "shared text\n".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "d", name: "D", tags: [], content: "shared text")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
    }

    /// Nothing selected and nothing previously managed must leave a foreign file completely alone —
    /// no conflict, no write, no manifest.
    func testProjectWithNoDocumentSelectedLeavesExistingAgentsFileUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "totally unrelated content".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        let preview = try await service.previewDocs(projectID: project.id)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        XCTAssertEqual(agents.content, "totally unrelated content")
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "totally unrelated content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
    }

    func testUnsyncRemovesManagedDocumentFilesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "hello")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: "CLAUDE.md").path))

        let removed = try await service.unsyncProject(id: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "CLAUDE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
        XCTAssertTrue(removed.contains { $0.contains("standard") }, "\(removed)")
    }

    /// The transaction's rollback copy is taken before any write, across skills, MCP and docs alike —
    /// a doc-level write failure must undo a skill file the same transaction already wrote.
    func testProjectTransactionRollsBackSkillsWhenDocWriteFailsLater() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "version one".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "rollback-doc", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "first version")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "first version\n")

        // A second change, blocked from ever landing: the skill gets a new version, and AGENTS.md is
        // replaced by a directory so the write that would follow it fails.
        try "version two".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.update(skillID: "demo")
        try FileManager.default.removeItem(at: projectURL.appending(path: "AGENTS.md"))
        try FileManager.default.createDirectory(at: projectURL.appending(path: "AGENTS.md"), withIntermediateDirectories: true)

        do { _ = try await service.syncProjectTransaction(projectID: project.id); XCTFail("Oczekiwano błędu zapisu") } catch {}
        let restoredSkill = try String(contentsOf: projectURL.appending(path: ".claude/skills/demo/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(restoredSkill, "version one")
    }

    func testDeletingDocumentRemovesItFromProjectAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "text")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        try await service.deleteDoc(id: doc.id)
        let config = try await service.docsConfiguration()
        XCTAssertTrue(config.docs.isEmpty)
        XCTAssertEqual(config.projectDocIDs?[project.id.uuidString] ?? [], [])
        let preview = try await service.previewDocs(projectID: project.id)
        XCTAssertTrue(preview.allSatisfy { $0.content.isEmpty })
    }

    func testAddDocTagsMergesWithExistingAndNormalizesCase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let one = try await service.createDoc(id: "one", name: "One", tags: ["seo"], content: "a")
        let two = try await service.createDoc(id: "two", name: "Two", tags: [], content: "b")
        try await service.addDocTags(docIDs: [one.id, two.id], tags: ["Audit", "seo"])
        let docs = try await service.docsConfiguration().docs
        XCTAssertEqual(docs.first { $0.id == one.id }?.tags, ["audit", "seo"])
        XCTAssertEqual(docs.first { $0.id == two.id }?.tags, ["audit", "seo"])
    }

    /// `docs.json` rides along with every other library file: it must survive a full local backup
    /// and restore round trip, and an older backup made before documents existed must still restore.
    func testFullLocalBackupRestoresDocumentsAndOlderBackupsWithoutDocsJSONStillRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.createDoc(id: "standard", name: "Standard", tags: ["backend"], content: "hello")
        let backup = try await service.createFullBackup(applicationVersion: "test")

        _ = try await service.createDoc(id: "extra", name: "Extra", tags: [], content: "world")
        try await service.restoreFullBackup(named: backup.name)
        let restored = try await service.docsConfiguration().docs
        XCTAssertEqual(restored.map(\.id), ["standard"])

        // Simulate a backup made before documents existed: remove docs.json from the package, then
        // add a document that only exists on disk right now — a legacy restore must leave it alone
        // instead of wiping it because the old package has nothing to say about it.
        let legacyPackage = root.appending(path: "data/backups/full/\(backup.name)/docs.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPackage.path))
        try FileManager.default.removeItem(at: legacyPackage)
        _ = try await service.createDoc(id: "current-only", name: "Current only", tags: [], content: "kept")
        try await service.restoreFullBackup(named: backup.name)
        let afterLegacyRestore = try await service.docsConfiguration().docs
        XCTAssertEqual(Set(afterLegacyRestore.map(\.id)), ["standard", "current-only"], "docs.json spoza backupu powinno przetrwać restore starszego pakietu bez docs.json")
    }
}
