import Foundation

extension LocalConfiguration {
    public var roots: [ProjectRoot] { projectRoots ?? [] }

    public func root(for project: Project) -> ProjectRoot? {
        guard let rootID = project.rootID else { return nil }
        return roots.first { $0.id == rootID }
    }

    /// True when the project takes its settings from its parent folder instead of its own.
    public func inheritsRoot(_ project: Project) -> Bool {
        project.overridesRoot != true && root(for: project) != nil
    }

    /// The project as everything downstream must see it. A project following its parent folder gets
    /// the folder's tools, skills, tags, exclusions and Git option and keeps only its own identity,
    /// so a change on the folder reaches every project in it without touching their records.
    public func resolved(_ project: Project) -> Project {
        guard let root = root(for: project), project.overridesRoot != true else { return project }
        var resolved = project
        resolved.tools = root.tools
        resolved.skillIDs = root.skillIDs
        resolved.tags = root.tags
        resolved.excludedSkillIDs = root.excludedSkillIDs
        resolved.manageGitignore = root.manageGitignore
        return resolved
    }

    public var resolvedProjects: [Project] { projects.map(resolved) }

    /// Which identifier owns the MCP selection for a project: the parent folder's when the project
    /// follows it. Roots and projects share the assignment dictionaries in `mcp.json`, because their
    /// UUIDs never collide and one lookup keeps inherited and own selections on the same path.
    public func mcpSelectionID(for project: Project) -> UUID {
        inheritsRoot(project) ? (project.rootID ?? project.id) : project.id
    }
}

