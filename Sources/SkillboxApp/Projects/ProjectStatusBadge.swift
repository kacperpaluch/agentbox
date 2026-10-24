import SwiftUI
import SkillboxCore

struct ProjectStatusBadge: View {
    let state: ProjectStatus.State?
    var body: some View {
        switch state {
        case .synced:
            // The common case stays quiet so the states that need something stand out.
            Label { Text("Aktualny").foregroundStyle(.secondary) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }.font(.caption)
        case .pending(let added, let outdated, let removed):
            Label(summary(added, outdated, removed), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
        case .blocked(let reason):
            Label("Zablokowany", systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(.red)
                .help(reason).accessibilityValue(reason)  // the tooltip alone needs a mouse
        case .missing:
            Label("Brak folderu", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.red)
        case nil:
            Label("Nieznany", systemImage: "clock").font(.caption).foregroundStyle(.tertiary)
        }
    }
    private func summary(_ added: Int, _ outdated: Int, _ removed: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if outdated > 0 { parts.append("~\(outdated)") }
        if removed > 0 { parts.append("-\(removed)") }
        return "Do synchronizacji " + parts.joined(separator: " ")
    }
}
