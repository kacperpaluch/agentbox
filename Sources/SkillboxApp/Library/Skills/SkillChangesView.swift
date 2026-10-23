import SwiftUI
import SkillboxCore

struct SkillChangesView: View {
    let changes: [SkillFileChange]
    var body: some View {
        ForEach(changes) { change in
            DisclosureGroup("\(change.kind) · \(change.path)") {
                VStack(alignment: .leading, spacing: 5) {
                    if !change.note.isEmpty { Text(change.note).font(.caption).foregroundStyle(.secondary) }
                    if change.oldText != nil || change.newText != nil {
                        SkillTextDiff(old: change.oldText ?? "", new: change.newText ?? "")
                    }
                }.padding(.vertical, 6)
            }
        }
    }
}
