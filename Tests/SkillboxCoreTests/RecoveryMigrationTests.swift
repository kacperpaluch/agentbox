import XCTest
@testable import SkillboxCore

final class RecoveryMigrationTests: AgentboxTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func legacy() throws -> (SkillboxService, URL, UUID, UUID) {
        let root = try temporary(), project = UUID(), server = UUID()
        try """
        {"projects":[{"id":"\(project)","name":"old","path":"\(root.path)","tools":["claude"],"skillIDs":[],"tags":[]}]}
        """.write(to: root.appending(path: "projects.local.json"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"servers":[{"id":"\(server)","name":"old","transport":"stdio","command":"echo","url":"","arguments":[],"environment":{},"headers":{},"enabled":true}],"projectServerIDs":{"\(project)":["\(server)"]}}
        """.write(to: root.appending(path: "mcp.json"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"docs":[{"id":"rules","name":"Rules","tags":[],"content":"Rules","updatedAt":"2024-01-01T00:00:00Z"}],"projectDocIDs":{"\(project)":["rules"]}}
        """.write(to: root.appending(path: "docs.json"), atomically: true, encoding: .utf8)
        return (try SkillboxService(root: root), root, project, server)
    }

    func testClearedLegacyAssignmentsStayEmptyAfterReopening() async throws {
        let (service, root, project, _) = try legacy()
        try await service.setMCPServers(projectID: project, serverIDs: [], tags: [])
        try await service.setDocs(projectID: project, docIDs: [], tags: [])
        let reopened = try SkillboxService(root: root)
        let selection = try await reopened.storedSelection(for: .project(project))
        XCTAssertEqual(selection.serverIDs, [])
        XCTAssertEqual(selection.docIDs, [])
        XCTAssertEqual(selection.tools, [.claude])
    }

    func testFirstMCPDefinitionWritePersistsAllLegacyAssignments() async throws {
        let (service, root, project, server) = try legacy()
        try await service.saveMCPServer(MCPServer(name: "new", transport: .stdio, command: "echo"))
        let reopened = try SkillboxService(root: root)
        let selection = try await reopened.storedSelection(for: .project(project))
        XCTAssertEqual(selection.serverIDs, [server])
        XCTAssertEqual(selection.docIDs, ["rules"])
        let raw = try String(contentsOf: root.appending(path: "selections.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains(server.uuidString))
    }

    func testFirstDocumentWritePersistsAllLegacyAssignments() async throws {
        let (service, root, project, server) = try legacy()
        _ = try await service.createDoc(id: "new", content: "New")
        let reopened = try SkillboxService(root: root)
        let selection = try await reopened.storedSelection(for: .project(project))
        XCTAssertEqual(selection.docIDs, ["rules"])
        XCTAssertEqual(selection.serverIDs, [server])
    }

    /// A backup from before `selections.json` restores the assignments it recorded, not the ones
    /// the library had when it was restored.
    func testRestoringABackupWithoutSelectionsBringsBackItsOwnAssignments() async throws {
        let (service, root, project, server) = try legacy()
        try FileManager.default.createDirectory(at: root.appending(path: "skills"), withIntermediateDirectories: true)
        try #"{"version":1,"skills":[]}"#.write(to: root.appending(path: "catalog.json"), atomically: true, encoding: .utf8)
        // What an old version left in `backups/full`: the files in their own, pre-selections format.
        let legacyFiles = try ["projects.local.json", "mcp.json", "docs.json"].map { ($0, try Data(contentsOf: root.appending(path: $0))) }
        let backup = try await service.createFullBackup(applicationVersion: "test")
        let package = root.appending(path: "backups/full/\(backup.name)")
        try FileManager.default.removeItem(at: package.appending(path: "selections.json"))
        for (name, data) in legacyFiles { try data.write(to: package.appending(path: name)) }

        try await service.setMCPServers(projectID: project, serverIDs: [], tags: [])
        try await service.setDocs(projectID: project, docIDs: [], tags: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "selections.json").path))

        try await service.restoreFullBackup(named: backup.name)
        let selection = try await SkillboxService(root: root).storedSelection(for: .project(project))
        XCTAssertEqual(selection.serverIDs, [server])
        XCTAssertEqual(selection.docIDs, ["rules"])
    }

