import XCTest
@testable import SkillboxCore

final class ProjectTests: AgentboxTestCase {
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
        let addedSelection = try await service.storedSelection(id: added.id)
        XCTAssertEqual(addedSelection.serverIDs, [], "tag wciąga serwer, więc jego id jest zbędne")

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
        let alphaSelection = try await service.storedSelection(id: alpha.id)
        XCTAssertEqual(alphaSelection.serverIDs, [server.id])
        let remainingRoots = try await service.projectRoots()
        XCTAssertTrue(remainingRoots.isEmpty)
    }
    /// A library written before parent folders existed must keep working, and a folder must not be
    /// able to hand a project a skill that was deleted from the library.
    func testDeletedSkillLeavesEveryPlaceThatSelectedIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = root.appending(path: "data")
        let source = root.appending(path: "source/demo")
        let folderPath = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderPath.appending(path: "alpha"), withIntermediateDirectories: true)
        let service = try SkillboxService(root: library)
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
        let folderSelection = try await service.storedSelection(id: stored.id)
        let followerSelection = try await service.storedSelection(id: alpha.id)
        XCTAssertEqual(folderSelection.serverIDs, [server.id])
        XCTAssertTrue(followerSelection.isEmpty, "stary wybór MCP nie zostaje jako druga prawda")
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
}
