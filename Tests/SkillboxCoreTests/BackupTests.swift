import XCTest
@testable import SkillboxCore

final class BackupTests: AgentboxTestCase {
    func testLibraryIsRecognizedAndReopenedWithItsSkillsIntact() async throws {
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
    func testAnalyzesClaudeConfigurationKeepsAllValuesLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"n8n-mcp":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-one","N8N_API_URL":"http://lan:5678"}},"n8n-tailscale":{"type":"stdio","command":"npx","args":["-y","n8n-mcp"],"env":{"N8N_API_KEY":"secret-two","N8N_API_URL":"http://tailnet:5678"}},"context7":{"type":"http","url":"https://mcp.context7.com/mcp","headers":{"CONTEXT7_API_KEY":"secret-three"}}}"#
        let summary = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(summary.servers.count, 3)
        XCTAssertEqual(summary.secretCount, 0)
        XCTAssertEqual(summary.servers.first(where: { $0.name == "n8n-mcp" })?.literalEnvironment?["N8N_API_URL"], "http://lan:5678")
        XCTAssertEqual(summary.servers.first(where: { $0.name == "context7" })?.literalHeaders?["CONTEXT7_API_KEY"], "secret-three")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "mcp-secrets.json").path))
    }
    func testProcessRunnerDrainsLargeOutput() throws {
        let output = try ProcessRunner.run("/usr/bin/head", ["-c", "200000", "/dev/zero"])
        XCTAssertEqual(output.utf8.count, 200_000)
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
    /// A snapshot has to carry `selections.json` too. It holds every attachment there is — which
    /// skills, servers, documents and plugins a place uses — so a snapshot without it restored the
    /// catalog while silently leaving the assignments as the mistake had left them.
    func testLibrarySnapshotRestoresProjectSelectionsAndNotOnlyTheCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "demo".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "web", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])

        // The next save is what snapshots the state above.
        try await service.setTags(skillID: "demo", tags: ["changed"])
        let snapshots = try await service.librarySnapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(snapshot.files.contains("selections.json"), "snapshot zawiera: \(snapshot.files)")

        // The assignment is then wrecked and the snapshot restored.
        try await service.configureProject(id: project.id, skillIDs: [], tags: [])
        _ = try await service.restoreLibrarySnapshot(named: snapshot.name)

        let restored = try await service.selection(for: .project(project.id))
        XCTAssertEqual(restored.skillIDs, ["demo"])
        XCTAssertEqual(restored.tools, [.claude])
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
        try await service.saveMCPServer(server, managedFields: [MCPManagedField(location: .header, key: "Authorization", value: "dummy-secret", classification: .literal)])
        let backup = try await service.createFullBackup(applicationVersion: "test")
        let package = root.appending(path: "data/backups/full/\(backup.name)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appending(path: "mcp-secrets.json").path))
        try await service.deleteProject(id: (try await service.listProjects())[0].id)
        try await service.deleteMCPServer(id: server.id)
        try "changed".write(to: root.appending(path: "data/skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try await service.restoreFullBackup(named: backup.name)
        let restoredProjects = try await service.listProjects()
        XCTAssertEqual(restoredProjects.first?.name, "saved")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "data/skills/demo/SKILL.md"), encoding: .utf8), "original skill")
        let restoredMCP = try await service.mcpConfiguration()
        XCTAssertEqual(restoredMCP.servers.first?.literalHeaders?["Authorization"], "dummy-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "data/mcp-secrets.json").path))
    }
    func testFullBackupKeepsNonemptyLegacySecretsForOlderLibraries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let server = MCPServer(name: "legacy", transport: .http, url: "https://example.test/mcp", secretHeaders: ["Authorization": "legacy:header:Authorization"])
        var legacyConfiguration = MCPConfiguration()
        legacyConfiguration.servers = [server]
        try await service.store.save(legacyConfiguration)
        try await service.store.replaceSecrets(["legacy:header:Authorization": "dummy-secret"])
        let backup = try await service.createFullBackup(applicationVersion: "test")
        let package = root.appending(path: "data/backups/full/\(backup.name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appending(path: "mcp-secrets.json").path))

        try await service.deleteMCPServer(id: server.id)
        try await service.restoreFullBackup(named: backup.name)
        let restoredMCP = try await service.mcpConfiguration()
        let restoredServers = restoredMCP.servers.map(\.name)
        let restoredSecrets = try await service.store.secrets()
        XCTAssertEqual(restoredServers, ["legacy"])
        XCTAssertEqual(restoredSecrets["legacy:header:Authorization"], "dummy-secret")
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
}