extension SkillboxService {
    public func projectRoots() async throws -> [ProjectRoot] {
        try await store.configuration().roots.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates a parent folder together with the projects picked from it. Everything lands in one
    /// save, so a single user action takes a single recovery snapshot and never leaves a folder
    /// without its projects.
    @discardableResult
    public func addProjectRoot(_ root: ProjectRoot, folders: [String], serverIDs: [UUID], serverTags: [String], treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
        var isDirectory: ObjCBool = false
        let rootURL = URL(fileURLWithPath: root.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillboxError.projectNotFound(root.path)
        }
        var config = try await store.configuration()
        guard !config.roots.contains(where: { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }) else {
            throw SkillboxError.invalidSkill("folder nadrzędny o nazwie \(root.name) już istnieje")
        }
        guard !config.roots.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == rootURL.path }) else {
            throw SkillboxError.invalidSkill("folder \(rootURL.path) jest już dodany jako nadrzędny")
        }
        var stored = Self.pruned(root, in: try await store.catalog())
        stored.path = rootURL.path
        stored.ignoredPaths = Self.standardized(stored.ignoredPaths)
        var projects: [Project] = []
        var taken = Set(config.projects.map { $0.name.lowercased() })
        for folder in Self.standardized(folders) {
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SkillboxError.projectNotFound(folder)
            }
            guard !config.projects.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == folder }) else { continue }
            let name = Self.uniqueProjectName(URL(fileURLWithPath: folder).lastPathComponent, taken: taken)
            taken.insert(name.lowercased())
            projects.append(Project(name: name, path: folder, tools: stored.tools, rootID: stored.id))
        }
        if treatingExistingAsKnown {
            let projectPaths = (config.projects + projects).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            stored.ignoredPaths = Self.knownSubfolders(of: rootURL, besides: stored.ignoredPaths, excluding: projectPaths)
        }
        config.projectRoots = config.roots + [stored]
        config.projects.append(contentsOf: projects)
        var mcp = try await store.mcpConfiguration()
        Self.assign(&mcp, projectID: stored.id, serverIDs: serverIDs, tags: serverTags)
        try await store.save(config, mcp)
        return stored
    }

    /// Saves the settings shared by every project in the folder. Projects that follow the folder
    /// pick the change up on their next preview; projects with their own settings are untouched.
    public func updateProjectRoot(_ root: ProjectRoot, serverIDs: [UUID], serverTags: [String]) async throws {
        var config = try await store.configuration()
        guard let index = config.roots.firstIndex(where: { $0.id == root.id }) else {
            throw SkillboxError.projectNotFound(root.name)
        }
        guard !config.roots.contains(where: { $0.id != root.id && $0.name.caseInsensitiveCompare(root.name) == .orderedSame }) else {
            throw SkillboxError.invalidSkill("folder nadrzędny o nazwie \(root.name) już istnieje")
        }
        var roots = config.roots
        var stored = Self.pruned(root, in: try await store.catalog())
        // The folder's location is set when it is added; editing only changes what it configures.
        stored.path = roots[index].path
        stored.ignoredPaths = Self.standardized(stored.ignoredPaths)
        roots[index] = stored
        config.projectRoots = roots
        var mcp = try await store.mcpConfiguration()
        Self.assign(&mcp, projectID: stored.id, serverIDs: serverIDs, tags: serverTags)
        try await store.save(config, mcp)
    }

    /// Turns a folder that already holds projects into a parent folder.
    ///
    /// Projects added one by one — or in a batch before parent folders existed — have no folder to
    /// inherit from, so without this the shared settings would be reachable only for folders added
    /// from scratch. Every project passed in joins the folder; `following` says which ones drop
    /// their own settings for the folder's, and the rest keep exactly what they synchronize today.
    @discardableResult
    public func adoptProjectsIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], serverIDs: [UUID], serverTags: [String], treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
        var isDirectory: ObjCBool = false
        let rootURL = URL(fileURLWithPath: root.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillboxError.projectNotFound(root.path)
        }
        var config = try await store.configuration()
        guard !config.roots.contains(where: { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }) else {
            throw SkillboxError.invalidSkill("folder nadrzędny o nazwie \(root.name) już istnieje")
        }
        guard !config.roots.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == rootURL.path }) else {
            throw SkillboxError.invalidSkill("folder \(rootURL.path) jest już dodany jako nadrzędny")
        }
        let followers = Set(following), owners = Set(keepingOwnSettings)
        for id in followers.union(owners) where !config.projects.contains(where: { $0.id == id }) {
            throw SkillboxError.projectNotFound(id.uuidString)
        }
        var stored = Self.pruned(root, in: try await store.catalog())
        stored.path = rootURL.path
        stored.ignoredPaths = Self.standardized(stored.ignoredPaths)
        var mcp = try await store.mcpConfiguration()
        for index in config.projects.indices {
            let id = config.projects[index].id
            guard followers.contains(id) || owners.contains(id) else { continue }
            config.projects[index].rootID = stored.id
            config.projects[index].overridesRoot = owners.contains(id) ? true : nil
            guard followers.contains(id) else { continue }
            // The folder answers for these projects now. Leaving their old selections behind would
            // be a second source of truth that nothing reads.
            config.projects[index].tools = []
            config.projects[index].skillIDs = []
            config.projects[index].tags = []
            config.projects[index].excludedSkillIDs = nil
            config.projects[index].manageGitignore = nil
            var servers = mcp.projectServerIDs ?? [:]; servers.removeValue(forKey: id.uuidString); mcp.projectServerIDs = servers
            var tags = mcp.projectServerTags ?? [:]; tags.removeValue(forKey: id.uuidString); mcp.projectServerTags = tags
        }
        if treatingExistingAsKnown {
            stored.ignoredPaths = Self.knownSubfolders(of: rootURL, besides: stored.ignoredPaths, excluding: config.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        }
        config.projectRoots = config.roots + [stored]
        Self.assign(&mcp, projectID: stored.id, serverIDs: serverIDs, tags: serverTags)
        try await store.save(config, mcp)
        return stored
    }

    /// Removes the shared settings. The projects stay exactly as they are synchronized today: each
    /// one that was following the folder keeps a copy of what it inherited, so deleting a folder is
    /// never a silent change to what lands in the user's repositories.
    public func deleteProjectRoot(id: UUID) async throws {
        var config = try await store.configuration()
        guard config.roots.contains(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        var mcp = try await store.mcpConfiguration()
        let inheritedServers = mcp.projectServerIDs?[id.uuidString] ?? []
        let inheritedTags = mcp.projectServerTags?[id.uuidString] ?? []
        for index in config.projects.indices where config.projects[index].rootID == id {
            let detached = config.resolved(config.projects[index])
            let followed = config.inheritsRoot(config.projects[index])
            config.projects[index] = detached
            config.projects[index].rootID = nil
            config.projects[index].overridesRoot = nil
            if followed { Self.assign(&mcp, projectID: detached.id, serverIDs: inheritedServers, tags: inheritedTags) }
        }
        config.projectRoots = config.roots.filter { $0.id != id }
        var servers = mcp.projectServerIDs ?? [:]; servers.removeValue(forKey: id.uuidString); mcp.projectServerIDs = servers
        var tags = mcp.projectServerTags ?? [:]; tags.removeValue(forKey: id.uuidString); mcp.projectServerTags = tags
        try await store.save(config, mcp)
    }

    /// Subfolders that appeared in a watched parent folder after it was added. A folder whose disk
    /// is not mounted is skipped rather than reported as an error: an unavailable folder must not
    /// break the projects list.
    public func scanProjectRoots() async throws -> [DetectedProjectFolder] {
        let config = try await store.configuration()
        let known = Set(config.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let fm = FileManager.default
        var found: [DetectedProjectFolder] = []
        for root in config.roots where root.watchesNewFolders {
            let url = URL(fileURLWithPath: root.path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let ignored = Set(Self.standardized(root.ignoredPaths))
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for folder in contents {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let path = folder.standardizedFileURL.path
                guard !known.contains(path), !ignored.contains(path) else { continue }
                found.append(DetectedProjectFolder(rootID: root.id, rootName: root.name, path: path))
            }
        }
        return found.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Adds detected subfolders as projects following their parent folder, in one save.
    @discardableResult
    public func addDetectedFolders(_ folders: [DetectedProjectFolder]) async throws -> [Project] {
        guard !folders.isEmpty else { return [] }
        var config = try await store.configuration()
        let fm = FileManager.default
        var taken = Set(config.projects.map { $0.name.lowercased() })
        var added: [Project] = []
        for folder in folders {
            guard let root = config.roots.first(where: { $0.id == folder.rootID }) else {
                throw SkillboxError.projectNotFound(folder.rootName)
            }
            let path = URL(fileURLWithPath: folder.path).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SkillboxError.projectNotFound(path)
            }
            guard !config.projects.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) else { continue }
            let name = Self.uniqueProjectName(URL(fileURLWithPath: path).lastPathComponent, taken: taken)
            taken.insert(name.lowercased())
            let project = Project(name: name, path: path, tools: root.tools, rootID: root.id)
            config.projects.append(project)
            added.append(project)
        }
        guard !added.isEmpty else { return [] }
        try await store.save(config)
        return added
    }

    /// Stops offering these subfolders. The paths are remembered on the parent folder, so a folder
    /// the user does not want as a project is not proposed again at every launch.
    public func ignoreDetectedFolders(_ folders: [DetectedProjectFolder]) async throws {
        guard !folders.isEmpty else { return }
        var config = try await store.configuration()
        var roots = config.roots
        for (index, root) in roots.enumerated() {
            let paths = Self.standardized(folders.filter { $0.rootID == root.id }.map(\.path))
            guard !paths.isEmpty else { continue }
            roots[index].ignoredPaths = Self.standardized(root.ignoredPaths + paths).sorted()
        }
        config.projectRoots = roots
        try await store.save(config)
    }

    /// Brings dismissed subfolders back into the scan.
    public func clearIgnoredFolders(rootID: UUID) async throws {
        var config = try await store.configuration()
        guard let index = config.roots.firstIndex(where: { $0.id == rootID }) else {
            throw SkillboxError.projectNotFound(rootID.uuidString)
        }
        var roots = config.roots
        roots[index].ignoredPaths = []
        config.projectRoots = roots
        try await store.save(config)
    }

    /// Every subfolder the parent folder holds right now, so only what appears later counts as new.
    ///
    /// Without this, "nowy podfolder" would mean "każdy, który nie jest projektem": a folder the
    /// user deliberately left unticked while adding the batch would be proposed again immediately,
    /// and a folder full of unrelated directories would open with a list of all of them. Bringing
    /// them back is one button — `Przywróć pominięte` in the folder's settings.
    /// Folders that became projects are left out: they are not skipped, and listing them would tell
    /// the user their folder skips a dozen subfolders when it skips none.
    static func knownSubfolders(of root: URL, besides existing: [String], excluding projects: [String]) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let taken = Set(standardized(projects))
        let subfolders = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.standardizedFileURL.path }
            .filter { !taken.contains($0) }
        return standardized(existing + subfolders).sorted()
    }

    /// Normalizes a parent folder before it is stored, with the same rules a project follows.
    static func pruned(_ root: ProjectRoot, in catalog: Catalog) -> ProjectRoot {
        var root = root
        root.tags = normalizedTags(root.tags)
        let excluded = Set(root.excludedSkillIDs ?? [])
        let tagsByID = Dictionary(catalog.skills.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
        root.skillIDs = pruneRedundant(root.skillIDs, coveredBy: root.tags) { tagsByID[$0] ?? [] }
            .filter { !excluded.contains($0) }
        return root
    }

    /// Project names must stay unique, and a subfolder discovered automatically cannot ask the user
    /// for a different one, so a taken name gets a numeric suffix instead of failing the whole scan.
    static func uniqueProjectName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    static func standardized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }
}
