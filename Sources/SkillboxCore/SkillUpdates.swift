import Foundation

public struct SkillFileChange: Identifiable, Sendable {
    public let path: String
    public let kind: String
    public let oldText: String?
    public let newText: String?
    public let note: String
    public var id: String { path }
}

/// Immutable bytes, not a branch name that could move between preview and acceptance.
public struct SkillUpdatePreview: Identifiable, Sendable {
    public let skill: Skill
    public let revision: String?
    public let changes: [SkillFileChange]
    public let usage: UsageReport
    let library: URL
    let before: SkillTree
    let after: SkillTree
    public var id: String { skill.id }
}

public struct SkillUpdatePlan: Identifiable, Sendable {
    public let id = UUID()
    public let updates: [SkillUpdatePreview]
    public let unchanged: [String]
    public let failed: [SkippedSkill]
}

/// ponytail: preview bytes stay in memory; use private disk staging if skill collections become too large.
struct SkillTree: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Kind: Sendable { case directory, file, link }
        let kind: Kind
        let data: Data
        let permissions: Int
        var text: String? { kind == .directory ? nil : String(data: data, encoding: .utf8).flatMap { $0.contains("\0") ? nil : $0 } }
    }
    let entries: [String: Entry]
    var rootPermissions: Int = 0o755

    static func read(_ root: URL) throws -> SkillTree {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SkillboxError.unsafePath(root.path) }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [String: Entry] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                // Git's checkout metadata and Finder's metadata are not skill resources.
                guard file.lastPathComponent != ".git", file.lastPathComponent != ".DS_Store" else { continue }
                let path = prefix + file.lastPathComponent
                let attrs = try fm.attributesOfItem(atPath: file.path)
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(base + "/") else { throw SkillboxError.unsafePath(file.path) }
                let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                switch attrs[.type] as? FileAttributeType {
                case .typeDirectory:
                    entries[path] = Entry(kind: .directory, data: Data(), permissions: mode)
                    try visit(file, prefix: path + "/")
                case .typeRegular:
                    entries[path] = Entry(kind: .file, data: try Data(contentsOf: file), permissions: mode)
                case .typeSymbolicLink:
                    let destination = try fm.destinationOfSymbolicLink(atPath: file.path)
                    guard !destination.hasPrefix("/") else { throw SkillboxError.unsafePath(file.path) }
                    entries[path] = Entry(kind: .link, data: Data(destination.utf8), permissions: 0)
                default: throw SkillboxError.unsafePath("nieobsługiwany typ pliku: \(file.path)")
                }
            }
        }
        try visit(root, prefix: "")
        return SkillTree(entries: entries, rootPermissions: mode)
    }

    func write(to root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for path in entries.keys.sorted() {
            guard let entry = entries[path] else { continue }
            let file = root.appending(path: path)
            switch entry.kind {
            case .directory: try fm.createDirectory(at: file, withIntermediateDirectories: true)
            case .file: try entry.data.write(to: file, options: .atomic)
            case .link: try fm.createSymbolicLink(atPath: file.path, withDestinationPath: String(decoding: entry.data, as: UTF8.self))
            }
        }
        // Set directory permissions last, so a read-only directory can still be populated.
        for path in entries.keys.sorted().reversed() {
            if let entry = entries[path], entry.kind != .link {
                try fm.setAttributes([.posixPermissions: entry.permissions], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try fm.setAttributes([.posixPermissions: rootPermissions], ofItemAtPath: root.path)
    }

    func changes(to other: SkillTree) -> [SkillFileChange] {
        let rootChange = rootPermissions == other.rootPermissions ? [] : [SkillFileChange(path: ".", kind: "Zmiana", oldText: nil, newText: nil, note: "Uprawnienia katalogu skilla: \(String(rootPermissions, radix: 8)) → \(String(other.rootPermissions, radix: 8))")]
        return rootChange + Set(entries.keys).union(other.entries.keys).sorted().compactMap { path in
            let old = entries[path], new = other.entries[path]
            guard old != new else { return nil }
            var notes: [String] = []
            if old?.kind == .directory || new?.kind == .directory { notes.append("Katalog lub zmiana typu pliku") }
            if old?.kind == .link || new?.kind == .link { notes.append("Dowiązanie symboliczne — tekst pokazuje jego cel") }
            if old?.kind == .file && old?.text == nil || new?.kind == .file && new?.text == nil { notes.append("Plik binarny lub tekst poza UTF-8: \(old?.data.count ?? 0) → \(new?.data.count ?? 0) B") }
            if old?.permissions != new?.permissions { notes.append("Uprawnienia: \(old.map { String($0.permissions, radix: 8) } ?? "—") → \(new.map { String($0.permissions, radix: 8) } ?? "—")") }
            return SkillFileChange(path: path, kind: old == nil ? "Dodanie" : new == nil ? "Usunięcie" : "Zmiana", oldText: old?.text, newText: new?.text, note: notes.joined(separator: "; "))
        }
    }
}

extension SkillboxService {
    public func previewSkillUpdates(ids: [String]? = nil) async throws -> SkillUpdatePlan {
        let catalog = try await store.catalog()
        let targets = catalog.skills.filter { ids?.contains($0.id) ?? ($0.source.kind == .git) }
        if let missing = ids?.first(where: { id in !catalog.skills.contains { $0.id == id } }) { throw SkillboxError.skillNotFound(missing) }
        // Disk identifiers are validated before they become paths, including failed groups.
        for skill in targets where !Self.isSafeSkillID(skill.id) { throw SkillboxError.unsafePath(skill.id) }
        var updates: [SkillUpdatePreview] = [], unchanged: [String] = [], failed: [SkippedSkill] = []
        func record(_ preview: SkillUpdatePreview) {
            if preview.changes.isEmpty { unchanged.append(preview.id) }
            else { updates.append(preview) }
        }
        for skill in targets where skill.source.kind == .local {
            do { record(try await inspectedUpdate(skill, source: URL(fileURLWithPath: skill.source.location), revision: nil)) }
            catch { failed.append(SkippedSkill(id: skill.id, reason: error.localizedDescription)) }
        }
        let groups = Dictionary(grouping: targets.filter { $0.source.kind == .git }) { "\($0.source.location)|\($0.source.branch ?? "")" }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            let temp = Self.scratchDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                guard Self.isAllowedGitLocation(first.source.location) else { throw SkillboxError.invalidSkill("niedozwolone źródło Git") }
                var args = ["clone", "--depth", "1"]
                if let branch = first.source.branch { args += ["--branch", branch] }
                args += ["--", first.source.location, temp.path]
                _ = try ProcessRunner.run("/usr/bin/git", args)
                let revision = try ProcessRunner.run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: temp)
                for skill in group {
                    do {
                        let source = skill.source.subpath.map { temp.appending(path: $0) } ?? temp
                        let base = temp.resolvingSymlinksInPath().standardizedFileURL.path
                        let resolved = source.resolvingSymlinksInPath().standardizedFileURL.path
                        guard resolved == base || resolved.hasPrefix(base + "/") else { throw SkillboxError.unsafePath(skill.id) }
                        record(try await inspectedUpdate(skill, source: source, revision: revision))
                    } catch { failed.append(SkippedSkill(id: skill.id, reason: error.localizedDescription)) }
                }
            } catch { failed += group.map { SkippedSkill(id: $0.id, reason: error.localizedDescription) } }
        }
        return SkillUpdatePlan(updates: updates.sorted { $0.id < $1.id }, unchanged: unchanged.sorted(), failed: failed.sorted { $0.id < $1.id })
    }

    private func inspectedUpdate(_ skill: Skill, source: URL, revision: String?) async throws -> SkillUpdatePreview {
        let destination = try await checkedUpdateDestination(skill.id)
        let before = try SkillTree.read(destination), after = try SkillTree.read(source)
        guard after.entries["SKILL.md"]?.kind == .file else { throw SkillboxError.invalidSkill("brak zwykłego pliku SKILL.md: \(skill.id)") }
        return SkillUpdatePreview(skill: skill, revision: revision, changes: before.changes(to: after), usage: try await usage(ofSkill: skill.id), library: store.root, before: before, after: after)
    }

    private func checkedUpdateDestination(_ id: String) async throws -> URL {
        guard Self.isSafeSkillID(id) else { throw SkillboxError.unsafePath(id) }
        let base = await store.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let destination = base.appending(path: id)
        let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw SkillboxError.unsafePath(destination.path) }
        guard destination.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == base.path else { throw SkillboxError.unsafePath(destination.path) }
        return destination
    }

    @discardableResult
    public func applySkillUpdates(_ previews: [SkillUpdatePreview], applicationVersion: String = "CLI") async throws -> [Skill] {
        guard !previews.isEmpty else { return [] }
        guard Set(previews.map(\.id)).count == previews.count else { throw SkillboxError.invalidSkill("powtórzony skill w aktualizacji") }
        let fm = FileManager.default, scratch = Self.scratchDirectory()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? fm.removeItem(at: scratch) } }
        // Build every replacement before touching the originals.
        for preview in previews {
            guard preview.library == store.root else { throw SkillboxError.invalidSkill("podgląd pochodzi z innej biblioteki") }
            _ = try await checkedUpdateDestination(preview.id)
            try preview.after.write(to: scratch.appending(path: "new/\(preview.id)"))
        }
        _ = try await createFullBackup(applicationVersion: applicationVersion)
        var catalog = try await store.catalog()
        var targets: [URL] = []
        for preview in previews {
            let target = try await checkedUpdateDestination(preview.id)
            guard catalog.skills.first(where: { $0.id == preview.id }) == preview.skill,
                  try SkillTree.read(target) == preview.before else {
                throw SkillboxError.invalidSkill("\(preview.id) zmienił się od podglądu — sprawdź aktualizacje ponownie")
            }
            targets.append(target)
        }
        try fm.createDirectory(at: scratch.appending(path: "old"), withIntermediateDirectories: true)
        var moved: [(target: URL, saved: URL)] = [], installed = Set<URL>(), updated: [Skill] = []
        do {
            for (preview, target) in zip(previews, targets) {
                let saved = scratch.appending(path: "old/\(preview.id)")
                try fm.moveItem(at: target, to: saved)
                moved.append((target, saved))
                try fm.moveItem(at: scratch.appending(path: "new/\(preview.id)"), to: target)
                installed.insert(target)
                var skill = preview.skill
                skill.source.revision = preview.revision
                skill.updatedAt = .now
                catalog.skills[catalog.skills.firstIndex { $0.id == skill.id }!] = skill
                updated.append(skill)
            }
            try await store.save(catalog)
        } catch {
            var report = RollbackReport()
            for item in moved.reversed() {
                report.attempt(item.target.path) {
                    if installed.contains(item.target) { try fm.removeItem(at: item.target) }
                    try fm.moveItem(at: item.saved, to: item.target)
                }
            }
            keep = !report.succeeded
            throw report.error(after: error, keeping: keep ? scratch.path : nil)
        }
        return updated
    }
}
