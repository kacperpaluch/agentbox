import SwiftUI
import SkillboxCore

// The navigation follows the job to be done: build a library, apply it to projects, then adjust the
// application. Recovery and history are supporting tools, not destinations users need to scan first.
enum SectionKind: String, CaseIterable, Identifiable {
    case library = "Biblioteka", projects = "Projekty", settings = "Ustawienia"
    var id: String { rawValue }
    var icon: String { switch self { case .library: "books.vertical"; case .projects: "folder"; case .settings: "gearshape" } }
}
