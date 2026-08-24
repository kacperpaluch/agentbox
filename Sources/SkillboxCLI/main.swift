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
        case "restore":
            guard let remote = option("--remote", in: args) else { throw SkillboxError.invalidSkill("podaj --remote <adres-repozytorium>") }
            print(try await service.restoreLibraryFromRemote(remote, applicationVersion: "CLI"))
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
        guard let mode = args.first else { print("Użycie: agentbox sync project <nazwa> | global [--skills a,b] [--tags x] | all"); return }
        let dry = args.contains("--dry-run")
        switch mode {
        case "project" where args.count >= 2:
            guard let project = try await service.listProjects().first(where: { $0.name == args[1] }) else { throw SkillboxError.projectNotFound(args[1]) }
            // Same transactional path as the GUI: backup, skills, MCP, rollback on failure.
            let preview = dry ? try await service.previewProjectSync(projectID: project.id) : try await service.syncProjectTransaction(projectID: project.id)
            printPreview(preview)
        case "global":
            let ids = csvOption("--skills", in: args), tags = csvOption("--tags", in: args)
            if !ids.isEmpty || !tags.isEmpty {
                let tools = (option("--tools", in: args) ?? "claude,codex,opencode").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
                try await service.setGlobalSelection(GlobalSkillSelection(tools: tools, skillIDs: ids, tags: tags))
            }
            let previews = dry ? try await service.previewGlobalSync() : try await service.syncGlobalSelection()
            if previews.isEmpty { print("Nie wybrano narzędzi dla synchronizacji globalnej") }
            for item in previews { print("\(item.tool.rawValue): +\(item.added.count) ~\(item.updated.count) -\(item.removed.count) → \(item.target)") }
        case "all":
            guard !dry else { for plan in try await service.previewAllProjectsSync() { print("\(plan.project.name):"); printPreview(plan.preview) }; return }
            for outcome in try await service.syncAllProjectsTransactions() {
                switch outcome.state {
                case .synced: print("✓ \(outcome.plan.project.name)")
                case .failed(let reason): print("✗ \(outcome.plan.project.name) — cofnięto: \(reason)")
                case .skipped: print("– \(outcome.plan.project.name) — pominięto po wcześniejszym błędzie")
                }
            }
        default: print("Użycie: agentbox sync project <nazwa> | global [--skills a,b] [--tags x] [--tools claude,codex] | all [--dry-run]")
        }
    }

    static func printPreview(_ preview: ProjectSyncPreview) {
        for item in preview.skills { print("  \(item.tool.rawValue): +\(item.added.count) ~\(item.updated.count) -\(item.removed.count) → \(item.target)") }
        for item in preview.mcp { print("  \(item.tool.rawValue) MCP: +\(item.added.count) -\(item.removed.count) → \(item.file)") }
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
