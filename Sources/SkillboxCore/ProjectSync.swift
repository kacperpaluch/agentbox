import Foundation

extension SkillboxService {
    public func previewProjectSync(projectID: UUID) async throws -> ProjectSyncPreview {
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let catalog = try await store.catalog()
        let selected = catalog.skills.filter { project.skillIDs.contains($0.id) || !$0.tags.filter(project.tags.contains).isEmpty }
        let current = Set(selected.map(\.id))
        let fm = FileManager.default
        let skills = project.tools.map { tool -> SkillSyncPreview in
            let target = URL(fileURLWithPath: project.path).appending(path: tool.projectSkillsPath)
            let manifest = target.appending(path: ".skillbox.json")
            let previous = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? [])
            return SkillSyncPreview(
                tool: tool,
                target: target.path,
                added: Array(current.subtracting(previous)).sorted(),
                updated: Array(current.intersection(previous)).filter { fm.fileExists(atPath: target.appending(path: $0).path) }.sorted(),
                removed: Array(previous.subtracting(current)).sorted()
            )
        }
        return ProjectSyncPreview(skills: skills, mcp: try await previewMCP(projectID: projectID))
    }

    @discardableResult
    public func syncProjectTransaction(projectID: UUID) async throws -> ProjectSyncPreview {
        let preview = try await previewProjectSync(projectID: projectID)
        let config = try await store.configuration()
        guard let project = config.projects.first(where: { $0.id == projectID }) else { throw SkillboxError.projectNotFound(projectID.uuidString) }
        let projectURL = URL(fileURLWithPath: project.path)
        let fm = FileManager.default
        let backup = projectURL.appending(path: ".skillbox/sync-backups/\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)

        var targets = preview.skills.map { URL(fileURLWithPath: $0.target) }
        targets += preview.mcp.map { URL(fileURLWithPath: $0.file) }
        targets.append(projectURL.appending(path: ".skillbox/mcp-manifest.json"))
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        var saved: [(target: URL, copy: URL?, existed: Bool)] = []

        do {
            for (index, target) in unique.enumerated() {
                let existed = fm.fileExists(atPath: target.path)
                let copy = existed ? backup.appending(path: "item-\(index)") : nil
                if let copy { try fm.copyItem(at: target, to: copy) }
                saved.append((target, copy, existed))
            }
            _ = try await syncProject(id: projectID)
            _ = try await syncMCP(projectID: projectID)
            try Self.pruneSyncBackups(projectURL, keeping: 10)
            return preview
        } catch {
            for item in saved.reversed() {
                if fm.fileExists(atPath: item.target.path) { try? fm.removeItem(at: item.target) }
                if item.existed, let copy = item.copy {
                    try? fm.createDirectory(at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.copyItem(at: copy, to: item.target)
                }
            }
            try? Self.pruneSyncBackups(projectURL, keeping: 10)
            throw error
        }
    }

    private static func pruneSyncBackups(_ project: URL, keeping limit: Int) throws {
        let root = project.appending(path: ".skillbox/sync-backups")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let items = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let sorted = items.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for item in sorted.dropFirst(limit) { try fm.removeItem(at: item) }
    }
}
