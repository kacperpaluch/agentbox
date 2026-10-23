import SwiftUI
import SkillboxCore

struct SkillRow: View {
    let skill: Skill
    let updateAvailable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight + 1) {
            HStack {
                Image(systemName: skill.source.kind == .git ? "network" : "internaldrive").foregroundStyle(.tint)
                Text(skill.name).rowTitle()
                Spacer()
                if updateAvailable { MetaBadge(text: "Aktualizacja", tint: .orange) }
            }
            if skill.tags.isEmpty { Text("bez tagów").font(.caption).foregroundStyle(.tertiary) } else { FlowTags(tags: skill.tags) }
        }
        .padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
