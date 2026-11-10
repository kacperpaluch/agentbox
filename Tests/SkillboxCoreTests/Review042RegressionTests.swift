import XCTest
@testable import SkillboxCore

/// One test per defect found in the code review of 0.42.0. Each checks the effect — the file on
/// disk, the stored record, the command's outcome — rather than the helper that produced it.
final class Review042RegressionTests: AgentboxTestCase {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func folder(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func skill(at url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\ntreść\n".write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    // 1. A managed AGENTS.md edited inside the project was overwritten, and the preview said +0 -0.
    func testAGENTSEditedInTheProjectStopsSynchronizationInsteadOfBeingOverwritten() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.createDoc(id: "zasady", content: "Zasady z biblioteki\n")
        let directory = try folder(root.appending(path: "p"))
        let project = try await service.addProject(Project(name: "p", path: directory.path), selection: AttachmentSelection(tools: [.claude], docIDs: ["zasady"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let agents = directory.appending(path: "AGENTS.md")
        let edited = "Zasady z biblioteki\nnotatka dopisana w projekcie\n"
        try edited.write(to: agents, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: project.id))
        XCTAssertEqual(try String(contentsOf: agents, encoding: .utf8), edited, "dopisek zostaje na dysku")
        // Removing the document or cleaning the project would lose the same text.
        await XCTAssertThrowsErrorAsync(try await service.unsyncProject(id: project.id))
        XCTAssertEqual(try String(contentsOf: agents, encoding: .utf8), edited)

        // Moving the change into the library is the way out: identical text blocks nothing.
        try await service.saveDocContent(docID: "zasady", name: "", content: edited)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        // And a library update over an untouched file is still an ordinary update.
        try await service.saveDocContent(docID: "zasady", name: "", content: "Nowa wersja\n")
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: agents, encoding: .utf8), "Nowa wersja\n")
    }

    // 1. A manifest written before the digest existed gets one on the next sync, even a no-op one.
    func testManifestWithoutDigestIsCompletedByASyncThatWritesNothingElse() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.createDoc(id: "zasady", content: "Zasady\n")
        let directory = try folder(root.appending(path: "p"))
        let project = try await service.addProject(Project(name: "p", path: directory.path), selection: AttachmentSelection(tools: [.claude], docIDs: ["zasady"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try #"{"docID":"zasady"}"#.write(to: directory.appending(path: ".skillbox/docs-manifest.json"), atomically: true, encoding: .utf8)

        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "Zasady\ndopisek\n".write(to: directory.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: project.id))
    }

    // 2. One folder added as two projects: each synchronization removed what the other wrote.
    func testTheSameFolderCannotBecomeTwoProjects() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let first = try folder(root.appending(path: "a")), second = try folder(root.appending(path: "b"))
        _ = try await service.addProject(name: "a", path: first.path, tools: [.claude])
        await XCTAssertThrowsErrorAsync(try await service.addProject(name: "kopia", path: first.path + "/", tools: [.claude]))
        await XCTAssertThrowsErrorAsync(try await service.addProject(Project(name: "kopia", path: first.path), selection: AttachmentSelection()))
        var other = try await service.addProject(Project(name: "b", path: second.path), selection: AttachmentSelection())
        other.path = first.path
        await XCTAssertThrowsErrorAsync(try await service.updateProject(other, selection: AttachmentSelection()))
        let stored = try await service.storedProjects()
        XCTAssertEqual(stored.map(\.path).sorted(), [first.path, second.path].map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted())
    }

    // 3. A mistyped id replaced the selection with nothing and reported success.
    func testUnknownSkillOrDocumentIsRefusedAndTheSelectionStays() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill(at: root.appending(path: "source/demo")).path)
        try await service.createDoc(id: "zasady", content: "Zasady\n")
        let directory = try folder(root.appending(path: "p"))
        let project = try await service.addProject(Project(name: "p", path: directory.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"], docIDs: ["zasady"]))

        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["project", "set", "p", "--skills", "dmeo"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["docs", "assign", "p", "--docs", "zasdy"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["sync", "global", "--skills", "dmeo", "--dry-run"], service: service))
        await XCTAssertThrowsErrorAsync(try await AgentboxCommand.run(["sync", "global", "--docs", "zasdy", "--dry-run"], service: service))
        let selection = try await service.storedSelection(id: project.id)
        XCTAssertEqual(selection.skillIDs, ["demo"])
        XCTAssertEqual(selection.docIDs, ["zasady"])
    }

    // 4. A damaged settings file read as "no plugins installed", which sent every sync to the CLI.
    func testDamagedClaudeSettingsBlockThePreviewInsteadOfReadingAsNoPlugins() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let plugin = ClaudePluginDefinition(name: "demo", marketplace: "", plugin: "demo@market")
        try await service.addLibraryClaudePlugin(plugin)
        let directory = try folder(root.appending(path: "p"))
        let project = try await service.addProject(Project(name: "p", path: directory.path), selection: AttachmentSelection(tools: [.claude], claudePluginIDs: [plugin.id]))
        try fm.createDirectory(at: directory.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{ to nie jest JSON".write(to: directory.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await service.previewProjectSync(projectID: project.id))
        await XCTAssertThrowsErrorAsync(try await service.installLibraryClaudePlugins(projectPath: directory.path, ids: [plugin.id]))
    }

    // 5. Fourteen backups made in one day pushed out every older one.
    func testADayOfBackupsKeepsYesterdaysBackup() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let old = try await service.createFullBackup(applicationVersion: "test")
        let directory = root.appending(path: "data/backups/full")
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-86400)], ofItemAtPath: directory.appending(path: old.name).path)
        for _ in 0..<15 { try await service.createFullBackup(applicationVersion: "test") }

        let kept = try fm.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(kept.contains(old.name), "wczorajszy backup zostaje")
        XCTAssertEqual(kept.count, 15, "14 najnowszych i najnowszy z wczoraj")
    }

    // 9. `--tools` alone was accepted and ignored.
    func testSyncGlobalWithOnlyToolsNarrowsTheStoredChoice() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill(at: root.appending(path: "source/demo")).path)
        try await service.setSelection(AttachmentSelection(tools: [.claude, .codex], skillIDs: ["demo"]), for: .global)

        let lines = try await AgentboxCommand.run(["sync", "global", "--tools", "claude", "--dry-run"], service: service)
        XCTAssertTrue(lines.contains { $0.hasPrefix("claude: ") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("codex: +1") }, "codex nie dostaje skilla, gdy --tools go nie wymienia")
    }
}
