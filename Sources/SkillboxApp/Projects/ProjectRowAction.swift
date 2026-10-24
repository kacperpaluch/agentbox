import SkillboxCore

/// Everything a row of the projects table can ask for. One list feeds the row's "…" menu and its
/// right-click menu, so the two can never offer different things.
enum ProjectRowAction {
    case sync(Project), inspect(Project), edit(Project), adopt(Project), delete(Project)
    case syncGroup(ProjectGroup), rootSettings(ProjectRoot), setUpRoot(ProjectGroup), deleteRoot(ProjectRoot)
    case inspectMac, clientServers
}
