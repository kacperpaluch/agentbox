import SwiftUI
import SkillboxCore

/// One line per selected plugin, saying plainly whether synchronization still has work to do for
/// it. The distinction matters: an already declared plugin is left alone, a missing one is handed
/// to Claude Code.
struct ClaudePluginPreviewRow: View {
    let item: ClaudePluginPreview
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.isInstalled ? "Już w projekcie: \(item.name)" : "Zostanie zainstalowany: \(item.name)")
                Text(item.plugin).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(item.scope.displayName).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: item.isInstalled ? "checkmark.circle" : "puzzlepiece.extension")
        }
        .font(.caption)
        .foregroundStyle(item.isInstalled ? Color.secondary : Color.primary)
    }
}
