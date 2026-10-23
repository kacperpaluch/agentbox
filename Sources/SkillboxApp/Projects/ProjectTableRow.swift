import SkillboxCore

/// One line of the projects table: a group header or a project inside it. A group's id has its own
/// namespace, so a folder can never share an identity with a project row (the outline then expands
/// or collapses the wrong row).
struct ProjectTableRow: Identifiable {
    let group: ProjectGroup
    let project: Project?
    var id: String { project.map { $0.id.uuidString } ?? "group/\(group.id)" }

    init(group: ProjectGroup) { self.group = group; self.project = nil }
    init(project: Project, in group: ProjectGroup) { self.group = group; self.project = project }

    /// The projects a selection stands for: a selected group means its visible projects, the way
    /// selecting a folder in Finder acts on what is inside it.
    static func projects(for ids: Set<String>, in groups: [(group: ProjectGroup, shown: [Project])]) -> [Project] {
        var seen = Set<String>(), result: [Project] = []
        for (group, shown) in groups {
            let whole = ids.contains(ProjectTableRow(group: group).id)
            for project in shown where (whole || ids.contains(project.id.uuidString)) && seen.insert(project.id.uuidString).inserted {
                result.append(project)
            }
        }
        return result
    }
}
