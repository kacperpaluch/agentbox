import SwiftUI
import SkillboxCore

/// Third column: only what makes this project differ from the rest of its group — its own settings
/// inside a folder, other clients, other skill tags — so identical projects read as identical.
struct ProjectExceptionsCell: View {
    let project: Project
    let ownSettingsInRoot: Bool
    let rootName: String?
    let enabledTools: [Tool]
    let usualTools: Set<Tool>
    let usualTags: Set<String>

    var body: some View {
        HStack(spacing: Space.tight + 2) {
            if ownSettingsInRoot {
                MetaBadge(text: "Własne ustawienia", tint: .orange)
                    .help("Projekt nie dziedziczy ustawień folderu\(rootName.map { " „\($0)”" } ?? "")")
            }
            if let toolsException { Text(toolsException).rowMetadata().lineLimit(1) }
            if Set(project.tags) != usualTags {
                Text(project.tags.isEmpty ? "Bez tagów" : project.tags.map { "#\($0)" }.joined(separator: " "))
                    .rowMetadata().lineLimit(1).help(project.tags.joined(separator: ", "))
            }
        }
    }

    /// Clients named only when they differ from what the rest of the group uses.
    private var toolsException: String? {
        let used = enabledTools.filter(project.tools.contains)
        guard Set(used) != usualTools else { return nil }
        let names = used.map { $0.rawValue.capitalized }.joined(separator: ", ")
        return used.isEmpty ? "Bez klientów" : Set(used).isSubset(of: usualTools) ? "Tylko \(names)" : names
    }
}
