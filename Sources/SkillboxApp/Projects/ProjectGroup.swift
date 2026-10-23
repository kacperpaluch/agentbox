import Foundation
import SkillboxCore

/// Projects shown together: those of one parent folder, or — for projects added on their own — those
/// sitting in the same directory.
struct ProjectGroup: Identifiable {
    let path: String
    let root: ProjectRoot?
    let projects: [Project]
    var id: String { root?.id.uuidString ?? path }
    var name: String { root?.name ?? URL(fileURLWithPath: path).lastPathComponent }
}
