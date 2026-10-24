import SwiftUI
import SkillboxCore

/// Titled grid of skill checkboxes — the same visual language everywhere skills are selected:
/// projects, folders, batch add and the Mac. A skill a selected tag pulls in carries that tag as a
/// badge; unticking it leaves it out of this place (see `SkillPick`).
struct SkillCheckGrid: View {
    let title: String
    let skills: [Skill]
    @Binding var selection: AttachmentSelection
    var body: some View {
        GroupBox(title) {
            if skills.isEmpty { Text("Biblioteka jest pusta.").foregroundStyle(.secondary).padding(6) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                    ForEach(skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { skill in
                        let tag = SkillPick.coveringTag(skill, in: selection)
                        Toggle(isOn: Binding(get: { SkillPick.isIncluded(skill, in: selection) }, set: { selection = SkillPick.setting(skill, included: $0, in: selection) })) {
                            HStack(spacing: Space.tight) {
                                Text(skill.name)
                                if let tag { Text("#\(tag)").rowMetadata() }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(tag.map { "Wchodzi przez tag #\($0). Odznacz, by pominąć go tutaj." } ?? "")
                    }
                }.padding(6)
            }
        }
    }
}
