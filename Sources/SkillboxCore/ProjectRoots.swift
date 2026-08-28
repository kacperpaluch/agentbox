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

    /// The project as everything downstream must see it: its own record plus the attachments that
    /// actually apply to it, which for a project following a parent folder are the folder's.
    ///
    /// This is the single seam where `selections.json` turns back into the shape the whole sync path
    /// reads. `Project.tools`, `.skillIDs`, `.tags` and `.excludedSkillIDs` are never stored on the
    /// project — they are filled in here, so a change on the folder reaches every project in it
    /// without any record being copied anywhere.
    public func resolved(_ project: Project) -> Project {
        var resolved = project
        let selection = storedSelection(for: .project(selectionID(for: project)))
        resolved.tools = selection.tools
        resolved.skillIDs = selection.skillIDs
        resolved.tags = selection.skillTags
        resolved.excludedSkillIDs = selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs
        if let root = root(for: project), project.overridesRoot != true { resolved.manageGitignore = root.manageGitignore }
        return resolved
    }

    /// The folder counterpart of `resolved(_ project:)` — its own attachments, never inherited from
    /// anywhere, because a folder is where inheritance starts.
    public func resolved(_ root: ProjectRoot) -> ProjectRoot {
        var resolved = root
        let selection = storedSelection(for: .root(root.id))
        resolved.tools = selection.tools
        resolved.skillIDs = selection.skillIDs
        resolved.tags = selection.skillTags
        resolved.excludedSkillIDs = selection.excludedSkillIDs.isEmpty ? nil : selection.excludedSkillIDs
        return resolved
    }

    public var resolvedProjects: [Project] { projects.map(resolved) }
    public var resolvedRoots: [ProjectRoot] { roots.map(resolved) }

    /// Which identifier owns a project's attachments: the parent folder's when the project follows
    /// it, its own otherwise. Roots and projects share the assignment dictionaries in `mcp.json` and
    /// `docs.json`, because their UUIDs never collide and one lookup keeps inherited and own
    /// selections on the same path.
    ///
    /// `mcp.json` and `docs.json` key their assignments identically, so this answers for both. It
    /// used to exist twice under two names — `mcpSelectionID` and `docSelectionID` — with byte-for-byte
    /// the same body, which meant a change to inheritance had to be remembered in two places.
    public func selectionID(for project: Project) -> UUID {
        inheritsRoot(project) ? (project.rootID ?? project.id) : project.id
    }
}

extension SkillboxService {
    public func projectRoots() async throws -> [ProjectRoot] {
        try await store.configuration().resolvedRoots.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates a parent folder together with the projects picked from it. Everything lands in one
    /// save, so a single user action takes a single recovery snapshot and never leaves a folder
    /// without its projects.
    @discardableResult
    public func addProjectRoot(_ root: ProjectRoot, folders: [String], selection: AttachmentSelection, treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
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
        var stored = root
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
            projects.append(Project(name: name, path: folder, rootID: stored.id))
        }
        if treatingExistingAsKnown {
            let projectPaths = (config.projects + projects).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            stored.ignoredPaths = Self.knownSubfolders(of: rootURL, besides: stored.ignoredPaths, excluding: projectPaths)
        }
        config.projectRoots = config.roots + [stored]
        config.projects.append(contentsOf: projects)
        var mcp = try await store.mcpConfiguration()
        // A new folder owns the selection its projects follow, so it is where the defaults land.
        Self.applyDefaultDisabledGlobalServers(&mcp, selectionID: stored.id)
        config.selections[stored.id.uuidString] = Self.pruned(selection, catalog: try await store.catalog(), mcp: mcp, docs: try await store.docsConfiguration())
        try await store.save(config, mcp)
        return stored
    }

    /// Saves the settings shared by every project in the folder. Projects that follow the folder
    /// pick the change up on their next preview; projects with their own settings are untouched.
    public func updateProjectRoot(_ root: ProjectRoot, selection: AttachmentSelection) async throws {
        var config = try await store.configuration()
        guard let index = config.roots.firstIndex(where: { $0.id == root.id }) else {
            throw SkillboxError.projectNotFound(root.name)
        }
        guard !config.roots.contains(where: { $0.id != root.id && $0.name.caseInsensitiveCompare(root.name) == .orderedSame }) else {
            throw SkillboxError.invalidSkill("folder nadrzędny o nazwie \(root.name) już istnieje")
        }
        var roots = config.roots
        var stored = root
        // The folder's location is set when it is added; editing only changes what it configures.
        stored.path = roots[index].path
        stored.ignoredPaths = Self.standardized(stored.ignoredPaths)
        roots[index] = stored
        config.projectRoots = roots
        config.selections[stored.id.uuidString] = Self.pruned(selection, catalog: try await store.catalog(), mcp: try await store.mcpConfiguration(), docs: try await store.docsConfiguration())
        try await store.save(config)
    }

    /// Turns a folder that already holds projects into a parent folder.
    ///
    /// Projects added one by one — or in a batch before parent folders existed — have no folder to
    /// inherit from, so without this the shared settings would be reachable only for folders added
    /// from scratch. Every project passed in joins the folder; `following` says which ones drop
    /// their own settings for the folder's, and the rest keep exactly what they synchronize today.
    @discardableResult
    public func adoptProjectsIntoRoot(_ root: ProjectRoot, following: [UUID], keepingOwnSettings: [UUID], selection: AttachmentSelection, treatingExistingAsKnown: Bool = true) async throws -> ProjectRoot {
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
        var stored = root
        stored.path = rootURL.path
        stored.ignoredPaths = Self.standardized(stored.ignoredPaths)
        let mcp = try await store.mcpConfiguration()
        let docs = try await store.docsConfiguration()
        for index in config.projects.indices {
            let id = config.projects[index].id
            guard followers.contains(id) || owners.contains(id) else { continue }
            config.projects[index].rootID = stored.id
            config.projects[index].overridesRoot = owners.contains(id) ? true : nil
            guard followers.contains(id) else { continue }
            // The folder answers for these projects now. Leaving their old selection behind would be
            // a second source of truth that nothing reads.
            config.projects[index].manageGitignore = nil
            config.selections.removeValue(forKey: id.uuidString)
        }
        if treatingExistingAsKnown {
            stored.ignoredPaths = Self.knownSubfolders(of: rootURL, besides: stored.ignoredPaths, excluding: config.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        }
        config.projectRoots = config.roots + [stored]
        config.selections[stored.id.uuidString] = Self.pruned(selection, catalog: try await store.catalog(), mcp: mcp, docs: docs)
        try await store.save(config, mcp, docs)
        return stored
    }

    /// Removes the shared settings. The projects stay exactly as they are synchronized today: each
    /// one that was following the folder keeps a copy of what it inherited, so deleting a folder is
    /// never a silent change to what lands in the user's repositories.
    public func deleteProjectRoot(id: UUID) async throws {
        var config = try await store.configuration()
        guard config.roots.contains(where: { $0.id == id }) else { throw SkillboxError.projectNotFound(id.uuidString) }
        let inherited = config.storedSelection(for: .root(id))
        for index in config.projects.indices where config.projects[index].rootID == id {
            let followed = config.inheritsRoot(config.projects[index])
            let gitignore = config.resolved(config.projects[index]).manageGitignore
            config.projects[index].rootID = nil
            config.projects[index].overridesRoot = nil
            if followed {
                config.projects[index].manageGitignore = gitignore
                config.selections[config.projects[index].id.uuidString] = inherited
            }
        }
        config.selections.removeValue(forKey: id.uuidString)
        config.projectRoots = config.roots.filter { $0.id != id }
        try await store.save(config)
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
