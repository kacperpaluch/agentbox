import Foundation

public actor SkillboxService {
    public let store: SkillboxStore
    private let fm = FileManager.default

    public init(root: URL? = nil) throws { store = try SkillboxStore(root: root) }

    public static func isExistingLibrary(at url: URL) -> Bool {
        let fm = FileManager.default
        let names = ["catalog.json", "projects.local.json", "mcp.json", "mcp-secrets.json"]
        if names.contains(where: { fm.fileExists(atPath: url.appending(path: $0).path) }) { return true }
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.appending(path: "skills").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func validateLibrary() async throws {
        _ = try await store.catalog()
        _ = try await store.configuration()
        _ = try await store.mcpConfiguration()
        _ = try await store.secrets()
    }

    public func listSkills() async throws -> [Skill] { try await store.catalog().skills.sorted { $0.name < $1.name } }
    /// Projects as synchronization sees them: one that follows a parent folder is returned with
    /// the folder's settings already applied. `storedProjects()` returns the raw records an editor
    /// must load, so saving a project never freezes inherited settings into it.
    public func listProjects() async throws -> [Project] { try await store.configuration().resolvedProjects.sorted { $0.name < $1.name } }
    public func storedProjects() async throws -> [Project] { try await store.configuration().projects.sorted { $0.name < $1.name } }

    public func skillMarkdown(skillID: String) async throws -> String {
        guard try await store.catalog().skills.contains(where: { $0.id == skillID }) else { throw SkillboxError.skillNotFound(skillID) }
        let url = await store.skillsDirectory.appending(path: skillID).appending(path: "SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func checkUpdates() async throws -> Set<String> {
        let skills = try await store.catalog().skills.filter { $0.source.kind == .git }
        var remoteRevisions: [String: String] = [:]
        var available = Set<String>()
        for skill in skills {
            let ref = skill.source.branch ?? "HEAD"
            let key = "\(skill.source.location)|\(ref)"
            let remote: String
            if let cached = remoteRevisions[key] { remote = cached } else {
                let output = try ProcessRunner.run("/usr/bin/git", ["ls-remote", skill.source.location, ref])
                remote = output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                remoteRevisions[key] = remote
            }
            if !remote.isEmpty, remote != skill.source.revision { available.insert(skill.id) }
        }
        return available
    }

    @discardableResult
    public func addLocal(path: String, id suppliedID: String? = nil) async throws -> Skill {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let skillsDirectory = await store.skillsDirectory
        var catalog = try await store.catalog()
        let skill = try importSkill(from: source, source: SkillSource(kind: .local, location: source.path), suppliedID: suppliedID, into: &catalog, skillsDirectory: skillsDirectory)
        try await store.save(catalog)
        return skill
    }

    public func addGitCollection(url: String, subpath: String? = nil, branch: String? = nil, id: String? = nil) async throws -> GitImportResult {
        let input = Self.normalizeGitInput(url: url, subpath: subpath, branch: branch)
        guard Self.isAllowedGitLocation(input.url) else { throw SkillboxError.invalidSkill("dozwolone źródła Git: https, http, ssh, git, file lub składnia user@host:path") }
        let temp = fm.temporaryDirectory.appending(path: "skillbox-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        var args = ["clone", "--depth", "1"]
        if let branch = input.branch { args += ["--branch", branch] }
        args += ["--", input.url, temp.path]
        _ = try ProcessRunner.run("/usr/bin/git", args)
        let revision = try ProcessRunner.run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: temp)
        let base = input.subpath.map { temp.appending(path: $0) } ?? temp
        let candidates = discoverSkills(in: base)
        guard !candidates.isEmpty else { throw SkillboxError.invalidSkill("brak SKILL.md w \(input.subpath ?? "repozytorium")") }
        if id != nil, candidates.count > 1 { throw SkillboxError.invalidSkill("--id można podać tylko dla pojedynczego skilla") }
        // The whole import is one catalog read and one save: a save per candidate burned one of
        // the ten recovery snapshots each, and an error mid-loop left a partially saved catalog.
        let skillsDirectory = await store.skillsDirectory
        var catalog = try await store.catalog()
        var imported: [Skill] = []
        var skipped: [SkippedSkill] = []
        for candidate in candidates {
            let tempPath = temp.resolvingSymlinksInPath().path
            let candidatePath = candidate.resolvingSymlinksInPath().path
            let relative: String?
            if candidatePath == tempPath { relative = nil }
            else if candidatePath.hasPrefix(tempPath + "/") { relative = String(candidatePath.dropFirst(tempPath.count + 1)) }
            else { throw SkillboxError.unsafePath(candidatePath) }
            let source = SkillSource(kind: .git, location: input.url, subpath: relative, branch: input.branch, revision: revision)
            let skillID = id ?? Self.defaultSkillID(relative: relative, candidate: candidate, repository: input.url)
            // One candidate conflicting with an unrelated existing skill (or being otherwise
            // invalid) is recorded and skipped rather than aborting the batch — a repository with
            // 25 skills should not fail to import 24 of them because one id collides.
            do {
                if let index = catalog.skills.firstIndex(where: { $0.id == skillID }) {
                    guard catalog.skills[index].source.kind == .git, Self.sameGitLocation(catalog.skills[index].source.location, input.url) else { throw SkillboxError.duplicateSkill(skillID) }
                    try copyReplacing(from: candidate, to: skillsDirectory.appending(path: skillID))
                    catalog.skills[index].source = source
                    catalog.skills[index].updatedAt = .now
                    imported.append(catalog.skills[index])
                } else {
                    imported.append(try importSkill(from: candidate, source: source, suppliedID: skillID, into: &catalog, skillsDirectory: skillsDirectory))
                }
            } catch { skipped.append(SkippedSkill(id: skillID, reason: error.localizedDescription)) }
        }
        guard !imported.isEmpty else { throw SkillboxError.invalidSkill(skipped.first?.reason ?? "nie zaimportowano żadnego skilla") }
        try await store.save(catalog)
        return GitImportResult(imported: imported, skipped: skipped)
    }

    private func discoverSkills(in root: URL) -> [URL] {
        if fm.fileExists(atPath: root.appending(path: "SKILL.md").path) { return [root] }
        return (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "SKILL.md" }.map { $0.deletingLastPathComponent() }
            .sorted { $0.path < $1.path }
    }

    /// Adds one skill to the passed-in catalog without saving it, so a batch import can make
    /// one save (and one recovery snapshot) for any number of skills.
    private func importSkill(from sourceURL: URL, source: SkillSource, suppliedID: String?, into catalog: inout Catalog, skillsDirectory: URL) throws -> Skill {
        guard fm.fileExists(atPath: sourceURL.appending(path: "SKILL.md").path) else { throw SkillboxError.invalidSkill("brak SKILL.md w \(sourceURL.path)") }
        let id = suppliedID ?? sourceURL.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        guard id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { throw SkillboxError.invalidSkill(id) }
        guard !catalog.skills.contains(where: { $0.id == id }) else { throw SkillboxError.duplicateSkill(id) }
        try copyReplacing(from: sourceURL, to: skillsDirectory.appending(path: id))
        let skill = Skill(id: id, name: id, source: source)
        catalog.skills.append(skill)
        return skill
    }

    /// The library directory of a skill, guaranteed to sit directly inside `skills/`.
    ///
    /// The identifier is checked instead of the resulting path. Standardizing the two URLs and
    /// comparing them looks equivalent but is not: `standardizedFileURL` resolves `/private/tmp` to
    /// `/tmp` and marks an existing directory with a trailing slash, and it does so on one side of
    /// the comparison only — which rejected perfectly valid libraries depending on where they live.
    func skillDirectory(_ skillID: String) async throws -> URL {
        guard !skillID.isEmpty, !skillID.contains("/"), skillID != ".", skillID != ".." else {
            throw SkillboxError.unsafePath(skillID)
        }
        return await store.skillsDirectory.appending(path: skillID)
    }

    /// Creates a skill from text written or pasted in the app, with no folder on disk to import
    /// from. The library copy is the original, so the source is local and points at the library
    /// itself — exactly what `saveSkillMarkdown` needs to keep the skill editable afterwards.
    @discardableResult
    public func createSkill(id: String, name: String = "", description: String = "", content: String, tags: [String] = []) async throws -> Skill {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        guard id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw SkillboxError.invalidSkill("identyfikator może zawierać tylko małe litery, cyfry i pojedyncze myślniki: \(id)")
        }
        var catalog = try await store.catalog()
        guard !catalog.skills.contains(where: { $0.id == id }) else { throw SkillboxError.duplicateSkill(id) }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = Self.skillDocument(name: displayName, description: description, body: content)
        let directory = try await skillDirectory(id)
        guard !fm.fileExists(atPath: directory.path) else { throw SkillboxError.duplicateSkill(id) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try document.write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            let skill = Skill(id: id, name: displayName, tags: Self.normalizedTags(tags), source: SkillSource(kind: .local, location: directory.path))
            catalog.skills.append(skill)
            try await store.save(catalog)
            return skill
        } catch {
            // The catalog is the source of truth. A directory left behind after a failed save would
            // block the next attempt with the same identifier.
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// Wraps written text in the YAML front matter a `SKILL.md` needs. Content that already starts
    /// with a `---` block is a complete file the user pasted, and is left exactly as it is.
    static func skillDocument(name: String, description: String, body: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("---") { return text + "\n" }
        var header = "---\nname: \(yamlScalar(name))\n"
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { header += "description: \(yamlScalar(description))\n" }
        header += "---\n\n"
        return header + text + "\n"
    }

    /// Quotes a value whose punctuation would otherwise change the meaning of the YAML line.
    static func yamlScalar(_ value: String) -> String {
        let plain = value.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._/()-]*$", options: .regularExpression) != nil
        guard !plain else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Saves edited `SKILL.md` content back into the library copy and bumps `updatedAt`, so every
    /// project that already has this skill immediately reports as outdated.
    ///
    /// Only local skills are editable. A Git-backed skill is replaced wholesale by `update`, so an
    /// in-app edit would be silently thrown away the next time the user pulls a new revision.
    public func saveSkillMarkdown(skillID: String, content: String) async throws {
        var catalog = try await store.catalog()
        guard let index = catalog.skills.firstIndex(where: { $0.id == skillID }) else { throw SkillboxError.skillNotFound(skillID) }
        guard catalog.skills[index].source.kind == .local else {
            throw SkillboxError.invalidSkill("skille z Git są zastępowane przy aktualizacji, więc nie można ich edytować w aplikacji")
        }
        let directory = try await skillDirectory(skillID)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        catalog.skills[index].updatedAt = .now
        try await store.save(catalog)
    }

    public func setTags(skillID: String, tags: [String]) async throws {
        var catalog = try await store.catalog()
        guard let index = catalog.skills.firstIndex(where: { $0.id == skillID }) else { throw SkillboxError.skillNotFound(skillID) }
        catalog.skills[index].tags = Self.normalizedTags(tags)
        try await store.save(catalog)
    }

    public func addTags(skillIDs: [String], tags: [String]) async throws {
        var catalog = try await store.catalog()
        let normalized = tags.map { $0.lowercased() }.filter { !$0.isEmpty }
        var found = Set<String>()
        for index in catalog.skills.indices where skillIDs.contains(catalog.skills[index].id) {
            catalog.skills[index].tags = Array(Set(catalog.skills[index].tags + normalized)).sorted()
            found.insert(catalog.skills[index].id)
        }
        if let missing = skillIDs.first(where: { !found.contains($0) }) { throw SkillboxError.skillNotFound(missing) }
        try await store.save(catalog)
    }

    public func deleteSkill(skillID: String) async throws {
        var catalog = try await store.catalog()
        guard catalog.skills.contains(where: { $0.id == skillID }) else { throw SkillboxError.skillNotFound(skillID) }
        let directory = try await skillDirectory(skillID)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        catalog.skills.removeAll { $0.id == skillID }
        var projects = try await store.configuration()
        for index in projects.projects.indices {
            projects.projects[index].skillIDs.removeAll { $0 == skillID }
            projects.projects[index].excludedSkillIDs?.removeAll { $0 == skillID }
        }
        // A parent folder holds the same selections for the projects that follow it, so leaving the
        // deleted skill there would keep handing it to every one of them.
        var roots = projects.roots
        for index in roots.indices {
            roots[index].skillIDs.removeAll { $0 == skillID }
            roots[index].excludedSkillIDs?.removeAll { $0 == skillID }
        }
        if !roots.isEmpty { projects.projectRoots = roots }
        try await store.save(catalog, projects)
    }

    @discardableResult
    public func update(skillID: String) async throws -> Skill {
        var catalog = try await store.catalog()
        guard let index = catalog.skills.firstIndex(where: { $0.id == skillID }) else { throw SkillboxError.skillNotFound(skillID) }
        var skill = catalog.skills[index]
        let destination = await store.skillsDirectory.appending(path: skill.id)
        switch skill.source.kind {
        case .local:
            try copyReplacing(from: URL(fileURLWithPath: skill.source.location), to: destination)
        case .git:
            let temp = fm.temporaryDirectory.appending(path: "skillbox-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            var args = ["clone", "--depth", "1"]
            if let branch = skill.source.branch { args += ["--branch", branch] }
            guard Self.isAllowedGitLocation(skill.source.location) else { throw SkillboxError.invalidSkill("niedozwolone źródło Git") }
            args += ["--", skill.source.location, temp.path]
            _ = try ProcessRunner.run("/usr/bin/git", args)
            skill.source.revision = try ProcessRunner.run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: temp)
            let source = skill.source.subpath.map { temp.appending(path: $0) } ?? discoverSkills(in: temp).first ?? temp
            try copyReplacing(from: source, to: destination)
        }
        skill.updatedAt = .now; catalog.skills[index] = skill; try await store.save(catalog)
        return skill
    }

    @discardableResult
    public func addProject(name: String, path: String, tools: [Tool]) async throws -> Project {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else { throw SkillboxError.projectNotFound(path) }
        var config = try await store.configuration()
        guard !config.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw SkillboxError.invalidSkill("projekt o nazwie \(name) już istnieje") }
        let project = Project(name: name, path: url.path, tools: tools)
        config.projects.append(project); try await store.save(config); return project
    }

    /// Creates a project and its skill and MCP assignments in one operation. The GUI used to call
    /// three separate methods, which took three snapshots for a single user action.
    @discardableResult
    public func addProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async throws -> Project {
        let url = URL(fileURLWithPath: project.path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        var config = try await store.configuration()
        guard !config.projects.contains(where: { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else { throw SkillboxError.invalidSkill("projekt o nazwie \(project.name) już istnieje") }
        var stored = Self.pruned(project, in: try await store.catalog()); stored.path = url.path
        config.projects.append(stored)
        var mcp = try await store.mcpConfiguration()
        Self.assign(&mcp, projectID: stored.id, serverIDs: serverIDs, tags: serverTags)
        try await store.save(config, mcp)
        return stored
    }

    public func updateProject(_ project: Project, serverIDs: [UUID], serverTags: [String]) async throws {
        var config = try await store.configuration()
        guard let index = config.projects.firstIndex(where: { $0.id == project.id }) else { throw SkillboxError.projectNotFound(project.name) }
        guard !config.projects.contains(where: { $0.id != project.id && $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else { throw SkillboxError.invalidSkill("projekt o nazwie \(project.name) już istnieje") }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        config.projects[index] = Self.pruned(project, in: try await store.catalog())
        var mcp = try await store.mcpConfiguration()
        // A project following its parent folder reads the folder's MCP selection, so writing one
        // under its own id would only leave a record nothing ever uses.
        if !config.inheritsRoot(config.projects[index]) {
            Self.assign(&mcp, projectID: project.id, serverIDs: serverIDs, tags: serverTags)
        }
        try await store.save(config, mcp)
    }

    static func assign(_ mcp: inout MCPConfiguration, projectID: UUID, serverIDs: [UUID], tags: [String]) {
        var assignments = mcp.projectServerIDs ?? [:]
        assignments[projectID.uuidString] = prunedServerIDs(Array(Set(serverIDs)), tags: tags, servers: mcp.servers)
        mcp.projectServerIDs = assignments
        var tagAssignments = mcp.projectServerTags ?? [:]
        tagAssignments[projectID.uuidString] = normalizedTags(tags)
        mcp.projectServerTags = tagAssignments
    }

    static func prunedServerIDs(_ serverIDs: [UUID], tags: [String], servers: [MCPServer]) -> [UUID] {
        let tagsByID = Dictionary(servers.map { ($0.id, $0.tags ?? []) }, uniquingKeysWith: { first, _ in first })
        return pruneRedundant(serverIDs, coveredBy: tags) { tagsByID[$0] ?? [] }
    }

    public func configureProject(name: String, skillIDs: [String], tags: [String]) async throws {
        var config = try await store.configuration()
        guard let index = config.projects.firstIndex(where: { $0.name == name }) else { throw SkillboxError.projectNotFound(name) }
        try Self.assertOwnSettings(config.projects[index], in: config)
        config.projects[index].skillIDs = skillIDs; config.projects[index].tags = tags
        config.projects[index] = Self.pruned(config.projects[index], in: try await store.catalog())
        try await store.save(config)
    }

    public func configureProject(id: UUID, skillIDs: [String], tags: [String]) async throws {
        var config = try await store.configuration()
        guard let index = config.projects.firstIndex(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        try Self.assertOwnSettings(config.projects[index], in: config)
        config.projects[index].skillIDs = skillIDs; config.projects[index].tags = tags
        config.projects[index] = Self.pruned(config.projects[index], in: try await store.catalog())
        try await store.save(config)
    }

    /// Configuring a project that follows its parent folder would write a selection synchronization
    /// never reads. Saying so is more useful than a silent no-op.
    static func assertOwnSettings(_ project: Project, in config: LocalConfiguration) throws {
        guard config.inheritsRoot(project) else { return }
        throw SkillboxError.invalidSkill("projekt \(project.name) korzysta z ustawień folderu nadrzędnego — zmień ustawienia folderu albo nadaj projektowi własne")
    }

    /// A tag owns everything it pulls in, so keeping an individual id for a tagged skill or server
    /// is a second source of truth: the editor already shows such an item as selected-by-tag, and
    /// the leftover id would silently keep it in the project after the tag is removed.
    static func pruneRedundant<ID: Hashable>(_ ids: [ID], coveredBy tags: [String], tagsOf: (ID) -> [String]) -> [ID] {
        let wanted = Set(normalizedTags(tags))
        return ids.filter { wanted.isDisjoint(with: tagsOf($0).map { $0.lowercased() }) }
    }

    /// Normalizes a project before it is stored: lowercased tags, no skill id that a selected tag
    /// already covers, and no skill id that the project excludes anyway.
    static func pruned(_ project: Project, in catalog: Catalog) -> Project {
        var project = project
        project.tags = normalizedTags(project.tags)
        let excluded = Set(project.excludedSkillIDs ?? [])
        let tagsByID = Dictionary(catalog.skills.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
        project.skillIDs = pruneRedundant(project.skillIDs, coveredBy: project.tags) { tagsByID[$0] ?? [] }
            .filter { !excluded.contains($0) }
        return project
    }

    /// Tags match case-insensitively everywhere, so they are stored lowercased everywhere.
    static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    public func updateProject(_ project: Project) async throws {
        var config = try await store.configuration()
        guard let index = config.projects.firstIndex(where: { $0.id == project.id }) else { throw SkillboxError.projectNotFound(project.name) }
        guard !config.projects.contains(where: { $0.id != project.id && $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else { throw SkillboxError.invalidSkill("projekt o nazwie \(project.name) już istnieje") }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        config.projects[index] = project
        try await store.save(config)
    }

    public func deleteProject(id: UUID) async throws {
        var config = try await store.configuration()
        guard let removed = config.projects.first(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        config.projects.removeAll { $0.id == id }
        // Removing a project from a watched parent folder is an answer, not an accident: without
        // this the folder would offer the very same subfolder again at the next scan.
        if let rootID = removed.rootID, let index = config.roots.firstIndex(where: { $0.id == rootID }) {
            var roots = config.roots
            roots[index].ignoredPaths = Self.standardized(roots[index].ignoredPaths + [removed.path]).sorted()
            config.projectRoots = roots
        }
        var mcp = try await store.mcpConfiguration()
        var servers = mcp.projectServerIDs ?? [:]; servers.removeValue(forKey: id.uuidString); mcp.projectServerIDs = servers
        var tags = mcp.projectServerTags ?? [:]; tags.removeValue(forKey: id.uuidString); mcp.projectServerTags = tags
        try await store.save(config, mcp)
    }

    /// Skill directories sitting in a project that Agentbox does not manage and that the library
    /// does not have yet. These are exactly the directories that block synchronization, so adopting
    /// one turns a conflict into a shared skill instead of forcing the user to delete their work.
    public func adoptableSkills(projectID: UUID) async throws -> [AdoptableSkill] {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let known = Set(try await store.catalog().skills.map(\.id))
        var found: [AdoptableSkill] = []
        for tool in project.tools {
            let target = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath)
            let managed = Self.managedSkillIDs(at: target)
            let entries = (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = entry.lastPathComponent
                guard !managed.contains(id), !known.contains(id) else { continue }
                guard fm.fileExists(atPath: entry.appending(path: "SKILL.md").path) else { continue }
                found.append(AdoptableSkill(suggestedID: id, path: entry.path, tool: tool))
            }
        }
        // The same skill can sit in .claude/skills and .codex/skills; adopt it once.
        var unique: [AdoptableSkill] = []
        for item in found where !unique.contains(where: { $0.suggestedID == item.suggestedID }) { unique.append(item) }
        return unique
    }

    @discardableResult
    public func adoptSkills(_ items: [AdoptableSkill]) async throws -> [Skill] {
        let skillsDirectory = await store.skillsDirectory
        var catalog = try await store.catalog()
        var adopted: [Skill] = []
        for item in items {
            let source = URL(fileURLWithPath: item.path).standardizedFileURL
            adopted.append(try importSkill(from: source, source: SkillSource(kind: .local, location: source.path), suppliedID: item.suggestedID, into: &catalog, skillsDirectory: skillsDirectory))
        }
        try await store.save(catalog)
        return adopted
    }

    public func backupStatus() async throws -> String {
        let root = store.root
        guard fm.fileExists(atPath: root.appending(path: ".git").path) else { return "Backup Git nie jest jeszcze skonfigurowany." }
        let remote = (try? ProcessRunner.run("/usr/bin/git", ["remote", "get-url", "origin"], cwd: root)) ?? "brak zdalnego repozytorium"
        let changes = try ProcessRunner.run("/usr/bin/git", ["status", "--short"], cwd: root)
        return "Repozytorium: \(remote)\n\(changes.isEmpty ? "Wszystkie zmiany są zapisane." : changes)"
    }

    public func copyLibrary(to destination: URL) async throws {
        let source = store.root.standardizedFileURL
        let target = destination.standardizedFileURL
        guard source != target else { return }
        guard !target.path.hasPrefix(source.path + "/") else { throw SkillboxError.unsafePath("nowy folder nie może znajdować się wewnątrz obecnej biblioteki") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard existing.isEmpty else { throw SkillboxError.invalidSkill("wybrany folder nie jest pusty") }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try fm.copyItem(at: item, to: target.appending(path: item.lastPathComponent))
        }
    }

    public func syncProject(name: String, dryRun: Bool = false) async throws -> [Tool: SyncResult] {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.name == name }) else { throw SkillboxError.projectNotFound(name) }
        return try await syncProject(id: project.id, dryRun: dryRun)
    }

    public func syncProject(id: UUID, dryRun: Bool = false) async throws -> [Tool: SyncResult] {
        let config = try await store.configuration()
        guard let project = config.resolvedProjects.first(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SkillboxError.projectNotFound(project.path) }
        let catalog = try await store.catalog()
        let selected = Self.selectedSkills(in: catalog, for: project)
        var results: [Tool: SyncResult] = [:]
        for tool in project.tools {
            let target = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath)
            results[tool] = try await sync(skills: selected, to: target, dryRun: dryRun)
        }
        // A tool unticked in the project keeps its manifest until this cleanup runs; syncing an
        // empty selection into its target removes everything the manifest lists and the manifest
        // itself, instead of leaving orphaned files in the repository.
        for tool in Self.abandonedTools(project: project) {
            let target = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath)
            results[tool] = try await sync(skills: [], to: target, dryRun: dryRun)
        }
        return results
    }

    public func syncGlobal(tool: Tool, skillIDs: [String], tags: [String] = [], dryRun: Bool = false, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> SyncResult {
        let selected = try await selectedSkills(ids: skillIDs, tags: tags, excluding: [])
        return try await sync(skills: selected, to: tool.globalSkillsURL(home: home), dryRun: dryRun)
    }

    /// Manifest of skills Agentbox owns inside one target directory.
    ///
    /// Version 2 records when each skill was last written so drift can be detected without
    /// hashing files. Version 1 was a bare `["id", ...]` array and still decodes; its entries get
    /// `distantPast`, so the first sync after upgrading reports them as outdated once.
    struct SkillManifest: Codable {
        var version = 2
        var skills: [String: Date] = [:]
    }

    static func skillManifest(at target: URL) -> SkillManifest {
        guard let data = try? Data(contentsOf: target.appending(path: ".skillbox.json")) else { return SkillManifest(version: 2, skills: [:]) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let manifest = try? decoder.decode(SkillManifest.self, from: data) { return manifest }
        let legacy = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return SkillManifest(version: 1, skills: Dictionary(uniqueKeysWithValues: legacy.map { ($0, Date.distantPast) }))
    }

    static func writeSkillManifest(_ skills: [Skill], to target: URL) throws {
        let manifest = SkillManifest(version: 2, skills: Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0.updatedAt) }))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: target.appending(path: ".skillbox.json"), options: .atomic)
    }

    static func managedSkillIDs(at target: URL) -> Set<String> { Set(skillManifest(at: target).skills.keys) }

    /// A directory that exists in the target but is not listed in the Agentbox manifest belongs
    /// to the user. Replacing it would destroy hand-written skills, so synchronization stops
    /// instead — the same rule that already protects unmanaged MCP entries.
    ///
    /// The one exception is a directory whose content is byte-identical to the library copy:
    /// that is exactly what `Przejmij skille z projektu` leaves behind, and replacing identical
    /// bytes destroys nothing, so the sync takes it over instead of blocking the very project the
    /// skill was adopted from.
    static func assertNoUnmanagedSkillConflict(ids: [String], target: URL, managed: Set<String>, library: URL) throws {
        let fm = FileManager.default
        for id in ids where !managed.contains(id) && fm.fileExists(atPath: target.appending(path: id).path) {
            guard !directoryMatches(library.appending(path: id), target.appending(path: id)) else { continue }
            throw SkillboxError.skillConflict("\(id) istnieje w \(target.path) i nie jest zarządzany przez Agentbox")
        }
    }

    static func skillPreview(tool: Tool, target: URL, current: [Skill], library: URL) throws -> SkillSyncPreview {
        let manifest = skillManifest(at: target)
        let previous = Set(manifest.skills.keys)
        let ids = Set(current.map(\.id))
        try assertNoUnmanagedSkillConflict(ids: Array(ids), target: target, managed: previous, library: library)
        let fm = FileManager.default
        // Outdated means the library copy moved on, or the directory disappeared from the project.
        // Both timestamps originate from the same `Skill.updatedAt` and are stored with ISO8601
        // second granularity, so an up-to-date skill compares exactly equal.
        let outdated = current.filter { skill in
            guard let written = manifest.skills[skill.id] else { return false }
            if !fm.fileExists(atPath: target.appending(path: skill.id).path) { return true }
            return skill.updatedAt > written
        }
        return SkillSyncPreview(
            tool: tool,
            target: target.path,
            added: Array(ids.subtracting(previous)).sorted(),
            updated: outdated.map(\.id).sorted(),
            removed: Array(previous.subtracting(ids)).sorted()
        )
    }

    func selectedSkills(ids: [String], tags: [String], excluding excluded: [String] = []) async throws -> [Skill] {
        let excludedIDs = Set(excluded)
        // Lowercased at comparison too, so selections saved before normalization keep working.
        let wanted = Set(tags.map { $0.lowercased() })
        return try await store.catalog().skills
            .filter { ids.contains($0.id) || !wanted.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
            .filter { !excludedIDs.contains($0.id) }
    }

    static func selectedSkills(in catalog: Catalog, for project: Project) -> [Skill] {
        let excluded = Set(project.excludedSkillIDs ?? [])
        let wanted = Set(project.tags.map { $0.lowercased() })
        return catalog.skills
            .filter { project.skillIDs.contains($0.id) || !wanted.isDisjoint(with: $0.tags.map { $0.lowercased() }) }
            .filter { !excluded.contains($0.id) }
    }

    private func sync(skills: [Skill], to target: URL, dryRun: Bool) async throws -> SyncResult {
        guard target.pathComponents.contains("skills"), target.path != "/" else { throw SkillboxError.unsafePath(target.path) }
        let previous = Self.managedSkillIDs(at: target)
        let current = skills.map(\.id).sorted(); var result = SyncResult()
        // Checked before the first removal so a conflict never leaves a half-synchronized target.
        try Self.assertNoUnmanagedSkillConflict(ids: current, target: target, managed: previous, library: await store.skillsDirectory)
        for stale in previous.subtracting(current) {
            result.removed.append(stale)
            let staleURL = target.appending(path: stale)
            if !dryRun, fm.fileExists(atPath: staleURL.path) { try fm.removeItem(at: staleURL) }
        }
        for skill in skills {
            result.copied.append(skill.id)
            if !dryRun { try fm.createDirectory(at: target, withIntermediateDirectories: true); try copyReplacing(from: await store.skillsDirectory.appending(path: skill.id), to: target.appending(path: skill.id)) }
        }
        if !dryRun {
            // An empty selection leaves no manifest behind: a target holding nothing managed is
            // the user's directory again, and a manifest-only directory would be clutter in
            // every repository that never chose any skills.
            if skills.isEmpty {
                let manifest = target.appending(path: ".skillbox.json")
                if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
                if let leftovers = try? fm.contentsOfDirectory(atPath: target.path), leftovers.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: target)
                }
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try Self.writeSkillManifest(skills, to: target)
            }
        }
        return result
    }

    public func backup(remote: String? = nil, message: String = "Agentbox backup", push: Bool = true, requireRemote: Bool = false) async throws -> String {
        let root = store.root
        if !fm.fileExists(atPath: root.appending(path: ".git").path) { _ = try ProcessRunner.run("/usr/bin/git", ["init"], cwd: root) }
        try ensureLibraryGitignore(root)
        if let remote {
            let existing = try? ProcessRunner.run("/usr/bin/git", ["remote", "get-url", "origin"], cwd: root)
            _ = try ProcessRunner.run("/usr/bin/git", existing == nil ? ["remote", "add", "origin", remote] : ["remote", "set-url", "origin", remote], cwd: root)
        }
        let hasRemote = (try? ProcessRunner.run("/usr/bin/git", ["remote", "get-url", "origin"], cwd: root)) != nil
        if requireRemote, !hasRemote { throw SkillboxError.commandFailed("brak zdalnego repozytorium Git; skonfiguruj origin lub podaj --remote") }
        var tracked = [".gitignore", "skills"]
        for name in ["catalog.json", "mcp.json"] where fm.fileExists(atPath: root.appending(path: name).path) { tracked.append(name) }
        _ = try ProcessRunner.run("/usr/bin/git", ["add"] + tracked, cwd: root)
        let staged = try ProcessRunner.run("/usr/bin/git", ["diff", "--cached", "--name-only"], cwd: root)
        if !staged.isEmpty { _ = try ProcessRunner.run("/usr/bin/git", ["commit", "-m", message], cwd: root) }
        if push, hasRemote { return try ProcessRunner.run("/usr/bin/git", ["push", "-u", "origin", "HEAD"], cwd: root) }
        return staged.isEmpty ? "Brak zmian" : "Utworzono lokalny commit"
    }

    /// Restores skills, catalog and MCP configuration from a backup repository — the missing half
    /// of `backup(remote:)`, used when setting up a new Mac. A full local backup is taken first, so
    /// the previous contents of the library remain recoverable.
    @discardableResult
    public func restoreLibraryFromRemote(_ remote: String, applicationVersion: String) async throws -> String {
        guard Self.isAllowedGitLocation(remote) else { throw SkillboxError.invalidSkill("dozwolone źródła Git: https, http, ssh, git, file lub składnia user@host:path") }
        let temp = fm.temporaryDirectory.appending(path: "agentbox-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        _ = try await store.createFullBackup(applicationVersion: applicationVersion)
        // A full clone, not --depth 1: the adopted .git must stay pushable.
        _ = try ProcessRunner.run("/usr/bin/git", ["clone", "--", remote, temp.path], timeout: 600)
        try await store.adoptLibrary(from: temp)
        let count = try await store.catalog().skills.count
        return "Przywrócono bibliotekę z \(remote): \(count) skilli. Projekty i sekrety na tym Macu pozostały bez zmian."
    }

    public func automaticBackup(push: Bool) async throws -> String? {
        let root = store.root
        guard fm.fileExists(atPath: root.appending(path: ".git").path) else { return nil }
        return try await backup(message: "Agentbox automatic backup", push: push)
    }

    private func ensureLibraryGitignore(_ root: URL) throws {
        let url = root.appending(path: ".gitignore")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for entry in ["projects.local.json", "mcp-secrets.json", ".agentbox-snapshots/", "backups/"] where !text.split(whereSeparator: \.isNewline).contains(Substring(entry)) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += entry + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func isAllowedGitLocation(_ value: String) -> Bool {
        guard !value.hasPrefix("-") else { return false }
        if value.range(of: "^[^@\\s]+@[^:\\s]+:.+$", options: .regularExpression) != nil { return true }
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return ["https", "http", "ssh", "git", "file"].contains(scheme)
    }

    /// Whether two Git source locations are the same repository, ignoring the surface differences
    /// that show up depending on how a URL was copied — a trailing slash, or a `.git` suffix GitHub
    /// includes in its "Copy" button but not in the address bar. Comparing raw strings here made
    /// re-adding a repository with an equivalent-but-differently-typed URL look like a foreign
    /// source, which turned an ordinary re-import into a hard conflict.
    private static func sameGitLocation(_ a: String, _ b: String) -> Bool {
        func normalized(_ value: String) -> String {
            var trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }
            return trimmed
        }
        return normalized(a) == normalized(b)
    }

    private static func defaultSkillID(relative: String?, candidate: URL, repository: String) -> String {
        let repositoryName: String = {
            if let parsed = URL(string: repository), !parsed.lastPathComponent.isEmpty { return parsed.lastPathComponent }
            let tail = repository.split(separator: "/").last.map(String.init) ?? candidate.lastPathComponent
            return tail.split(separator: ":").last.map(String.init) ?? tail
        }()
        let base = relative == nil ? repositoryName : candidate.lastPathComponent
        let withoutGit = base.hasSuffix(".git") ? String(base.dropLast(4)) : base
        return withoutGit.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    static func normalizeGitInput(url: String, subpath: String?, branch: String?) -> (url: String, subpath: String?, branch: String?) {
        guard let parsed = URL(string: url), parsed.host?.lowercased() == "github.com" else { return (url, subpath, branch) }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "tree" else { return (url, subpath, branch) }
        let repository = parts[1].hasSuffix(".git") ? parts[1] : parts[1] + ".git"
        let cloneURL = "https://github.com/\(parts[0])/\(repository)"
        let detectedPath = parts.dropFirst(4).joined(separator: "/")
        return (cloneURL, subpath ?? (detectedPath.isEmpty ? nil : detectedPath), branch ?? parts[3])
    }

    private func copyReplacing(from source: URL, to destination: URL) throws {
        guard fm.fileExists(atPath: source.path) else { throw SkillboxError.invalidSkill(source.path) }
        let staging = destination.deletingLastPathComponent().appending(path: ".skillbox-stage-\(UUID().uuidString)")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staging)
        let previous = destination.deletingLastPathComponent().appending(path: ".skillbox-previous-\(UUID().uuidString)")
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: previous) }
        do {
            try fm.moveItem(at: staging, to: destination)
            if existed { try? fm.removeItem(at: previous) }
        } catch {
            try? fm.removeItem(at: staging)
            if existed, fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: destination) }
            throw error
        }
    }
}
