import SwiftUI
import SkillboxCore

/// The actions of one row, as menu items.
struct ProjectRowMenu: View {
    let row: ProjectTableRow
    let isMissing: Bool
    let perform: (ProjectRowAction) -> Void

    var body: some View {
        if row.isMac {
            Button("Pokaż w inspektorze") { perform(.inspectMac) }
            Button("Serwery klientów…") { perform(.clientServers) }
        } else if let project = row.project {
            Button("Synchronizuj…") { perform(.sync(project)) }.disabled(isMissing)
            Button("Pokaż w inspektorze") { perform(.inspect(project)) }
            Button("Nazwa i folder…") { perform(.edit(project)) }
            Button("Przejmij z projektu…") { perform(.adopt(project)) }
            Divider()
            Button("Usuń projekt…", role: .destructive) { perform(.delete(project)) }
        } else if let root = row.group.root {
            Button("Synchronizuj grupę…") { perform(.syncGroup(row.group)) }.disabled(row.group.projects.isEmpty)
            Button("Ustawienia folderu…") { perform(.rootSettings(root)) }
            Divider()
            // Only the shared settings go; the projects stay, each with a copy of what it inherited.
            Button("Usuń wspólne ustawienia folderu…", role: .destructive) { perform(.deleteRoot(root)) }
        } else {
            Button("Synchronizuj grupę…") { perform(.syncGroup(row.group)) }.disabled(row.group.projects.isEmpty)
            Button("Wspólne ustawienia…") { perform(.setUpRoot(row.group)) }
        }
    }
}
