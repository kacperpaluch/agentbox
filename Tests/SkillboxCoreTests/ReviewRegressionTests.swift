import XCTest
@testable import SkillboxCore

/// One test per defect found in the external review of 0.24.0. Each one failed before its fix and
/// describes the rule that has to hold, so the same mistake cannot come back quietly.
final class ReviewRegressionTests: AgentboxTestCase {
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // 1. Manifest ids used in path joins without validation.
    func testManifestEntryCannotPointOutsideTheSkillsDirectory() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        let victim = projectURL.appending(path: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "ważne".write(to: victim.appending(path: "dane.txt"), atomically: true, encoding: .utf8)
        let target = projectURL.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"version":2,"skills":{"../../victim":"2020-01-01T00:00:00Z"}}"#
            .write(to: target.appending(path: ".skillbox.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        _ = try? await service.unsyncProject(id: project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appending(path: "dane.txt").path),
                      "manifest nigdy nie może wskazać katalogu spoza katalogu skilli")
    }

    // 2. A library written before selections.json moved attachments out.
    func testLegacyLibraryKeepsItsAssignments() async throws {
        let root = try temp()
        let data = root.appending(path: "data")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: data.appending(path: "skills/demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: data.appending(path: "skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"version":1,"skills":[{"id":"demo","name":"demo","tags":[],"source":{"kind":"local","location":"/tmp/demo"},"updatedAt":"2024-01-01T00:00:00Z"}]}"#
            .write(to: data.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        // The 0.16 shape: attachments live on the project itself, no selections.json exists.
        try """
        {"projects":[{"id":"5F2C8E52-9A9D-4C2B-9F62-1D0F1F4C9A11","name":"stary","path":"\(projectURL.path)","tools":["claude"],"skillIDs":["demo"],"tags":[]}]}
        """.write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: data)

        let projects = try await service.listProjects()
        let project = try XCTUnwrap(projects.first)

        XCTAssertEqual(project.tools, [.claude], "biblioteka sprzed 0.17 zachowuje narzędzia projektu")
        XCTAssertEqual(project.skillIDs, ["demo"], "biblioteka sprzed 0.17 zachowuje przypisane skille")
    }

