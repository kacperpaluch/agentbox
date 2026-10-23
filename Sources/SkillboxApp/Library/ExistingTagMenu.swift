import SwiftUI
import SkillboxCore

struct ExistingTagMenu: View {
    let tags: [String]; @Binding var text: String
    var body: some View { Menu("Używane tagi") { if tags.isEmpty { Text("Brak tagów") } else { ForEach(tags, id: \.self) { tag in Button("#\(tag)") { var values = Set(AppModel.csv(text)); values.insert(tag); text = values.sorted().joined(separator: ", ") } } } }.disabled(tags.isEmpty) }
}
