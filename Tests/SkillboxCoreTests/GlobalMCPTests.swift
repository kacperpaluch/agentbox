import XCTest
@testable import SkillboxCore

final class GlobalMCPTests: AgentboxTestCase {
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
    /// `.claude/settings.local.json` belongs to the user and to Claude Code, which writes its own
    /// permission decisions there. Agentbox only ever adds names to `disabledMcpServers`; a project
    /// with no global opt-out at all must leave the file untouched instead of re-serializing it.
    func testClaudeSettingsLocalIsUntouchedWhenNoGlobalServerIsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        let settings = projectURL.appending(path: ".claude/settings.local.json")
        // Written the way Claude Code writes it: insertion order, not alphabetical.
        let original = "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls:*)\"\n    ],\n    \"deny\": []\n  },\n  \"alwaysThinkingEnabled\": true\n}"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.saveMCPServer(MCPServer(name: "ctx", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
    }
    /// The same rule for a file holding nothing but `{}`: Agentbox manages no entry in it, so it is
    /// not its empty scaffold to delete.
    func testEmptyClaudeSettingsLocalIsNotDeletedWhenNothingIsManaged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        let settings = projectURL.appending(path: ".claude/settings.local.json")
        try "{}\n".write(to: settings, atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.saveMCPServer(MCPServer(name: "ctx", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{}\n")
    }
    /// Unticking a tool cleans up everything it owned in the project — the global opt-out included,
    /// which the editor can no longer even show once the tool is gone.
    func testUntickingToolAlsoCleansUpItsGlobalServerOptOut() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.apple-mail]\ncommand = \"npx\"\n".write(to: home.appending(path: ".codex/config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{\"mcpServers\":{\"hubspot\":{\"type\":\"http\",\"url\":\"https://x.test\"}}}".write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        var project = try await service.addProject(name: "app", path: projectURL.path, tools: [.codex, .claude])
        try await service.setDisabledGlobalServers(projectID: project.id, tool: .codex, names: ["apple-mail"])
        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: ["hubspot"])
        _ = try await service.syncMCP(projectID: project.id)
        let codexFile = projectURL.appending(path: ".codex/config.toml")
        let claudeSettings = projectURL.appending(path: ".claude/settings.local.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexFile.path))
        XCTAssertTrue(try String(contentsOf: claudeSettings, encoding: .utf8).contains("hubspot"))

        project.tools = []
        try await service.updateProject(project, serverIDs: [], serverTags: [])
        _ = try await service.syncMCP(projectID: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSettings.path))
    }
    /// `.claude/settings.local.json` holds no secrets and is Claude Code's own file, so it is only
    /// excluded once Agentbox actually writes an opt-out into it — and never under the heading that
    /// warns about secrets.
    func testClaudeSettingsIsExcludedOnlyWhenManagedAndUnderItsOwnHeading() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".git/info"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "{\"mcpServers\":{\"hubspot\":{\"type\":\"http\",\"url\":\"https://x.test\"}}}".write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.saveMCPServer(MCPServer(name: "ctx", transport: .stdio, command: "npx"))
        let servers = try await service.mcpConfiguration().servers.map(\.id)
        try await service.setMCPServers(projectID: project.id, serverIDs: servers, tags: [])
        _ = try await service.syncMCP(projectID: project.id)
        let exclude = projectURL.appending(path: ".git/info/exclude")
        let withoutOptOut = try String(contentsOf: exclude, encoding: .utf8)
        XCTAssertTrue(withoutOptOut.contains(".mcp.json"))
        XCTAssertFalse(withoutOptOut.contains(".claude/settings.local.json"), withoutOptOut)

        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: ["hubspot"])
        _ = try await service.syncMCP(projectID: project.id)
        let withOptOut = try String(contentsOf: exclude, encoding: .utf8)
        XCTAssertTrue(withOptOut.contains(".claude/settings.local.json"), withOptOut)
        // It must sit under its own heading, not the one about secrets.
        let lines = withOptOut.split(whereSeparator: \.isNewline).map(String.init)
        let index = try XCTUnwrap(lines.firstIndex(of: ".claude/settings.local.json"))
        let heading = try XCTUnwrap(lines[..<index].last { $0.hasPrefix("#") })
        XCTAssertFalse(heading.contains("sekrety"), heading)
    }
    /// Claude Code's opt-out is a managed file like any other, so a transaction that fails after it
    /// was written must put it back. It lives outside `MCPPreview.content`, and leaving it out of the
    /// rollback targets left the opt-out in the project while `mcp-manifest.json` was restored
    /// without it — the next sync then no longer recognised the name as ours and never cleaned it up.
    func testFailedTransactionRollsBackTheClaudeGlobalOptOut() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        let settings = projectURL.appending(path: ".claude/settings.local.json")
        let original = "{\n  \"permissions\" : {\n    \"allow\" : [\n      \"Bash\"\n    ]\n  }\n}\n"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "app", path: projectURL.path, tools: [.claude])
        try await service.setDisabledGlobalServers(projectID: project.id, tool: .claude, names: ["hubspot"])

        // A document makes the sync reach its docs step, which is the one made to fail below.
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "# Guidelines")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        // Stands in for any later write failing: the docs manifest cannot be written over a
        // directory, and the preview cannot see that coming because it never writes the manifest.
        try FileManager.default.createDirectory(at: projectURL.appending(path: ".skillbox/docs-manifest.json"), withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: project.id))

        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/mcp-manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path))
    }
    /// Opting out is per project, so without a default a project added next month silently gets the
    /// global server back. The default applies when a selection is created — and only then, so
    /// projects that already exist are never changed behind the user's back.
    func testDefaultDisabledGlobalServerAppliesToNewProjectsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let existing = root.appending(path: "stary")
        let fresh = root.appending(path: "nowy")
        let folder = root.appending(path: "praca/sklep")
        for url in [existing, fresh, folder] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let service = try SkillboxService(root: root.appending(path: "data"))

        let old = try await service.addProject(name: "stary", path: existing.path, tools: [.codex])
        try await service.setDefaultDisabledGlobalServers(tool: .codex, names: ["apple_mail"])
        let defaults = try await service.defaultDisabledGlobalServers()
        XCTAssertEqual(defaults, [Tool.codex: ["apple_mail"]])

        // The project that already existed keeps whatever it had: nothing.
        let oldState = try await service.disabledGlobalServers(projectID: old.id)
        XCTAssertEqual(oldState, [:])

        let new = try await service.addProject(name: "nowy", path: fresh.path, tools: [.codex])
        let newState = try await service.disabledGlobalServers(projectID: new.id)
        XCTAssertEqual(newState, [Tool.codex: ["apple_mail"]])

        // A new folder owns the selection its projects follow, so the default lands there too.
        _ = try await AgentboxCommand.run(["project", "root-add", "praca", root.appending(path: "praca").path, "--tools", "codex", "--folders", "sklep"], service: service)
        let projects = try await service.listProjects()
        let inFolder = try XCTUnwrap(projects.first { $0.name == "sklep" })
        let folderState = try await service.disabledGlobalServers(projectID: inFolder.id)
        XCTAssertEqual(folderState, [Tool.codex: ["apple_mail"]])

        // Turning the default off again leaves every existing project exactly as it is.
        try await service.setDefaultDisabledGlobalServers(tool: .codex, names: [])
        let clearedDefaults = try await service.defaultDisabledGlobalServers()
        XCTAssertEqual(clearedDefaults, [:])
        let stillDisabled = try await service.disabledGlobalServers(projectID: new.id)
        XCTAssertEqual(stillDisabled, [Tool.codex: ["apple_mail"]])
    }
}
