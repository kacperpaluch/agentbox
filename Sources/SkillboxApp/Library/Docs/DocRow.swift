import SwiftUI
import SkillboxCore

struct DocRow: View {
    let doc: AgentDoc
    /// Shown only by a search that found this document through its text, not its name.
    var matchedInContent = false
    let usageKey: AnyHashable
    let usage: () async -> UsageReport
    let onEdit: () -> Void
    let onDelete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: "doc.text").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.row) {
                    Text(doc.name).rowTitle()
                    ForEach(doc.tags, id: \.self) { TagPill(tag: $0) }
                    if matchedInContent { MetaBadge(text: "w treści", tint: .secondary) }
                }
                UsageCaption(key: usageKey, load: usage)
            }
            Spacer()
            RowMenu {
                Button("Edytuj…", action: onEdit)
                Divider()
                Button("Usuń…", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, Space.tight)
    }
}
