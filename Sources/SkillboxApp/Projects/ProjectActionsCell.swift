import SwiftUI
import SkillboxCore

/// Last column: the one action a row most often needs, then the rest in a menu.
struct ProjectActionsCell: View {
    let row: ProjectTableRow
    let status: ProjectStatus?
    let pending: Int
    let isWorking: Bool
    let perform: (ProjectRowAction) -> Void

    var body: some View {
        HStack(spacing: Space.tight) {
            if let project = row.project {
                // Prominent only where there is something to write; elsewhere it would be one of dozens
                // of identical blue buttons drowning out the rows that need attention.
                // The two styles are different types, so this is a branch rather than a ternary.
                if isPending {
                    Button("Synchronizuj") { perform(.sync(project)) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Synchronizuj") { perform(.sync(project)) }.buttonStyle(.bordered).disabled(status?.state == .missing)
                }
            } else if pending > 0 {
                Button("Synchronizuj grupę") { perform(.syncGroup(row.group)) }.buttonStyle(.bordered).disabled(isWorking)
            } else if let root = row.group.root {
                Button("Ustawienia folderu") { perform(.rootSettings(root)) }.buttonStyle(.bordered)
            } else {
                Button("Wspólne ustawienia…") { perform(.setUpRoot(row.group)) }.buttonStyle(.bordered)
                    .help("Ustaw skille i MCP wspólne dla wszystkich projektów w tym folderze")
            }
            RowMenu { ProjectRowMenu(row: row, isMissing: status?.state == .missing, perform: perform) }
        }
        .controlSize(.small)
    }

    private var isPending: Bool { if case .pending? = status?.state { true } else { false } }
}
