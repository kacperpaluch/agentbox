import SwiftUI
import SkillboxCore

/// Two lines per server: name, transport and tags on top; underneath, what it runs and where it is
/// used. Counts of arguments and variables said nothing — "0 argumentów" for every HTTP server.
struct MCPServerRow: View {
    let server: MCPServer
    let usageKey: AnyHashable
    let usage: () async -> UsageReport
    let onDetails: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: server.transport == .stdio ? "terminal" : "globe").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.row) {
                    Text(server.name).rowTitle()
                    MetaBadge(text: server.transport == .stdio ? "Lokalny" : server.transport.rawValue.uppercased())
                    ForEach(server.tags ?? [], id: \.self) { TagPill(tag: $0) }
                }
                HStack(spacing: Space.row) {
                    Text(server.launchSummary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("·").rowMetadata()
                    UsageCaption(key: usageKey, load: usage)
                }
            }
            Spacer()
            RowMenu {
                Button("Szczegóły…", action: onDetails)
                Button("Duplikuj…", action: onDuplicate)
                Divider()
                Button("Usuń…", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, Space.tight)
    }
}
