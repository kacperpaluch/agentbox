import SwiftUI
import SkillboxCore

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: Space.tight) {
            ForEach(tags.prefix(4), id: \.self) { TagPill(tag: $0) }
            if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
