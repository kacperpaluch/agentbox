import SwiftUI
import SkillboxCore

struct ProjectSyncOutcomeRow: View {
    let outcome: ProjectSyncOutcome
    private var icon: (String, Color) {
        switch outcome.state {
        case .synced: ("checkmark.circle.fill", .green)
        case .upToDate: ("equal.circle.fill", .secondary)
        case .failed: ("xmark.octagon.fill", .red)
        case .skipped: ("minus.circle.fill", .secondary)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.plan.project.name).fontWeight(.medium)
                switch outcome.state {
                case .synced: Text("Zsynchronizowano").font(.caption).foregroundStyle(.secondary)
                case .upToDate: Text("Bez zmian — nic nie zapisano i nie utworzono backupu.").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason): Text("Cofnięto do stanu sprzed synchronizacji — \(reason)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                case .skipped: Text("Pominięto po wcześniejszym błędzie; pliki projektu nie zostały zmienione.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