    // 3. An unmanaged AGENTS.md that cannot be read as UTF-8.
    func testUnreadableUnmanagedDocumentIsLeftAlone() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let agents = projectURL.appending(path: "AGENTS.md")
        try "moje własne zasady".data(using: .utf16)!.write(to: agents)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        _ = try? await service.syncDocs(projectID: project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.path),
                      "niezarządzany plik, którego nie da się odczytać, zostaje nietknięty")
    }

    // 4. Imported secrets end up in mcp.json, which snapshotLibrary copies.
    func testSecretBearingFilesAndTheirCopiesStayPrivate() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.importMCPJSON(#"{"mcpServers":{"x":{"command":"npx","env":{"TOKEN":"dummy-secret-value"}}}}"#)
        // A second write, so at least one snapshot exists.
        try await service.saveMCPServer(MCPServer(name: "inny", transport: .stdio, command: "npx"))

        let snapshots = root.appending(path: "data/.agentbox-snapshots")
        var leaked: [String] = []
        if let items = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
            for item in items {
                let mcp = item.appending(path: "mcp.json")
                if let text = try? String(contentsOf: mcp, encoding: .utf8), text.contains("dummy-secret-value") { leaked.append(item.lastPathComponent) }
            }
        }
        func permissions(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? 0 }
        XCTAssertEqual(permissions(root.appending(path: "data/mcp.json")), 0o600, "mcp.json może zawierać token, więc czyta go tylko właściciel")
        XCTAssertEqual(permissions(snapshots), 0o700, "katalog snapshotów jest prywatny")
        for name in leaked {
            XCTAssertEqual(permissions(snapshots.appending(path: name).appending(path: "mcp.json")), 0o600, "kopia mcp.json w snapshocie jest chroniona tak jak oryginał")
        }
    }

    // 6. Deleting a skill removes files before the configuration is read.
    func testFailedSkillDeletionLeavesTheLibraryUnchanged() async throws {
        let root = try temp()
        let data = root.appending(path: "data")
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: data)
        _ = try await service.addLocal(path: source.path)
        // Corrupt the file the deletion has to read *after* it already removed the directory.
        try "{ to nie jest JSON".write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await service.deleteSkill(skillID: "demo"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(path: "skills/demo/SKILL.md").path),
                      "nieudane usunięcie zostawia bibliotekę dokładnie tak, jak ją zastało")
    }

    // 8. Claude's opt-out file is not part of the up-to-date comparison.
    func testGlobalServerOptOutIsActuallyWritten() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        // No servers assigned, so the main .mcp.json stays absent — only the opt-out has work to do.
        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: ["globalny"])

        let preview = try await service.previewProjectSync(projectID: project.id)
        XCTAssertEqual(preview.mcp.first?.disabledGlobalAdded, ["globalny"], "przygotowanie: podgląd zawiera wyłączenie")

        _ = try await service.syncProjectTransaction(projectID: project.id)

        let settings = projectURL.appending(path: ".claude/settings.local.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path),
                      "wyłączenie globalnego serwera musi trafić na dysk")
    }

    // 9 & 10. What the JSON editor exports and what re-importing it does.
    func testJSONRoundTripKeepsSecretsTagsAndEnabled() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        var server = MCPServer(name: "x", transport: .stdio, command: "npx")
        server.tags = ["praca"]
        server.enabled = false
        server.secretEnvironment = ["TOKEN": "konto"]
        try await service.saveMCPServer(server)
        try await service.store.replaceSecrets(["konto": "prawdziwy-token"])

        let json = try await service.exportMCPServerJSON(server.id)

        XCTAssertFalse(json.contains("\"TOKEN\" : \"\""), "eksport pokazuje prawdziwą wartość sekretu: \(json)")
        let all = try await service.mcpConfiguration().servers
        let exported = try await service.exportMCPConfigurationJSON(all)
        _ = try await service.importMCPJSON(exported)
        let servers = try await service.mcpConfiguration().servers
        let after = try XCTUnwrap(servers.first { $0.id == server.id })
        XCTAssertEqual(after.tags, ["praca"], "zapis całej konfiguracji zachowuje tagi")
        XCTAssertFalse(after.enabled, "zapis całej konfiguracji nie włącza wyłączonego serwera")
    }

    // 11. Global sync and a client the user unticked.
    func testGlobalSyncCleansUpAnUntickedClient() async throws {
        let root = try temp()
        let home = root.appending(path: "home")
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        _ = try await service.syncGlobal(tool: .claude, skillIDs: ["demo"], home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/demo/SKILL.md").path), "przygotowanie")

        try await service.setSelection(AttachmentSelection(tools: [.codex], skillIDs: ["demo"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/demo").path),
                       "odznaczony klient traci zarządzane skille")
    }

    // Minor: TOML string escaping.
    func testTOMLEscapesControlCharacters() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.codex])
        let server = MCPServer(name: "x", transport: .stdio, command: "npx", arguments: ["linia1\nlinia2"])
        try await service.saveMCPServer(server)
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])

        _ = try await service.syncMCP(projectID: project.id)

        let toml = try String(contentsOf: projectURL.appending(path: ".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(toml.contains("linia1\nlinia2"), "TOML nie może zawierać surowego znaku sterującego: \(toml)")
    }

    // 1b. The same manifest ids during an ordinary synchronization, not just unsync.
    func testOrdinarySynchronizationHonoursTheSameManifestRule() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        let victim = projectURL.appending(path: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "ważne".write(to: victim.appending(path: "dane.txt"), atomically: true, encoding: .utf8)
        let target = projectURL.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"version":2,"skills":{"../../victim":"2020-01-01T00:00:00Z"}}"#
            .write(to: target.appending(path: ".skillbox.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        _ = try? await service.syncProject(id: project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appending(path: "dane.txt").path),
                      "to samo obowiązuje na ścieżce zwykłej synchronizacji")
    }

    // 2b. Does the lost selection actually destroy files in an old project?
    func testSynchronizingALegacyLibraryDoesNotDeleteItsSkills() async throws {
        let root = try temp()
        let data = root.appending(path: "data")
        let projectURL = root.appending(path: "project")
        let installed = projectURL.appending(path: ".claude/skills/demo")
        try FileManager.default.createDirectory(at: data.appending(path: "skills/demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: data.appending(path: "skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: installed.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"version":2,"skills":{"demo":"2024-01-01T00:00:00Z"}}"#
            .write(to: projectURL.appending(path: ".claude/skills/.skillbox.json"), atomically: true, encoding: .utf8)
        try #"{"version":1,"skills":[{"id":"demo","name":"demo","tags":[],"source":{"kind":"local","location":"/tmp/demo"},"updatedAt":"2024-01-01T00:00:00Z"}]}"#
            .write(to: data.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        try """
        {"projects":[{"id":"5F2C8E52-9A9D-4C2B-9F62-1D0F1F4C9A11","name":"stary","path":"\(projectURL.path)","tools":["claude"],"skillIDs":["demo"],"tags":[]}]}
        """.write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: data)
        let projects = try await service.listProjects()

        _ = try? await service.syncProjectTransaction(projectID: try XCTUnwrap(projects.first).id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appending(path: "SKILL.md").path),
                      "synchronizacja starej biblioteki nie może skasować skilli z projektu")
    }


    // MARK: Git

    /// In a linked worktree `.git` is a file, not a directory. The exclude file lives wherever it
    /// points, and generated MCP files may hold resolved secrets — so "nie znalazłem .git/info"
    /// must never mean "trudno".
    func testGeneratedFilesAreExcludedInsideAWorktree() async throws {
        let root = try temp()
        let main = root.appending(path: "main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try "x".write(to: main.appending(path: "plik.txt"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: main)
        try runGit(["-c", "user.name=T", "-c", "user.email=t@e.com", "add", "."], in: main)
        try runGit(["-c", "user.name=T", "-c", "user.email=t@e.com", "commit", "-m", "init"], in: main)
        let worktree = root.appending(path: "gałąź")
        try runGit(["worktree", "add", "-b", "praca", worktree.path], in: main)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path, isDirectory: &isDirectory)
        XCTAssertFalse(isDirectory.boolValue, "przygotowanie: w worktree .git jest plikiem")

        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "wt", path: worktree.path, tools: [.claude])
        let server = MCPServer(name: "x", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])

        _ = try await service.syncMCP(projectID: project.id)

        // Asked of Git, not of the function under test: the first attempt at this fix wrote the
        // exclusions into the worktree's own `info/` — a file Git never reads — and a test that
        // consulted the same helper happily agreed with it.
        let ignored = try gitOutput(["check-ignore", "-v", ".mcp.json"], in: worktree)
        XCTAssertTrue(ignored.contains("exclude"), "Git musi faktycznie ignorować wygenerowany plik MCP w worktree: \(ignored)")
    }

    /// A package inside a monorepo: `.git` sits two levels up. Nothing used to be excluded there,
    /// and a pattern with a slash inside would not have matched from the root anyway.
    func testGeneratedFilesAreExcludedInAProjectNestedInARepository() async throws {
        let root = try temp()
        let repository = root.appending(path: "repo")
        let package = repository.appending(path: "packages/moja app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try runGit(["init"], in: repository)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: package.path, tools: [.claude, .codex])
        let server = MCPServer(name: "x", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])

        _ = try await service.syncProjectTransaction(projectID: project.id)

        for file in [".mcp.json", ".codex/config.toml", ".skillbox/mcp-manifest.json"] {
            let ignored = try gitOutput(["check-ignore", "-v", "packages/moja app/\(file)"], in: repository)
            XCTAssertTrue(ignored.contains("exclude"), "Git musi ignorować \(file) w zagnieżdżonym projekcie: \(ignored)")
        }
        let elsewhere = try gitOutput(["check-ignore", "-v", ".codex/config.toml"], in: repository)
        XCTAssertFalse(elsewhere.contains("exclude"), "wzorce dotyczą tylko folderu projektu: \(elsewhere)")
    }

    /// Files already current skip every write, but must not skip the protection: `git init` after
    /// the first sync is the ordinary way a project becomes a repository.
    func testRepositoryInitializedAfterSyncIsProtectedByTheNextSync() async throws {
        let root = try temp()
        let folder = root.appending(path: "app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: folder.path, tools: [.claude])
        let server = MCPServer(name: "x", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        try await service.setMCPServers(projectID: project.id, serverIDs: [server.id], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)

        try runGit(["init"], in: folder)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let ignored = try gitOutput(["check-ignore", "-v", ".mcp.json"], in: folder)
        XCTAssertTrue(ignored.contains("exclude"), "ponowna synchronizacja aktualnego projektu dodaje wykluczenia: \(ignored)")

        try "".write(to: folder.appending(path: ".git/info/exclude"), atomically: true, encoding: .utf8)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let restored = try gitOutput(["check-ignore", "-v", ".mcp.json"], in: folder)
        XCTAssertTrue(restored.contains("exclude"), "usunięte reguły wracają: \(restored)")
    }

    /// Clutter from 0.7.0 is removed by name — but a `.skillbox` that is a link leads elsewhere.
    func testLegacyBackupCleanupDoesNotFollowALinkedSkillboxFolder() async throws {
        let root = try temp()
        let folder = root.appending(path: "app"), outside = root.appending(path: "gdzie-indziej")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appending(path: "sync-backups"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: ".skillbox"), withDestinationURL: outside)
        SkillboxService.removeLegacyBackupDirectories(folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "sync-backups").path))

        let own = root.appending(path: "own")
        try FileManager.default.createDirectory(at: own.appending(path: ".skillbox/sync-backups"), withIntermediateDirectories: true)
        SkillboxService.removeLegacyBackupDirectories(own)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appending(path: ".skillbox/sync-backups").path), "własny stary katalog nadal znika")
    }

    // MARK: Równoległe zapisy

    /// Two operations read the same library; the second save must not wipe out the first. The same
    /// holds when the other writer is `agentbox` running next to the app.
    func testSavingAValueReadBeforeAnotherSaveIsRefused() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
            _ = try await service.addProject(name: name, path: root.appending(path: name).path, tools: [.claude])
        }
        let projects = try await service.storedProjects()
        var stale = try await service.store.configuration()
        try await service.setSelection(AttachmentSelection(tools: [.codex]), for: .project(projects[0].id))
        stale.selections[projects[1].id.uuidString] = AttachmentSelection(tools: [.opencode])
        await XCTAssertThrowsErrorAsync(try await service.store.save(stale))
        let kept = try await service.storedSelection(for: .project(projects[0].id))
        XCTAssertEqual(kept.tools, [.codex], "pierwszy zapis przetrwał")

        var mcp = try await service.store.mcpConfiguration()
        try #"{"version":1,"servers":[]}"#.write(to: root.appending(path: "data/mcp.json"), atomically: true, encoding: .utf8)
        mcp.servers.append(MCPServer(name: "x", transport: .stdio, command: "npx"))
        await XCTAssertThrowsErrorAsync(try await service.store.save(mcp)) // zmiana z innego procesu też blokuje zapis

        let fresh = try await service.store.configuration()
        try await service.store.save(fresh)
    }

    // MARK: Nieudane cofanie zmian

    /// A rollback that cannot finish must say so and keep the copy it was restoring from. Reporting
    /// "cofnięto" over a half-written project, having just deleted the only rescue copy, is the
    /// worst possible combination.
    func testFailedRollbackIsReportedAndKeepsTheBackup() throws {
        let root = try temp()
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try "oryginał".write(to: project.appending(path: ".claude/skills/plik.txt"), atomically: true, encoding: .utf8)
        let scratch = SkillboxService.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A backup whose saved copy is missing: restoring it cannot possibly succeed.
        let backup = scratch.appending(path: "kopia")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let error = SkillboxService.rollingBackForTests(
            SkillboxError.commandFailed("pierwotny błąd"),
            project: project, backup: backup,
            relativePath: ".claude/skills/plik.txt", scratch: scratch
        )

        XCTAssertTrue(error.localizedDescription.contains("pierwotny błąd"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("cofanie zmian też się nie powiodło"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains(backup.path), "komunikat musi wskazać zachowaną kopię: \(error.localizedDescription)")
        XCTAssertTrue(SkillboxService.shouldKeepScratch(scratch), "kopia ratunkowa nie może zostać skasowana po nieudanym cofnięciu")
    }

    // MARK: Folder nadrzędny

    /// Deleting a folder keeps every project exactly as it is synchronized today. The opt-out from a
    /// globally declared MCP server is part of that, even though it lives in `mcp.json` rather than
    /// in the selection.
    func testDeletingAParentFolderKeepsItsGlobalOptOuts() async throws {
        let root = try temp()
        let folder = root.appending(path: "grupa")
        for name in ["a", "b"] { try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true) }
        let service = try SkillboxService(root: root.appending(path: "data"))
        let stored = try await service.addProjectRoot(
            ProjectRoot(name: "grupa", path: folder.path, tools: [.codex]),
            folders: [folder.appending(path: "a").path, folder.appending(path: "b").path],
            selection: AttachmentSelection(tools: [.codex])
        )
        try await service.setDisabledGlobalServers(selectionID: stored.id, tool: .codex, names: ["apple-mail"])

        try await service.deleteProjectRoot(id: stored.id)

        for project in try await service.listProjects() {
            let optOut = try await service.disabledGlobalServers(projectID: project.id)
            XCTAssertEqual(optOut, [Tool.codex: ["apple-mail"]], "projekt \(project.name) stracił wyłączenie globalnego serwera")
        }
    }

    // MARK: Druga runda przeglądu

    /// Validating the *name* of a manifest entry is not enough when the directory holding it is a
    /// symbolic link: an ordinary entry then resolves outside the project.
    func testSymlinkedSkillsDirectoryCannotReachOutsideTheProject() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside.appending(path: "demo"), withIntermediateDirectories: true)
        try "cudze".write(to: outside.appending(path: "demo/plik.txt"), atomically: true, encoding: .utf8)
        try #"{"version":2,"skills":{"demo":"2020-01-01T00:00:00Z"}}"#
            .write(to: outside.appending(path: ".skillbox.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projectURL.appending(path: ".claude/skills"), withDestinationURL: outside)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        _ = try? await service.syncProjectTransaction(projectID: project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "demo/plik.txt").path),
                      "dowiązanie nie może wyprowadzić usuwania poza projekt")
    }

    /// A backup has to save what the library *means*, not the bytes of two files that no longer
    /// agree with each other.
    func testBackupOfALegacyLibraryKeepsWhatTheMigrationRecovered() async throws {
        let root = try temp()
        let data = root.appending(path: "data")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: data.appending(path: "skills/demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: data.appending(path: "skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"version":1,"skills":[{"id":"demo","name":"demo","tags":[],"source":{"kind":"local","location":"/tmp/demo"},"updatedAt":"2024-01-01T00:00:00Z"}]}"#
            .write(to: data.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        try """
        {"projects":[{"id":"5F2C8E52-9A9D-4C2B-9F62-1D0F1F4C9A11","name":"stary","path":"\(projectURL.path)","tools":["claude"],"skillIDs":["demo"],"tags":[]}]}
        """.write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: data)

        let backup = try await service.createFullBackup(applicationVersion: "test")
        try await service.restoreFullBackup(named: backup.name)

        let projects = try await service.listProjects()
        XCTAssertEqual(projects.first?.skillIDs, ["demo"], "backup zachowuje przypisania odzyskane przez migrację")
        XCTAssertEqual(projects.first?.tools, [.claude], "backup zachowuje narzędzia odzyskane przez migrację")
    }

    /// The old format held more than skills: servers, documents and this Mac's own choice.
    func testMigrationRecoversServersDocumentsAndTheGlobalChoice() async throws {
        let root = try temp()
        let data = root.appending(path: "data")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let projectID = "5F2C8E52-9A9D-4C2B-9F62-1D0F1F4C9A11"
        let serverID = "9B7C1A44-0F3E-4A21-8C55-77E2B1D0C9AA"
        try """
        {"projects":[{"id":"\(projectID)","name":"stary","path":"\(projectURL.path)","tools":["claude"],"skillIDs":[],"tags":[]}],
         "globalTools":["codex"],"globalSkillIDs":["demo"],"globalTags":["wspólne"]}
        """.write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"servers":[{"id":"\(serverID)","name":"context7","transport":"stdio","command":"npx","arguments":[],"environment":{},"headers":{},"url":"","enabled":true}],
         "projectServerIDs":{"\(projectID)":["\(serverID)"]},"projectServerTags":{"\(projectID)":["praca"]}}
        """.write(to: data.appending(path: "mcp.json"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"docs":[{"id":"zasady","name":"Zasady","tags":[],"content":"treść","updatedAt":"2024-01-01T00:00:00Z"}],
         "projectDocIDs":{"\(projectID)":["zasady"]},"projectDocTags":{"\(projectID)":["x"]}}
        """.write(to: data.appending(path: "docs.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: data)

        let projects = try await service.listProjects()
        let project = try XCTUnwrap(projects.first)
        let selection = try await service.storedSelection(for: .project(project.id))
        let global = try await service.storedSelection(for: .global)

        XCTAssertEqual(selection.serverIDs.map(\.uuidString), [serverID], "migracja odzyskuje przypisania MCP")
        XCTAssertEqual(selection.serverTags, ["praca"], "migracja odzyskuje tagi MCP")
        XCTAssertEqual(selection.docIDs, ["zasady"], "migracja odzyskuje przypisania dokumentów")
        XCTAssertEqual(global.tools, [.codex], "migracja odzyskuje wybór globalny")
        XCTAssertEqual(global.skillIDs, ["demo"], "migracja odzyskuje globalne skille")
    }

    /// Restoring must apply today's protection, not the archive's.
    func testRestoringAnOldBackupReappliesTodaysPermissions() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.saveMCPServer(MCPServer(name: "x", transport: .stdio, command: "npx"))
        let backup = try await service.createFullBackup(applicationVersion: "test")
        // An older backup, taken when the file was still created with default permissions.
        let file = root.appending(path: "data/backups/full/\(backup.name)/mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try await service.restoreFullBackup(named: backup.name)

        let permissions = ((try? FileManager.default.attributesOfItem(atPath: root.appending(path: "data/mcp.json").path)[.posixPermissions]) as? Int) ?? 0
        XCTAssertEqual(permissions, 0o600, "przywrócenie backupu nie może cofnąć ochrony uprawnień")
    }

    /// `~/.claude/skills` symlinked into a dotfiles repository is a normal setup. Cleaning up after
    /// a client the user unticked must empty it, never take the link away.
    func testCleanupNeverRemovesTheUsersOwnSymlink() async throws {
        let root = try temp()
        let home = root.appending(path: "home")
        let dotfiles = root.appending(path: "dotfiles/skills")
        let source = root.appending(path: "source/demo")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".claude/skills"), withDestinationURL: dotfiles)
        try "---\nname: demo\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setSelection(AttachmentSelection(tools: [.claude], skillIDs: ["demo"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfiles.appending(path: "demo/SKILL.md").path), "przygotowanie: skill trafił przez dowiązanie")

        // The user unticks Claude for this Mac: the skill goes, the link stays.
        try await service.setSelection(AttachmentSelection(tools: [.codex], skillIDs: ["demo"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dotfiles.appending(path: "demo").path), "zarządzany skill musi zniknąć")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appending(path: ".claude/skills").path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "dowiązanie użytkownika musi zostać nietknięte")
    }


    /// Found while re-reading my own fixes: the unreadable-file bug had three more homes. Everything
    /// that reads one of the user's files here goes on to rewrite it, so "nie dało się odczytać"
    /// must stop the write instead of starting from an empty string.
    func testUnreadableUserFilesAreNeverRewritten() async throws {
        let root = try temp()
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".codex"), withIntermediateDirectories: true)
        let toml = projectURL.appending(path: ".codex/config.toml")
        let gitignore = projectURL.appending(path: ".gitignore")
        let tomlBytes = "model = \"opus\"\n".data(using: .utf16)!
        let gitignoreBytes = "*.log\n".data(using: .utf16)!
        try tomlBytes.write(to: toml)
        try gitignoreBytes.write(to: gitignore)
        let service = try SkillboxService(root: root.appending(path: "data"))
        var project = Project(name: "p", path: projectURL.path)
        project.manageGitignore = true
        let stored = try await service.addProject(project, selection: AttachmentSelection(tools: [.codex]))
        let server = MCPServer(name: "x", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        try await service.setMCPServers(projectID: stored.id, serverIDs: [server.id], tags: [])

        await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: stored.id))

        XCTAssertEqual(try Data(contentsOf: toml), tomlBytes, "nieczytelny config.toml nie może zostać nadpisany")
        XCTAssertEqual(try Data(contentsOf: gitignore), gitignoreBytes, "nieczytelny .gitignore nie może zostać nadpisany")
    }

    // MARK: Trzecia runda — kontrola zmian recenzenta

    private func legacyLibrary() throws -> (URL, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let data = root.appending(path: "data")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: data.appending(path: "skills/demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: D\n---\n".write(to: data.appending(path: "skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"version":1,"skills":[{"id":"demo","name":"demo","tags":[],"source":{"kind":"local","location":"/tmp/demo"},"updatedAt":"2024-01-01T00:00:00Z"}]}"#
            .write(to: data.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        let id = "5F2C8E52-9A9D-4C2B-9F62-1D0F1F4C9A11"
        try """
        {"projects":[{"id":"\(id)","name":"stary","path":"\(projectURL.path)","tools":["claude"],"skillIDs":["demo"],"tags":[]}]}
        """.write(to: data.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        return (root, id)
    }

    /// The reviewer covered servers and documents. Skills come from a different legacy file and are
    /// the case where a wrong answer deletes files from the user's repositories.
    func testClearedSkillSelectionStaysClearedAfterReopening() async throws {
        let (root, _) = try legacyLibrary()
        let service = try SkillboxService(root: root.appending(path: "data"))
        var projects = try await service.listProjects()
        XCTAssertEqual(projects.first?.skillIDs, ["demo"], "przygotowanie: migracja odzyskuje skille")

        try await service.configureProject(id: try XCTUnwrap(projects.first).id, skillIDs: [], tags: [])

        let reopened = try SkillboxService(root: root.appending(path: "data"))
        projects = try await reopened.listProjects()
        XCTAssertEqual(projects.first?.skillIDs, [], "wyczyszczony wybór skilli nie może wrócić po ponownym otwarciu")
        XCTAssertEqual(projects.first?.tools, [.claude], "narzędzia, których nikt nie ruszał, zostają")
    }

    /// A save that now writes three files instead of one must still cost one recovery snapshot;
    /// ten of them is the whole history.
    func testSavingAnMCPServerStillCostsOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.saveMCPServer(MCPServer(name: "pierwszy", transport: .stdio, command: "npx"))
        let before = try await service.librarySnapshots().count

        try await service.saveMCPServer(MCPServer(name: "drugi", transport: .stdio, command: "npx"))

        let after = try await service.librarySnapshots().count
        XCTAssertEqual(after, before + 1, "jeden zapis to jeden snapshot")
    }

    /// `configuration()` now parses mcp.json and docs.json too. A broken documents file should not
    /// make the project list unreadable.
    func testACorruptLibraryFileIsNamedInTheError() async throws {
        let (root, _) = try legacyLibrary()
        try "{ to nie jest JSON".write(to: root.appending(path: "data/docs.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))

        do {
            _ = try await service.listProjects()
            XCTFail("uszkodzony plik musi zostać zgłoszony, nie przemilczany")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("docs.json"), "komunikat musi nazwać zepsuty plik: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("Kopie zapasowe"), "i powiedzieć, co z tym zrobić: \(error.localizedDescription)")
        }
    }
}
