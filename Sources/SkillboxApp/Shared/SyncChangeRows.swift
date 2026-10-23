import SwiftUI
import SkillboxCore

struct SyncChangeRows: View {
    let added: [String], updated: [String], removed: [String]
    var body: some View { VStack(alignment: .leading, spacing: 3) { if added.isEmpty && updated.isEmpty && removed.isEmpty { Text("Brak zmian").font(.caption).foregroundStyle(.secondary) }; ForEach(added, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.green) }; ForEach(updated, id: \.self) { Label($0, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue) }; ForEach(removed, id: \.self) { Label($0, systemImage: "minus.circle.fill").foregroundStyle(.orange) } }.font(.caption) }
}
