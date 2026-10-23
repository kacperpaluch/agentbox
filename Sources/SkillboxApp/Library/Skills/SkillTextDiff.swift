import SwiftUI
import SkillboxCore

struct SkillTextDiff: View {
    let old: String, new: String
    @State private var lines: [DiffLine] = []
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) { ForEach(lines) { DiffLineRow(line: $0) } }
            .task { lines = TextDiff.lines(old: old, new: new) }
    }
}
