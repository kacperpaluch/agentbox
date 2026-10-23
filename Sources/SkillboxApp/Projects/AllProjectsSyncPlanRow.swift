import SwiftUI
import SkillboxCore

struct AllProjectsSyncPlanRow: View {
    let plan: ProjectSyncPlan
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.preview.skills, id: \.tool) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.target).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed)
                    }
                }
                ForEach(plan.preview.mcp, id: \.tool.rawValue) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.file).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: [], removed: item.removed)
                    }
                }
                ForEach(plan.preview.docs, id: \.file) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.file).font(.caption).foregroundStyle(.secondary)
                        SyncChangeRows(added: item.added, updated: [], removed: item.removed)
                    }
                }
                if !plan.preview.plugins.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Pluginy Claude").font(.caption.weight(.semibold)); ForEach(plan.preview.plugins) { item in ClaudePluginPreviewRow(item: item) } } }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.project.name).font(.headline)
                Text(plan.project.path).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
