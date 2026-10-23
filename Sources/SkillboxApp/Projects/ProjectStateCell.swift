import SwiftUI
import SkillboxCore

/// Second column: a project's status, or how many projects of a group need something.
struct ProjectStateCell: View {
    let row: ProjectTableRow
    let status: ProjectStatus?
    let pending: Int
    let problems: Int

    var body: some View {
        if row.project != nil {
            ProjectStatusBadge(status: status)
        } else {
            HStack(spacing: Space.tight) {
                if pending > 0 { MetaBadge(text: "\(pending) do synchronizacji", tint: .orange) }
                if problems > 0 { MetaBadge(text: "\(problems) z problemem", tint: .red) }
                if row.group.projects.isEmpty { Text("Brak projektów").rowMetadata().help("Dodaj podfoldery przez „Dodaj projekt → Wiele projektów” albo poczekaj, aż Agentbox je wykryje.") }
            }
        }
    }
}
