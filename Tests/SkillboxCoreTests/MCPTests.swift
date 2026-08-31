import XCTest
@testable import SkillboxCore

final class MCPTests: AgentboxTestCase {
    func testDuplicateMCPServerCreatesIndependentFullConfiguration() {
        let server = MCPServer(
            name: "actual-budget",
            transport: .http,
            url: "https://actual.example/mcp",
            headers: ["X-Token": "ACTUAL_TOKEN"],
            enabled: false,
            literalEnvironment: ["REGION": "home"],
            literalHeaders: ["Authorization": "Bearer dummy-secret"],
            tags: ["finance"]
        )

        let copy = server.duplicated(name: "actual-budget-tailscale")

        XCTAssertNotEqual(copy.id, server.id)
        XCTAssertEqual(copy.name, "actual-budget-tailscale")
        XCTAssertEqual(copy.transport, server.transport)
        XCTAssertEqual(copy.url, server.url)
        XCTAssertEqual(copy.headers, server.headers)
        XCTAssertEqual(copy.literalEnvironment, server.literalEnvironment)
        XCTAssertEqual(copy.literalHeaders, server.literalHeaders)
        XCTAssertEqual(copy.enabled, server.enabled)
        XCTAssertEqual(copy.tags, server.tags)
    }

    func testDuplicateMCPServerPersistsAnExactCopyUnderNewName() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "actual-budget", transport: .http, url: "https://actual.example/mcp", headers: ["X-Token": "ACTUAL_TOKEN"], enabled: false, literalEnvironment: ["REGION": "home"], literalHeaders: ["Authorization": "Bearer dummy-secret"], secretEnvironment: ["LEGACY_TOKEN": "actual-token"], secretHeaders: ["X-Legacy": "actual-header"], tags: ["finance"])
        try await service.saveMCPServer(server)

        let copy = try await service.duplicateMCPServer(id: server.id, name: "actual-budget-tailscale")
        let configuration = try await service.mcpConfiguration()
        let stored = try XCTUnwrap(configuration.servers.first { $0.id == copy.id })

        XCTAssertNotEqual(stored.id, server.id)
        XCTAssertEqual(stored.name, "actual-budget-tailscale")
        XCTAssertEqual(stored.transport, server.transport)
        XCTAssertEqual(stored.command, server.command)
        XCTAssertEqual(stored.arguments, server.arguments)
        XCTAssertEqual(stored.url, server.url)
        XCTAssertEqual(stored.environment, server.environment)
        XCTAssertEqual(stored.headers, server.headers)
        XCTAssertEqual(stored.literalEnvironment, server.literalEnvironment)
        XCTAssertEqual(stored.literalHeaders, server.literalHeaders)
        XCTAssertEqual(stored.secretEnvironment, server.secretEnvironment)
        XCTAssertEqual(stored.secretHeaders, server.secretHeaders)
        XCTAssertEqual(stored.enabled, server.enabled)
        XCTAssertEqual(stored.tags, server.tags)
    }

    func testAIPromptRequiresMCPWrapperAndEnvironmentReferencesForSecrets() {
        let prompt = SkillboxService.mcpAIPrompt("Use the token from the docs")
        XCTAssertTrue(prompt.contains("{\"mcpServers\": {...}}"))
        XCTAssertTrue(prompt.contains("${GITHUB_TOKEN}"))
        XCTAssertTrue(prompt.contains("Nigdy nie wymyślaj"))
        XCTAssertTrue(prompt.contains("Use the token from the docs"))
    }

    func testImportsSingleServerDefinitionWithoutMistakingEnvironmentForServer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"args":["--from","mcp-portainer~=2.45.0","mcp-portainer"],"command":"uvx","env":{"PORTAINER_URL":"https://twoj-portainer.pl","PORTAINER_API_KEY":"ptr_dummy-secret"}}"#

        let analyzed = try await service.analyzeMCPJSON(json)
        XCTAssertTrue(analyzed.isSingleServerInput)
        XCTAssertEqual(analyzed.servers.map(\.name), ["mcp-portainer"])
        XCTAssertEqual(analyzed.servers.first?.command, "uvx")
        XCTAssertEqual(analyzed.servers.first?.arguments, ["--from", "mcp-portainer~=2.45.0", "mcp-portainer"])
        XCTAssertEqual(analyzed.servers.first?.literalEnvironment?["PORTAINER_URL"], "https://twoj-portainer.pl")
        XCTAssertEqual(analyzed.servers.first?.literalEnvironment?["PORTAINER_API_KEY"], "ptr_dummy-secret")

        let imported = try await service.importMCPJSON(json, singleServerName: "portainer")
        XCTAssertEqual(imported.servers.map(\.name), ["portainer"])
        let saved = try await service.mcpConfiguration()
        XCTAssertEqual(saved.servers.map(\.name), ["portainer"])
    }

    func testImportsSingleServerWithMacOSTypographicQuotes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{“args”: [“-y”, “actual-mcp-server”, “--stdio”], “command”: “npx”, “env”: {“ACTUAL_SERVER_URL”: “http://example.test:5006”}}"#

        let analyzed = try await service.analyzeMCPJSON(json)

        XCTAssertTrue(analyzed.isSingleServerInput)
        XCTAssertEqual(analyzed.servers.map(\.name), ["actual-mcp-server"])
        XCTAssertEqual(analyzed.servers.first?.command, "npx")
        XCTAssertEqual(analyzed.servers.first?.literalEnvironment?["ACTUAL_SERVER_URL"], "http://example.test:5006")
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
    func testImportKeepsLiteralValuesInLocalConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let json = #"{"custom":{"command":"tool","env":{"CREDENTIAL":"hidden-value","TOKEN_LIMIT":"4096"}}}"#
        let analyzed = try await service.analyzeMCPJSON(json)
        XCTAssertEqual(analyzed.fields.first(where: { $0.key == "CREDENTIAL" })?.classification, .literal)
        XCTAssertEqual(analyzed.fields.first(where: { $0.key == "TOKEN_LIMIT" })?.classification, .literal)
        let imported = try await service.importMCPJSON(json)
        let server = try XCTUnwrap(imported.servers.first)
        XCTAssertEqual(server.literalEnvironment?["CREDENTIAL"], "hidden-value")
        XCTAssertEqual(server.literalEnvironment?["TOKEN_LIMIT"], "4096")
    }
    func testProjectSelectsMCPServersBothDirectlyAndByTag() async throws {
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
        XCTAssertEqual(updated.literalEnvironment?["API_KEY"], "sk-secret")
        let managedAfterUpdate = try await service.managedFields(serverID: server.id)
        XCTAssertEqual(managedAfterUpdate.first { $0.key == "API_KEY" }?.value, "sk-secret")

        // Typing a value for a key that does not look like a secret keeps it a plain, backed-up value.
        let plain = #"{"command":"npx2","args":["-y","pkg"],"env":{"REGION":"eu-west-1"}}"#
        let final = try await service.updateMCPServerJSON(server.id, name: "api", json: plain, enabled: true, tags: ["seo"])
        XCTAssertEqual(final.literalEnvironment?["REGION"], "eu-west-1")
        XCTAssertNil(final.secretEnvironment)
    }
    func testReimportingServerReplacesItsLocalValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let server = MCPServer(name: "api", transport: .http, url: "https://example.test/mcp")
        try await service.saveMCPServer(server)
        try await service.saveMCPServer(server, managedFields: [MCPManagedField(location: .header, key: "Authorization", value: "dummy-old", classification: .literal)])

        _ = try await service.importMCPJSON(#"{"api":{"type":"http","url":"https://example.test/mcp","headers":{"Authorization":"Bearer dummy-new"}}}"#)
        let updated = try await service.mcpConfiguration().servers.first
        XCTAssertEqual(updated?.literalHeaders?["Authorization"], "Bearer dummy-new")
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
}
