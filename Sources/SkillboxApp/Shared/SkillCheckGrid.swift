import SwiftUI
import SkillboxCore

/// Titled grid of "pick a skill" checkboxes — the same visual language everywhere skills are
/// selected: Projects, folders, batch add, and Global. A skill whose id is in `locked` shows fixed
/// as checked, because something else (a tag) already pulls it in, with `lockedHelp` as its tooltip.
struct SkillCheckGrid: View {
    let title: String
    let skills: [Skill]
    @Binding var selection: Set<String>
    var locked: Set<String> = []
    var lockedHelp: String = ""
    var body: some View {
        GroupBox(title) {
            if skills.isEmpty { Text("Biblioteka jest pusta.").foregroundStyle(.secondary).padding(6) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading) {
                    ForEach(skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { skill in
                        let isLocked = locked.contains(skill.id)
                        Toggle(skill.name, isOn: isLocked ? .constant(true) : setBinding(skill.id, in: $selection))
                            .toggleStyle(.checkbox).disabled(isLocked).help(isLocked ? lockedHelp : "")
                    }
                }.padding(6)
            }
        }
    }
}
