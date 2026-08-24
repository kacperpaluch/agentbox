import Foundation

/// Command dispatch for the `agentbox` executable.
///
/// This lives in SkillboxCore rather than the executable target so the tests can drive real
/// commands against a temporary library instead of only testing the service underneath them.
public enum AgentboxCommand {
    public static let help = """
    Agentbox — skille i MCP dla Claude, Codex i OpenCode
      agentbox add <folder|git-url> [--path subdir] [--branch main] [--id name]
      agentbox list | tag <skill> <tag...> | update <skill|--all>
      agentbox project add|set|list|status|adopt|unsync ...
      agentbox sync project <name> [--dry-run]
      agentbox sync all [--dry-run]
      agentbox sync global [--skills a,b] [--tags x] [--tools claude,codex,opencode]
      agentbox refresh [--remote git-url] [--message text]
      agentbox backup [--remote git-url] [--message text]
      agentbox restore --remote <git-url>
      agentbox mcp list|server|assign|preview|sync ...
    """

    /// Runs one command and returns the lines it produced. Throwing means the command failed.
    public static func run(_ args: [String], service: SkillboxService) async throws -> [String] {
        guard let command = args.first else { return [help] }
        if ["help", "--help", "-h"].contains(command) { return [help] }
        let rest = Array(args.dropFirst())
        switch command {
        case "list":
            return try await service.listSkills().map { "\($0.id)\t\($0.tags.joined(separator: ","))\t\($0.source.kind.rawValue)" }
        case "add":
            guard let value = rest.first else { throw SkillboxError.invalidSkill("podaj ścieżkę lub URL") }
            let subpath = option("--path", in: args), branch = option("--branch", in: args), id = option("--id", in: args)
            if value.contains("://") || value.hasSuffix(".git") {
                let skills = try await service.addGitCollection(url: value, subpath: subpath, branch: branch, id: id)
                return ["Dodano \(skills.count): \(skills.map(\.id).joined(separator: ", "))"]
            }
            return ["Dodano \(try await service.addLocal(path: value, id: id).id)"]
        case "tag":
            guard rest.count >= 2 else { return ["Użycie: agentbox tag <skill> <tag...>"] }
            try await service.setTags(skillID: rest[0], tags: Array(rest.dropFirst()))
            return ["Zapisano tagi"]
        case "update":
            guard let target = rest.first else { return ["Użycie: agentbox update <skill|--all>"] }
            guard target == "--all" else { _ = try await service.update(skillID: target); return ["Zaktualizowano \(target)"] }
            let ids = try await service.checkUpdates().sorted()
            guard !ids.isEmpty else { return ["Wszystkie skille są aktualne"] }
            var lines = ["Dostępne aktualizacje: \(ids.count)"]
            for id in ids { _ = try await service.update(skillID: id); lines.append("Zaktualizowano \(id)") }
            return lines
        case "project": return try await project(rest, service: service, args: args)
        case "sync": return try await sync(rest, service: service, args: args)
        case "refresh": return try await refresh(service: service, args: args)
        case "backup":
            return [try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Agentbox backup")]
        case "restore":
            guard let remote = option("--remote", in: args) else { throw SkillboxError.invalidSkill("podaj --remote <adres-repozytorium>") }
            return [try await service.restoreLibraryFromRemote(remote, applicationVersion: "CLI")]
        case "mcp": return try await mcp(rest, service: service, args: args)
        default: return [help]
        }
    }

    private static func project(_ rest: [String], service: SkillboxService, args: [String]) async throws -> [String] {
        guard let action = rest.first else { return [projectUsage] }
        switch action {
        case "list":
            return try await service.listProjects().map { "\($0.name)\t\($0.path)\t\($0.tools.map(\.rawValue).joined(separator: ","))" }
        case "status":
            let projects = try await service.listProjects()
            let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
            return try await service.projectStatuses().map { status in
                let name = names[status.projectID] ?? status.projectID.uuidString
                switch status.state {
                case .synced: return "✓ \(name)\taktualny"
                case .pending(let added, let outdated, let removed): return "● \(name)\t+\(added) ~\(outdated) -\(removed)"
                case .blocked(let reason): return "✗ \(name)\tzablokowany: \(reason)"
                case .missing: return "? \(name)\tbrak folderu projektu"
                }
            }
        case "add" where rest.count >= 3:
            let tools = (option("--tools", in: args) ?? "claude,codex,opencode").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
            return ["Dodano projekt \(try await service.addProject(name: rest[1], path: rest[2], tools: tools).name)"]
        case "set" where rest.count >= 2:
            try await service.configureProject(name: rest[1], skillIDs: csv("--skills", in: args), tags: csv("--tags", in: args))
            return ["Zapisano projekt"]
        case "adopt" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            let candidates = try await service.adoptableSkills(projectID: project.id)
            guard !candidates.isEmpty else { return ["Brak skilli do przejęcia w \(project.name)"] }
            guard args.contains("--yes") else {
                return ["Znaleziono \(candidates.count) skilli do przejęcia:"] + candidates.map { "  \($0.suggestedID)\t\($0.path)" } + ["Dodaj --yes, aby skopiować je do biblioteki."]
            }
            let adopted = try await service.adoptSkills(candidates)
            return ["Przejęto \(adopted.count): \(adopted.map(\.id).joined(separator: ", "))"]
        case "unsync" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            let removed = try await service.unsyncProject(id: project.id)
            return ["Usunięto z \(project.name): \(removed.count) elementów"] + removed.map { "  \($0)" }
        default: return [projectUsage]
        }
    }

    private static let projectUsage = "Użycie: agentbox project add <nazwa> <folder> [--tools claude,codex,opencode] | set <nazwa> [--skills a,b] [--tags web] | list | status | adopt <nazwa> [--yes] | unsync <nazwa>"

    private static func sync(_ rest: [String], service: SkillboxService, args: [String]) async throws -> [String] {
        guard let mode = rest.first else { return [syncUsage] }
        let dry = args.contains("--dry-run")
        switch mode {
        case "project" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            let preview = dry ? try await service.previewProjectSync(projectID: project.id) : try await service.syncProjectTransaction(projectID: project.id)
            return lines(for: preview)
        case "global":
            let ids = csv("--skills", in: args), tags = csv("--tags", in: args)
            if !ids.isEmpty || !tags.isEmpty {
                let tools = (option("--tools", in: args) ?? "claude,codex,opencode").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
                try await service.setGlobalSelection(GlobalSkillSelection(tools: tools, skillIDs: ids, tags: tags))
            }
            let previews = dry ? try await service.previewGlobalSync() : try await service.syncGlobalSelection()
            guard !previews.isEmpty else { return ["Nie wybrano narzędzi dla synchronizacji globalnej"] }
            return previews.map { "\($0.tool.rawValue): +\($0.added.count) ~\($0.updated.count) -\($0.removed.count) → \($0.target)" }
        case "all":
            guard !dry else {
                return try await service.previewAllProjectsSync().flatMap { ["\($0.project.name):"] + lines(for: $0.preview) }
            }
            return try await service.syncAllProjectsTransactions().map { outcome in
                switch outcome.state {
                case .synced: return "✓ \(outcome.plan.project.name)"
                case .upToDate: return "= \(outcome.plan.project.name) — bez zmian"
                case .failed(let reason): return "✗ \(outcome.plan.project.name) — cofnięto: \(reason)"
                case .skipped: return "– \(outcome.plan.project.name) — pominięto po wcześniejszym błędzie"
                }
            }
        default: return [syncUsage]
        }
    }

    private static let syncUsage = "Użycie: agentbox sync project <nazwa> | global [--skills a,b] [--tags x] [--tools claude,codex] | all [--dry-run]"

    private static func refresh(service: SkillboxService, args: [String]) async throws -> [String] {
        var lines = ["1/4 Sprawdzanie aktualizacji skilli…"]
        let updates = try await service.checkUpdates().sorted()
        if updates.isEmpty { lines.append("Wszystkie skille są aktualne") }
        else { for id in updates { _ = try await service.update(skillID: id); lines.append("Zaktualizowano \(id)") } }
        lines.append("2/4 Tworzenie pełnego backupu lokalnego…")
        lines.append("Utworzono \(try await service.createFullBackup(applicationVersion: "CLI").name)")
        lines.append("3/4 Tworzenie backupu Git…")
        lines.append(try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Agentbox refresh", push: true, requireRemote: true))
        lines.append("4/4 Synchronizacja projektów…")
        let outcomes = try await service.syncAllProjectsTransactions()
        for outcome in outcomes {
            switch outcome.state {
            case .synced: lines.append("✓ \(outcome.plan.project.name)")
            case .upToDate: lines.append("= \(outcome.plan.project.name) — bez zmian")
            case .failed(let reason): lines.append("✗ \(outcome.plan.project.name) — cofnięto: \(reason)")
            case .skipped: lines.append("– \(outcome.plan.project.name) — pominięto")
            }
        }
        let synced = outcomes.filter { $0.state == .synced }.count
        let upToDate = outcomes.filter { $0.state == .upToDate }.count
        lines.append("Gotowe: zaktualizowano \(updates.count) skilli, zsynchronizowano \(synced), bez zmian \(upToDate) z \(outcomes.count) projektów")
        return lines
    }

    private static func mcp(_ rest: [String], service: SkillboxService, args: [String]) async throws -> [String] {
        guard let action = rest.first else { return [mcpUsage] }
        let config = try await service.mcpConfiguration()
        switch action {
        case "list":
            return config.servers.map { "server\t\($0.name)\t\($0.transport.rawValue)\t\(($0.tags ?? []).joined(separator: ","))" }
        case "server" where rest.count >= 3 && rest[1] == "add":
            let name = rest[2]
            if let url = option("--url", in: args) {
                try await service.saveMCPServer(MCPServer(name: name, transport: .http, url: url, headers: map("--headers", in: args), tags: csv("--tags", in: args)))
            } else if let command = option("--command", in: args) {
                try await service.saveMCPServer(MCPServer(name: name, transport: .stdio, command: command, arguments: csv("--args", in: args), environment: map("--env", in: args), tags: csv("--tags", in: args)))
            } else { throw SkillboxError.invalidSkill("podaj --url lub --command") }
            return ["Dodano serwer \(name)"]
        case "assign" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            let names = Set(csv("--servers", in: args))
            try await service.setMCPServers(projectID: project.id, serverIDs: config.servers.filter { names.contains($0.name) }.map(\.id), tags: csv("--tags", in: args))
            return ["Przypisano serwery MCP"]
        case "preview" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            return try await service.previewMCP(projectID: project.id).flatMap { ["--- \($0.file)", $0.content] }
        case "sync" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            _ = try await service.syncMCP(projectID: project.id)
            return ["Zsynchronizowano MCP"]
        default: return [mcpUsage]
        }
    }

    private static let mcpUsage = "Użycie: agentbox mcp list | server add <name> --url URL|--command CMD [--args a,b] [--tags x,y] | assign <project> --servers a,b [--tags x,y] | preview <project> | sync <project>"

    private static func resolve(_ name: String, service: SkillboxService) async throws -> Project {
        guard let project = try await service.listProjects().first(where: { $0.name == name }) else { throw SkillboxError.projectNotFound(name) }
        return project
    }

    private static func lines(for preview: ProjectSyncPreview) -> [String] {
        preview.skills.map { "  \($0.tool.rawValue): +\($0.added.count) ~\($0.updated.count) -\($0.removed.count) → \($0.target)" }
            + preview.mcp.map { "  \($0.tool.rawValue) MCP: +\($0.added.count) -\($0.removed.count) → \($0.file)" }
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    static func csv(_ name: String, in args: [String]) -> [String] {
        option(name, in: args)?.split(separator: ",").map(String.init) ?? []
    }
    static func map(_ name: String, in args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for item in csv(name, in: args) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}
