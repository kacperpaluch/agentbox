import SwiftUI
import SkillboxCore

/// A starting template, not an inherited configuration: it is copied into the editor only when
/// a project is created, so changing it can never alter an existing project.
struct ProjectDefaultsStrip: View {
    let model: AppModel
    let configure: () -> Void

    var body: some View {
        HStack(spacing: Space.tight + 4) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Domyślne dla nowych projektów").sectionLabel()
                Text(summary).rowMetadata().lineLimit(1)
            }
            Spacer()
            Button("Skonfiguruj…", action: configure).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, Space.page).padding(.vertical, Space.row)
        .background(Color.accentColor.opacity(0.06))
    }

    private var summary: String {
        let defaults = model.projectDefaults
        let tools = defaults.tools.filter(model.enabledTools.contains)
        let clients = tools.isEmpty ? "bez klientów" : tools.map { $0.rawValue.capitalized }.joined(separator: ", ")
        let skills = defaults.skillIDs.count + defaults.skillTags.count
        let servers = defaults.serverIDs.count + defaults.serverTags.count
        let docs = defaults.docIDs.count + defaults.docTags.count
        return "\(clients) · \(skills) skilli · \(servers) MCP · \(docs) dokumentów"
    }

}
