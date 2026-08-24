import Foundation
import SkillboxCore

@main
struct AgentboxCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Błąd: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else { printHelp(); return }
        if ["help", "--help", "-h"].contains(command) { printHelp(); return }
        let customRoot = ProcessInfo.processInfo.environment["SKILLBOX_HOME"].map { URL(fileURLWithPath: $0) } ?? AgentboxRootPreference.load()
        let service = try SkillboxService(root: customRoot)
        switch command {
        case "list":
            for skill in try await service.listSkills() { print("\(skill.id)\t\(skill.tags.joined(separator: ","))\t\(skill.source.kind.rawValue)") }
        case "add":
            guard args.count >= 2 else { throw SkillboxError.invalidSkill("podaj ścieżkę lub URL") }
            let value = args[1], subpath = option("--path", in: args), branch = option("--branch", in: args), id = option("--id", in: args)
            if value.contains("://") || value.hasSuffix(".git") {
                let skills = try await service.addGitCollection(url: value, subpath: subpath, branch: branch, id: id)
                print("Dodano \(skills.count): \(skills.map(\.id).joined(separator: ", "))")
            } else {
                let skill = try await service.addLocal(path: value, id: id); print("Dodano \(skill.id)")
            }
        case "tag":
            guard args.count >= 3 else { print("Użycie: agentbox tag <skill> <tag...>"); return }
            try await service.setTags(skillID: args[1], tags: Array(args.dropFirst(2))); print("Zapisano tagi")
        case "update":
            guard args.count >= 2 else { print("Użycie: agentbox update <skill|--all>"); return }
            if args[1] == "--all" {
                print("Sprawdzanie aktualizacji…")
                let ids = try await service.checkUpdates().sorted()
                guard !ids.isEmpty else { print("Wszystkie skille są aktualne"); return }
                print("Dostępne aktualizacje: \(ids.count)")
                for id in ids { _ = try await service.update(skillID: id); print("Zaktualizowano \(id)") }
            } else {
                _ = try await service.update(skillID: args[1]); print("Zaktualizowano \(args[1])")
            }
        case "project": try await projectCommand(service, Array(args.dropFirst()))
        case "sync": try await syncCommand(service, Array(args.dropFirst()))
        case "refresh": try await refreshCommand(service, args)
        case "backup":
            let output = try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Skillbox backup")
            print(output)
        case "mcp": try await mcpCommand(service, Array(args.dropFirst()))
        default: printHelp()
        }
    }

    static func refreshCommand(_ service: SkillboxService, _ args: [String]) async throws {
        print("1/4 Sprawdzanie aktualizacji skilli…")
        let updates = try await service.checkUpdates().sorted()
        if updates.isEmpty { print("Wszystkie skille są aktualne") }
        else { for id in updates { _ = try await service.update(skillID: id); print("Zaktualizowano \(id)") } }

        print("2/4 Tworzenie pełnego backupu lokalnego…")
        let local = try await service.createFullBackup(applicationVersion: "CLI")
        print("Utworzono \(local.name)")

        print("3/4 Tworzenie backupu Git…")
        let git = try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Agentbox refresh", push: true, requireRemote: true)
        print(git)

        print("4/4 Synchronizacja projektów…")
        let projects = try await service.listProjects()
        for project in projects {
            let preview = try await service.syncProjectTransaction(projectID: project.id)
            let skillChanges = preview.skills.reduce(0) { $0 + $1.added.count + $1.updated.count + $1.removed.count }
            print("Zsynchronizowano \(project.name): \(skillChanges) operacji na skillach, \(preview.mcp.count) plików MCP")
        }
        print("Gotowe: zaktualizowano \(updates.count) skilli i zsynchronizowano \(projects.count) projektów")
    }

    static func projectCommand(_ service: SkillboxService, _ args: [String]) async throws {
        guard let action = args.first else { return }
        if action == "list" { for item in try await service.listProjects() { print("\(item.name)\t\(item.path)\t\(item.tools.map(\.rawValue).joined(separator: ","))") }; return }
        if action == "add", args.count >= 3 {
            let tools = (option("--tools", in: args) ?? "claude,codex,opencode").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
            let project = try await service.addProject(name: args[1], path: args[2], tools: tools); print("Dodano projekt \(project.name)"); return
        }
        if action == "set", args.count >= 2 {
            try await service.configureProject(name: args[1], skillIDs: csvOption("--skills", in: args), tags: csvOption("--tags", in: args)); print("Zapisano projekt"); return
        }
        print("Użycie: agentbox project add <nazwa> <folder> [--tools claude,codex,opencode] | set <nazwa> [--skills a,b] [--tags web,seo] | list")
    }

    static func syncCommand(_ service: SkillboxService, _ args: [String]) async throws {
        guard args.count >= 2 else { print("Użycie: agentbox sync project <nazwa> | global <tool> --skills a,b [--tags x]"); return }
        let dry = args.contains("--dry-run")
        if args[0] == "project" {
            for (tool, result) in try await service.syncProject(name: args[1], dryRun: dry) { print("\(tool.rawValue): +\(result.copied.count) -\(result.removed.count)") }
        } else if args[0] == "global", let tool = Tool(rawValue: args[1]) {
            let result = try await service.syncGlobal(tool: tool, skillIDs: csvOption("--skills", in: args), tags: csvOption("--tags", in: args), dryRun: dry)
            print("\(tool.rawValue): +\(result.copied.count) -\(result.removed.count)")
        }
    }

    static func mcpCommand(_ service: SkillboxService, _ args: [String]) async throws {
        guard let action = args.first else { print("Użycie: agentbox mcp list|server|assign|preview|sync"); return }
        let config = try await service.mcpConfiguration()
        switch action {
        case "list":
            for server in config.servers { print("server\t\(server.name)\t\(server.transport.rawValue)\t\((server.tags ?? []).joined(separator: ","))") }
        case "server" where args.count >= 3 && args[1] == "add":
            let name = args[2]
            if let url = option("--url", in: args) { try await service.saveMCPServer(MCPServer(name: name, transport: .http, url: url, headers: mapOption("--headers", in: args), tags: csvOption("--tags", in: args))) }
            else if let command = option("--command", in: args) { try await service.saveMCPServer(MCPServer(name: name, transport: .stdio, command: command, arguments: csvOption("--args", in: args), environment: mapOption("--env", in: args), tags: csvOption("--tags", in: args))) }
            else { throw SkillboxError.invalidSkill("podaj --url lub --command") }
            print("Dodano serwer \(name)")
        case "assign" where args.count >= 2:
            guard let project = try await service.listProjects().first(where: { $0.name == args[1] }) else { throw SkillboxError.projectNotFound(args[1]) }
            let names = Set(csvOption("--servers", in: args)); let ids = config.servers.filter { names.contains($0.name) }.map(\.id)
            try await service.setMCPServers(projectID: project.id, serverIDs: ids, tags: csvOption("--tags", in: args)); print("Przypisano serwery MCP")
        case "preview" where args.count >= 2:
            guard let project = try await service.listProjects().first(where: { $0.name == args[1] }) else { throw SkillboxError.projectNotFound(args[1]) }
            for preview in try await service.previewMCP(projectID: project.id) { print("--- \(preview.file)\n\(preview.content)") }
        case "sync" where args.count >= 2:
            guard let project = try await service.listProjects().first(where: { $0.name == args[1] }) else { throw SkillboxError.projectNotFound(args[1]) }
            _ = try await service.syncMCP(projectID: project.id); print("Zsynchronizowano MCP")
        default: print("Użycie: agentbox mcp list | server add <name> --url URL|--command CMD [--args a,b] [--tags x,y] | assign <project> --servers a,b [--tags x,y] | preview <project> | sync <project>")
        }
    }

    static func option(_ name: String, in args: [String]) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
    static func csvOption(_ name: String, in args: [String]) -> [String] { option(name, in: args)?.split(separator: ",").map(String.init) ?? [] }
    static func mapOption(_ name: String, in args: [String]) -> [String: String] { var result: [String: String] = [:]; for item in csvOption(name, in: args) { let parts = item.split(separator: "=", maxSplits: 1).map(String.init); if parts.count == 2 { result[parts[0]] = parts[1] } }; return result }
    static func printHelp() { print("""
    Agentbox — skille i MCP dla Claude, Codex i OpenCode
      agentbox add <folder|git-url> [--path subdir] [--branch main] [--id name]
      agentbox list | tag <skill> <tag...> | update <skill|--all>
      agentbox project add|set|list ...
      agentbox sync project <name> [--dry-run]
      agentbox sync global <claude|codex|opencode> --skills a,b [--tags x]
      agentbox refresh [--remote git-url] [--message text]
      agentbox backup [--remote git-url] [--message text]
      agentbox mcp list|server|assign|preview|sync ...
    """) }
}
