import XCTest
@testable import SkillboxCore

/// One test per defect found in the code review of 0.28.0. Each checks the effect — Git's answer,
/// the file on disk, the command's outcome — rather than the helper that produced it.
final class Review029RegressionTests: AgentboxTestCase {
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func folder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func skill(at url: URL, body: String = "treść") throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n\(body)\n".write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    // 1. A token written into a `.mcp.json` the repository already tracks.
    func testLocalValueIsNeverWrittenIntoATrackedMCPFile() async throws {
        let root = try temp()
        let project = try folder(root.appending(path: "project"))
        try runGit(["init", "-q"], in: project)
        let original = "{\n  \"mcpServers\" : {}\n}\n"
        try original.write(to: project.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        try runGit(["add", ".mcp.json"], in: project)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let server = MCPServer(name: "gh", transport: .http, url: "https://example.com/mcp", literalHeaders: ["Authorization": "Bearer dummy-secret"])
        try await service.saveMCPServer(server)
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], serverIDs: [server.id]))

        await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: added.id))

        XCTAssertEqual(try String(contentsOf: project.appending(path: ".mcp.json"), encoding: .utf8), original, "token nie może trafić do pliku śledzonego przez Git")
        XCTAssertEqual(try gitOutput(["diff", "--name-only"], in: project), "")
    }

    // 1b. A reference is not a secret, so a tracked file still receives it.
    func testReferenceIsStillWrittenIntoATrackedMCPFile() async throws {
        let root = try temp()
        let project = try folder(root.appending(path: "project"))
        try runGit(["init", "-q"], in: project)
        try "{}\n".write(to: project.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        try runGit(["add", ".mcp.json"], in: project)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let server = MCPServer(name: "gh", transport: .http, url: "https://example.com/mcp", headers: ["Authorization": "GH_TOKEN"])
        try await service.saveMCPServer(server)
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], serverIDs: [server.id]))

        try await service.syncProjectTransaction(projectID: added.id)

        XCTAssertTrue(try String(contentsOf: project.appending(path: ".mcp.json"), encoding: .utf8).contains("Bearer ${GH_TOKEN}"))
    }

    // 1c. A generated file that can hold a token is readable only by its owner.
    func testGeneratedMCPFileIsPrivate() async throws {
        let root = try temp()
        let project = try folder(root.appending(path: "project"))
        let service = try SkillboxService(root: root.appending(path: "data"))
        let server = MCPServer(name: "gh", transport: .http, url: "https://example.com/mcp", literalHeaders: ["Authorization": "Bearer dummy-secret"])
        try await service.saveMCPServer(server)
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], serverIDs: [server.id]))

        try await service.syncProjectTransaction(projectID: added.id)

        let mode = try FileManager.default.attributesOfItem(atPath: project.appending(path: ".mcp.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    // 2. A skill at the root of a repository brought the repository's `.git` along.
    func testSkillAtRepositoryRootIsImportedWithoutItsGitDirectory() async throws {
        let root = try temp()
        let repository = try skill(at: root.appending(path: "repo"))
        try runGit(["init", "-q"], in: repository)
        try runGit(["add", "."], in: repository)
        try runGit(["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init"], in: repository)
        let project = try folder(root.appending(path: "project"))
        try runGit(["init", "-q"], in: project)
        let data = root.appending(path: "data")
        let service = try SkillboxService(root: data)

        let result = try await service.addGitCollection(url: "file://\(repository.path)")
        let id = try XCTUnwrap(result.imported.first?.id)
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], skillIDs: [id]))
        try await service.syncProjectTransaction(projectID: added.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appending(path: "skills/\(id)/.git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(path: "skills/\(id)/SKILL.md").path))
        // Git's own answer: the skill is ordinary files, not an embedded repository.
        try runGit(["add", ".claude"], in: project)
        XCTAssertFalse(try gitOutput(["ls-files", "-s"], in: project).contains("160000"))
        XCTAssertTrue(try gitOutput(["ls-files"], in: project).contains(".claude/skills/\(id)/SKILL.md"))
    }

    // 2b. A library written by an older version still holds `.git`; it must not reach projects.
    func testGitDirectoryLeftInLibraryIsNotCopiedIntoProjects() async throws {
        let root = try temp()
        let project = try folder(root.appending(path: "project"))
        let data = root.appending(path: "data")
        let service = try SkillboxService(root: data)
        try await service.addLocal(path: try skill(at: root.appending(path: "demo")).path)
        try "[core]\n".write(to: try folder(data.appending(path: "skills/demo/.git")).appending(path: "config"), atomically: true, encoding: .utf8)
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))

        try await service.syncProjectTransaction(projectID: added.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appending(path: ".claude/skills/demo/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appending(path: ".claude/skills/demo/.git").path))
    }

    // 3. A symlinked folder became a symlink in the library instead of a copy.
    func testSymlinkedSkillFolderIsCopiedIntoTheLibrary() async throws {
        let root = try temp()
        let real = try skill(at: root.appending(path: "real/demo"))
        let link = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let data = root.appending(path: "data")
        let service = try SkillboxService(root: data)

        let added = try await service.addLocal(path: link.path)

        let type = try FileManager.default.attributesOfItem(atPath: data.appending(path: "skills/\(added.id)").path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeDirectory, "biblioteka ma trzymać kopię, nie dowiązanie")
        try FileManager.default.removeItem(at: real)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(path: "skills/\(added.id)/SKILL.md").path))
    }

    // 4. An SSE server was imported as HTTP and rendered with the wrong transport.
    func testSSEServerKeepsItsTransport() async throws {
        let root = try temp()
        let project = try folder(root.appending(path: "project"))
        let service = try SkillboxService(root: root.appending(path: "data"))

        let summary = try await service.importMCPJSON(#"{"mcpServers":{"events":{"type":"sse","url":"https://example.com/sse"}}}"#)
        let server = try XCTUnwrap(summary.servers.first)
        XCTAssertEqual(server.transport.rawValue, "sse")
        let added = try await service.addProject(Project(name: "p", path: project.path), selection: AttachmentSelection(tools: [.claude], serverIDs: [server.id]))
        try await service.syncProjectTransaction(projectID: added.id)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: project.appending(path: ".mcp.json"))) as? [String: Any]
        let entry = (written?["mcpServers"] as? [String: Any])?["events"] as? [String: Any]
        XCTAssertEqual(entry?["type"] as? String, "sse")
        let exported = try await service.exportMCPServerJSON(server.id)
        XCTAssertTrue(exported.contains(#""type" : "sse""#))
    }

    // 5. Header references: only the shapes the renderers write back are references.
    func testHeaderReferenceKeepsExactlyWhatWasTyped() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let json = #"{"mcpServers":{"api":{"url":"https://example.com","headers":{"Authorization":"${RAW_TOKEN}","X-Key":"Bearer ${K}","X-Plain":"${P}"}}}}"#

        let imported = try await service.importMCPJSON(json)
        let server = try XCTUnwrap(imported.servers.first)

        XCTAssertEqual(server.literalHeaders?["Authorization"], "${RAW_TOKEN}", "bez Bearer nie wolno dopisać Bearer przy renderowaniu")
        XCTAssertEqual(server.literalHeaders?["X-Key"], "Bearer ${K}", "Bearer w innym nagłówku nie może zniknąć")
        XCTAssertEqual(server.headers["X-Plain"], "P")
        let second = try await service.importMCPJSON(#"{"mcpServers":{"b":{"url":"https://example.com","headers":{"authorization":"Bearer ${T}"}}}}"#)
        let bearer = try XCTUnwrap(second.servers.first)
        XCTAssertEqual(bearer.headers["authorization"], "T")
    }

    // 6. Pointing a project at another folder left the old one full of managed files.
    func testChangingProjectPathCleansUpTheOldFolder() async throws {
        let root = try temp()
        let old = try folder(root.appending(path: "old"))
        let new = try folder(root.appending(path: "new"))
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.addLocal(path: try skill(at: root.appending(path: "demo")).path)
        var project = try await service.addProject(Project(name: "p", path: old.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appending(path: ".claude/skills/demo").path))

        project.path = new.path
        try await service.updateProject(project, selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appending(path: ".claude/skills/demo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appending(path: ".claude/skills/.skillbox.json").path))
    }

    // 7. `agentbox update <skill>` exited 0 when the skill could not be updated.
    func testFailedUpdateMakesTheCommandFail() async throws {
        let root = try temp()
        let source = try skill(at: root.appending(path: "demo"))
        let service = try SkillboxService(root: root.appending(path: "data"))
        try await service.addLocal(path: source.path)
        try FileManager.default.removeItem(at: source)

        do {
            _ = try await AgentboxCommand.run(["update", "demo"], service: service)
            XCTFail("nieudana aktualizacja musi zakończyć polecenie błędem")
        } catch let partial as AgentboxCommand.PartialFailure {
            XCTAssertTrue(partial.lines.contains { $0.hasPrefix("✗ demo") })
        }
    }

    // 8. A copy kept in the temporary directory is not kept forever, and the message says so.
    func testRollbackMessageWarnsThatTemporaryCopiesExpire() {
        var report = RollbackReport()
        report.attempt("plik") { throw SkillboxError.commandFailed("dysk") }
        let path = FileManager.default.temporaryDirectory.appending(path: "agentbox-sync-x").path
        let message = report.error(after: SkillboxError.commandFailed("zapis"), keeping: path).localizedDescription
        XCTAssertTrue(message.contains("katalog tymczasowy"))
    }
}
