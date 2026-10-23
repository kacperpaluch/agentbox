import SwiftUI
import SkillboxCore

/// What the Projekty list shows. "Problemy" are the projects that cannot be synchronized as they are.
enum ProjectFilter: String, CaseIterable, Identifiable {
    case all = "Wszystkie", pending = "Do synchronizacji", problems = "Problemy"
    var id: String { rawValue }

    func includes(_ state: ProjectStatus.State?) -> Bool {
        switch (self, state) {
        case (.all, _), (.pending, .pending?), (.problems, .blocked?), (.problems, .missing?): true
        default: false
        }
    }
    /// Lower comes first: what needs a decision, then what needs a sync, then everything else.
    static func rank(_ state: ProjectStatus.State?) -> Int {
        switch state {
        case .blocked?: 0
        case .missing?: 1
        case .pending?: 2
        case .synced?: 3
        case nil: 4
        }
    }
    static func matches(_ project: Project, search: String) -> Bool {
        search.isEmpty || project.name.localizedStandardContains(search) || project.path.localizedStandardContains(search)
    }
    /// The order inside a group: attention first, then by name.
    /// What most projects of a group have. A row names its clients and tags only when they differ,
    /// so a folder whose projects all use Claude and `#seo` does not say so on every line.
    static func usual<T: Hashable>(_ sets: [Set<T>], otherwise fallback: Set<T>) -> Set<T> {
        let counts = Dictionary(sets.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.count > $1.key.count }?.key ?? fallback
    }
    static func usualTools(_ projects: [Project], enabled: [Tool]) -> Set<Tool> {
        usual(projects.map { Set($0.tools.filter(enabled.contains)) }, otherwise: Set(enabled))
    }
    static func usualTags(_ projects: [Project]) -> Set<String> { usual(projects.map { Set($0.tags) }, otherwise: []) }
    static func sorted(_ projects: [Project], statuses: [UUID: ProjectStatus]) -> [Project] {
        projects.sorted {
            let (left, right) = (rank(statuses[$0.id]?.state), rank(statuses[$1.id]?.state))
            return left != right ? left < right : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
