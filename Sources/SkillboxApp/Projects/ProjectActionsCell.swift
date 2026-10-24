import SwiftUI
import SkillboxCore

/// Last column: a button only where something is waiting to be written, then the rest in a menu.
/// A row that is up to date says so in its status; a button there would be one of dozens of
/// identical ones drowning out the rows that need attention.
struct ProjectActionsCell: View {
    let row: ProjectTableRow
    let state: ProjectStatus.State?
    let perform: (ProjectRowAction) -> Void

    var body: some View {
        HStack(spacing: Space.tight) {
            if isPending {
                if let project = row.project {
                    Button("Synchronizuj") { perform(.sync(project)) }.buttonStyle(.borderedProminent)
                } else if row.isMac {
                    // The Mac's preview lives in the inspector, next to the choice that produced it.
                    Button("Synchronizuj") { perform(.inspectMac) }.buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
            RowMenu { ProjectRowMenu(row: row, isMissing: state == .missing, perform: perform) }
        }
        .controlSize(.small)
    }

    private var isPending: Bool { if case .pending? = state { true } else { false } }
}