    func testFailedMigrationDoesNotOverwriteLegacySources() async throws {
        let (service, root, _, _) = try legacy()
        let mcp = root.appending(path: "mcp.json"), local = root.appending(path: "projects.local.json")
        let beforeMCP = try Data(contentsOf: mcp), beforeLocal = try Data(contentsOf: local)
        try Data("{broken".utf8).write(to: root.appending(path: "docs.json"))
        await XCTAssertThrowsErrorAsync(try await service.saveMCPServer(MCPServer(name: "new", transport: .stdio, command: "echo")))
        XCTAssertEqual(try Data(contentsOf: mcp), beforeMCP)
        XCTAssertEqual(try Data(contentsOf: local), beforeLocal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "selections.json").path))
    }

    func testSnapshotRestoresMissingSensitiveFilePrivately() async throws {
        let root = try temporary(), service = try SkillboxService(root: root)
        let server = MCPServer(name: "test", transport: .stdio, command: "echo", literalEnvironment: ["TOKEN": "dummy-secret"])
        try await service.saveMCPServer(server)
        _ = try await service.createDoc(id: "rules", content: "Rules")
        let snapshots = try await service.librarySnapshots()
        let snapshot = try XCTUnwrap(snapshots.first { $0.files.contains("mcp.json") })
        let mcp = root.appending(path: "mcp.json")
        try FileManager.default.removeItem(at: mcp)
        _ = try await service.restoreLibrarySnapshot(named: snapshot.name)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mcp.path)[.posixPermissions] as? Int, 0o600)
        let restored = try await service.mcpConfiguration()
        XCTAssertEqual(restored.servers.first?.literalEnvironment?["TOKEN"], "dummy-secret")
    }

    func testFailedRollbackKeepsRealPrivateCopiesAndReportsBothErrors() throws {
        let root = try temporary(), fm = FileManager.default
        let file = root.appending(path: "settings.json")
        try Data("original".utf8).write(to: file)
        let rollback = try FileRollback(files: [file])
        defer { try? fm.removeItem(at: rollback.directory) }
        XCTAssertThrowsError(try rollback.perform {
            try fm.removeItem(at: file)
            try fm.createDirectory(at: file.appending(path: "blocker"), withIntermediateDirectories: true)
            throw SkillboxError.commandFailed("original failure")
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("original failure"))
            XCTAssertTrue(error.localizedDescription.contains("cofanie zmian też się nie powiodło"))
            XCTAssertTrue(error.localizedDescription.contains(rollback.directory.path))
        }
        let copy = rollback.directory.appending(path: "0-settings.json")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "original")
        XCTAssertEqual(try fm.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try fm.attributesOfItem(atPath: rollback.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertTrue(fm.fileExists(atPath: file.appending(path: "blocker").path))
    }

    func testRollbackRestoresExistingAndRemovesNewFiles() throws {
        let root = try temporary(), fm = FileManager.default
        let existing = root.appending(path: "mcp.json"), new = root.appending(path: "new.json")
        try Data("original".utf8).write(to: existing)
        let rollback = try FileRollback(files: [existing, new])
        XCTAssertThrowsError(try rollback.perform {
            try Data("changed".utf8).write(to: existing)
            try Data("new".utf8).write(to: new)
            throw SkillboxError.commandFailed("test")
        })
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertFalse(fm.fileExists(atPath: new.path))
        XCTAssertFalse(fm.fileExists(atPath: rollback.directory.path))
        XCTAssertEqual(try fm.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int, 0o600)
    }

    func testUnreadableOriginalStopsBeforeAnyWrite() throws {
        let root = try temporary(), file = root.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: file.appending(path: "valuable"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileRollback(files: [file]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appending(path: "valuable").path))
    }

    func testMovedSkillSurvivesFailedRestoration() throws {
        let root = try temporary(), fm = FileManager.default
        let original = root.appending(path: "skills/demo"), scratch = root.appending(path: "scratch")
        let saved = scratch.appending(path: "demo")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("original skill".utf8).write(to: original.appending(path: "SKILL.md"))
        try fm.moveItem(at: original, to: saved)
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let error = SkillboxService.restoring([(from: original, to: saved)], after: SkillboxError.commandFailed("save failed"), scratch: scratch)
        XCTAssertTrue(error.localizedDescription.contains("save failed"))
        XCTAssertTrue(error.localizedDescription.contains(scratch.path))
        XCTAssertEqual(try String(contentsOf: saved.appending(path: "SKILL.md"), encoding: .utf8), "original skill")
    }
}
