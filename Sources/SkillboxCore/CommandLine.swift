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
      agentbox new <id> [--name x] [--description y] [--tags a,b] [--file plik|-]
      agentbox delete <skill>
      agentbox project add|set|list|status|adopt|unsync|remove ...
      agentbox project root-add|root-adopt|roots|scan|adopt-new|ignore-new ...
      agentbox sync project <name> [--dry-run]
      agentbox sync all [--dry-run]
      agentbox sync global [--skills a,b] [--tags x] [--tools claude,codex,opencode]
      agentbox refresh [--remote git-url] [--message text]
      agentbox backup [--remote git-url] [--message text]
      agentbox restore --remote <git-url>
      agentbox mcp list|server|assign|preview|sync ...
      agentbox docs list|new|tag|delete|assign|preview|sync ...
    """

    /// Runs one command and returns the lines it produced. Throwing means the command failed.
    public static func run(_ args: [String], service: SkillboxService) async throws -> [String] {
        guard let command = args.first else { return [help] }
        if ["help", "--help", "-h"].contains(command) { return [help] }
        let rest = Array(args.dropFirst())
        switch command {
        case "list":
            return try await service.listSkills().map { "\($0.id)\t\($0.tags.joined(separator: ","))\t\($0.source.kind.rawValue)" }
        case "new" where rest.count >= 1:
            // `--file -` reads standard input, so a skill can be piped in from an editor or another
            // command instead of having to exist as a file first.
            let file = option("--file", in: args)
            let content: String
            switch file {
            case "-": content = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            case .some(let path): content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            case .none: content = "Opisz tutaj, co skill ma robić.\n"
            }
            let skill = try await service.createSkill(id: rest[0], name: option("--name", in: args) ?? "", description: option("--description", in: args) ?? "", content: content, tags: csv("--tags", in: args))
            return ["Utworzono skill \(skill.id)"]
        case "add":
            guard let value = rest.first else { throw SkillboxError.invalidSkill("podaj ścieżkę lub URL") }
            let subpath = option("--path", in: args), branch = option("--branch", in: args), id = option("--id", in: args)
            if value.contains("://") || value.hasSuffix(".git") {
                let result = try await service.addGitCollection(url: value, subpath: subpath, branch: branch, id: id)
                var lines = ["Dodano \(result.imported.count): \(result.imported.map(\.id).joined(separator: ", "))"]
                if !result.skipped.isEmpty { lines.append("Pominięto \(result.skipped.count): " + result.skipped.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ")) }
                return lines
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
        case "delete" where rest.count >= 1:
            try await service.deleteSkill(skillID: rest[0])
            return ["Usunięto skill \(rest[0])"]
        case "project": return try await project(rest, service: service, args: args)
        case "sync": return try await sync(rest, service: service, args: args)
        case "refresh": return try await refresh(service: service, args: args)
        case "backup":
            return [try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Agentbox backup")]
        case "restore":
            guard let remote = option("--remote", in: args) else { throw SkillboxError.invalidSkill("podaj --remote <adres-repozytorium>") }
            return [try await service.restoreLibraryFromRemote(remote, applicationVersion: "CLI")]
        case "mcp": return try await mcp(rest, service: service, args: args)
        case "docs": return try await docs(rest, service: service, args: args)
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
        case "remove" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            var lines: [String] = []
            if args.contains("--clean") {
                let removed = try await service.unsyncProject(id: project.id)
                lines.append("Usunięto z folderu projektu: \(removed.count) elementów")
            }
            try await service.deleteProject(id: project.id)
            lines.append("Usunięto projekt \(project.name) z Agentbox" + (args.contains("--clean") ? "" : "; pliki w jego folderze zostały bez zmian"))
            return lines
        case "root-add" where rest.count >= 3:
            let tools = (option("--tools", in: args) ?? "claude,codex,opencode").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
            let folderURL = URL(fileURLWithPath: rest[2]).standardizedFileURL
            // `--folders` picks subfolders by name; without it nothing is added yet and the folder's
            // own scan proposes everything it holds.
            let picked = csv("--folders", in: args).map { folderURL.appending(path: $0).path }
            let root = ProjectRoot(name: rest[1], path: folderURL.path, tools: tools, skillIDs: csv("--skills", in: args), tags: csv("--tags", in: args), manageGitignore: args.contains("--gitignore"), watchesNewFolders: !args.contains("--no-watch"))
            let stored = try await service.addProjectRoot(root, folders: picked, serverIDs: [], serverTags: [])
            return ["Dodano folder nadrzędny \(stored.name) (\(picked.count) projektów)"]
        case "root-adopt" where rest.count >= 3:
            // Existing projects in the folder join it; --keep-own names the ones that stay on their
            // own settings instead of the folder's.
            let folderURL = URL(fileURLWithPath: rest[2]).standardizedFileURL
            let inside = try await service.storedProjects().filter { URL(fileURLWithPath: $0.path).standardizedFileURL.deletingLastPathComponent().path == folderURL.path }
            guard !inside.isEmpty else { throw SkillboxError.projectNotFound("brak projektów w \(folderURL.path)") }
            let keepOwn = Set(csv("--keep-own", in: args))
            let owners = inside.filter { keepOwn.contains($0.name) }.map(\.id)
            let followers = inside.filter { !keepOwn.contains($0.name) }.map(\.id)
            let tools = (option("--tools", in: args) ?? "").split(separator: ",").compactMap { Tool(rawValue: String($0)) }
            let root = ProjectRoot(name: rest[1], path: folderURL.path, tools: tools.isEmpty ? Array(Set(inside.flatMap(\.tools))) : tools, skillIDs: csv("--skills", in: args), tags: csv("--tags", in: args), manageGitignore: args.contains("--gitignore"), watchesNewFolders: !args.contains("--no-watch"))
            let stored = try await service.adoptProjectsIntoRoot(root, following: followers, keepingOwnSettings: owners, serverIDs: [], serverTags: [])
            return ["Utworzono folder nadrzędny \(stored.name): \(followers.count) projektów na wspólnych ustawieniach, \(owners.count) z własnymi"]
        case "roots":
            let roots = try await service.projectRoots()
            guard !roots.isEmpty else { return ["Brak folderów nadrzędnych."] }
            let projects = try await service.storedProjects()
            return roots.map { root in
                let count = projects.filter { $0.rootID == root.id }.count
                let watching = root.watchesNewFolders ? "wykrywa nowe" : "bez wykrywania"
                return "\(root.name)\t\(root.path)\t\(count) projektów\t\(watching)\t\(root.tools.map(\.rawValue).joined(separator: ","))"
            }
        case "scan":
            let found = try await detected(rest, service: service, args: args)
            guard !found.isEmpty else { return ["Brak nowych podfolderów."] }
            return ["Nowe podfoldery: \(found.count)"] + found.map { "  \($0.rootName)\t\($0.path)" }
        case "adopt-new":
            let found = try await detected(rest, service: service, args: args)
            guard !found.isEmpty else { return ["Brak nowych podfolderów."] }
            guard args.contains("--yes") else {
                return ["Znaleziono \(found.count) nowych podfolderów:"] + found.map { "  \($0.rootName)\t\($0.path)" }
                    + ["Dodaj --yes, aby dodać je jako projekty (--sync synchronizuje je od razu)."]
            }
            let added = try await service.addDetectedFolders(found)
            var output = ["Dodano \(added.count) projektów: \(added.map(\.name).joined(separator: ", "))"]
            if args.contains("--sync") {
                for project in added {
                    let preview = try await service.syncProjectTransaction(projectID: project.id)
                    output.append("Zsynchronizowano \(project.name)")
                    output += lines(for: preview)
                }
            }
            return output
        case "ignore-new":
            let found = try await detected(rest, service: service, args: args)
            guard !found.isEmpty else { return ["Brak nowych podfolderów."] }
            try await service.ignoreDetectedFolders(found)
            return ["Pominięto \(found.count) podfolderów. Wróć do nich przez agentbox project unignore <folder>."]
        case "unignore" where rest.count >= 2:
            guard let root = try await service.projectRoots().first(where: { $0.name == rest[1] }) else { throw SkillboxError.projectNotFound(rest[1]) }
            try await service.clearIgnoredFolders(rootID: root.id)
            return ["Wyczyszczono listę pominiętych podfolderów w \(root.name)"]
        default: return [projectUsage]
        }
    }

    /// New subfolders, optionally narrowed to one parent folder with `--root <nazwa>`.
    private static func detected(_ rest: [String], service: SkillboxService, args: [String]) async throws -> [DetectedProjectFolder] {
        let found = try await service.scanProjectRoots()
        guard let name = option("--root", in: args) else { return found }
        guard let root = try await service.projectRoots().first(where: { $0.name == name }) else { throw SkillboxError.projectNotFound(name) }
        return found.filter { $0.rootID == root.id }
    }

    private static let projectUsage = "Użycie: agentbox project add <nazwa> <folder> [--tools claude,codex,opencode] | set <nazwa> [--skills a,b] [--tags web] | list | status | adopt <nazwa> [--yes] | unsync <nazwa> | remove <nazwa> [--clean] | root-adopt <nazwa> <folder> [--skills a,b] [--tags x] [--keep-own projekt] | root-add <nazwa> <folder> [--tools t] [--skills a,b] [--tags x] [--folders alpha,beta] [--no-watch] | roots | scan [--root nazwa] | adopt-new [--root nazwa] [--yes] [--sync] | ignore-new [--root nazwa] | unignore <folder>"

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
        let backupName = try await service.createFullBackup(applicationVersion: "CLI").name
        lines.append("Utworzono \(backupName)")
        lines.append("3/4 Tworzenie backupu Git…")
        let gitBackup = try await service.backup(remote: option("--remote", in: args), message: option("--message", in: args) ?? "Agentbox refresh", push: true, requireRemote: true)
        lines.append(gitBackup)
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
        return lines + summary(updates: updates, backupName: backupName, gitBackup: gitBackup, outcomes: outcomes)
    }

    /// A closing block for `refresh`. The per-project lines above scroll away on a long run, and a
    /// rolled-back or skipped project was reported only there — so the run could end looking fine
    /// while a project had actually failed. The summary names those projects explicitly.
    static func summary(updates: [String], backupName: String, gitBackup: String, outcomes: [ProjectSyncOutcome]) -> [String] {
        let synced = outcomes.filter { $0.state == .synced }
        let upToDate = outcomes.filter { $0.state == .upToDate }
        let failed = outcomes.filter { if case .failed = $0.state { return true } else { return false } }
        let skipped = outcomes.filter { $0.state == .skipped }
        var counts = ["✓ \(synced.count) zsynchronizowano", "= \(upToDate.count) bez zmian"]
        if !failed.isEmpty { counts.append("✗ \(failed.count) cofnięto") }
        if !skipped.isEmpty { counts.append("– \(skipped.count) pominięto") }
        var lines = [
            String(repeating: "─", count: 52),
            "PODSUMOWANIE",
            "  Skille          \(updates.isEmpty ? "bez aktualizacji" : "zaktualizowano \(updates.count): \(updates.joined(separator: ", "))")",
            "  Backup lokalny  \(backupName)",
            "  Backup Git      \(compact(gitBackup))",
            "  Projekty        \(outcomes.count) — \(counts.joined(separator: ", "))"
        ]
        if !failed.isEmpty {
            lines.append("  Wymaga uwagi:")
            for outcome in failed {
                if case .failed(let reason) = outcome.state { lines.append("    ✗ \(outcome.plan.project.name) — \(reason)") }
            }
            for outcome in skipped { lines.append("    – \(outcome.plan.project.name) — nie próbowano po błędzie") }
        }
        return lines
    }

    /// Git reports a push over several lines. The summary is a block of aligned one-liners, so the
    /// raw output goes above and this keeps only its gist.
    private static func compact(_ text: String, limit: Int = 88) -> String {
        let joined = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        guard joined.count > limit else { return joined.isEmpty ? "bez zmian" : joined }
        return String(joined.prefix(limit - 1)) + "…"
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
        case "server" where rest.count >= 3 && rest[1] == "remove":
            let name = rest[2]
            guard let server = config.servers.first(where: { $0.name == name }) else { throw SkillboxError.mcpConflict("serwer MCP nie istnieje: \(name)") }
            try await service.deleteMCPServer(id: server.id)
            return ["Usunięto serwer \(name)"]
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

    private static let mcpUsage = "Użycie: agentbox mcp list | server add <name> --url URL|--command CMD [--args a,b] [--tags x,y] | server remove <name> | assign <project> --servers a,b [--tags x,y] | preview <project> | sync <project>"

    private static func docs(_ rest: [String], service: SkillboxService, args: [String]) async throws -> [String] {
        guard let action = rest.first else { return [docsUsage] }
        switch action {
        case "list":
            let config = try await service.docsConfiguration()
            return config.docs.sorted { $0.name < $1.name }.map { "\($0.id)\t\($0.tags.joined(separator: ","))\t\($0.content.count) znaków" }
        case "new" where rest.count >= 2:
            let file = option("--file", in: args)
            let content: String
            switch file {
            case "-": content = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            case .some(let path): content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            case .none: content = ""
            }
            let doc = try await service.createDoc(id: rest[1], name: option("--name", in: args) ?? "", tags: csv("--tags", in: args), content: content)
            return ["Utworzono dokument \(doc.id)"]
        case "tag" where rest.count >= 3:
            try await service.setDocTags(docID: rest[1], tags: Array(rest.dropFirst(2)))
            return ["Zapisano tagi"]
        case "delete" where rest.count >= 2:
            try await service.deleteDoc(id: rest[1])
            return ["Usunięto dokument \(rest[1])"]
        case "assign" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            try await service.setDocs(projectID: project.id, docIDs: csv("--docs", in: args), tags: csv("--tags", in: args))
            return ["Przypisano dokumenty"]
        case "preview" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            return try await service.previewDocs(projectID: project.id).flatMap { ["--- \($0.file)", $0.content.isEmpty ? "(plik nie zostanie utworzony)" : $0.content] }
        case "sync" where rest.count >= 2:
            let project = try await resolve(rest[1], service: service)
            _ = try await service.syncDocs(projectID: project.id)
            return ["Zsynchronizowano dokumenty"]
        default: return [docsUsage]
        }
    }

    private static let docsUsage = "Użycie: agentbox docs list | new <id> [--name x] [--tags a,b] [--file plik|-] | tag <id> <tag...> | delete <id> | assign <project> --docs a,b [--tags x,y] | preview <project> | sync <project>"

    private static func resolve(_ name: String, service: SkillboxService) async throws -> Project {
        guard let project = try await service.listProjects().first(where: { $0.name == name }) else { throw SkillboxError.projectNotFound(name) }
        return project
    }

    private static func lines(for preview: ProjectSyncPreview) -> [String] {
        preview.skills.map { "  \($0.tool.rawValue): +\($0.added.count) ~\($0.updated.count) -\($0.removed.count) → \($0.target)" }
            + preview.mcp.map { "  \($0.tool.rawValue) MCP: +\($0.added.count) -\($0.removed.count) → \($0.file)" }
            + preview.docs.map { "  dokument: +\($0.added.count) -\($0.removed.count) → \($0.file)" }
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
