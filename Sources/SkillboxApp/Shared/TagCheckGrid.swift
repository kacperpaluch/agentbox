import SwiftUI
import SkillboxCore

/// Titled grid of `#tag` checkboxes — shared by every "select by tag" section in the app.
struct TagCheckGrid: View {
    let title: String
    let tags: [String]
    @Binding var selection: Set<String>
    var body: some View {
        GroupBox(title) {
            if tags.isEmpty { Text("Brak tagów.").foregroundStyle(.secondary).padding(6) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                    ForEach(tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { tag in Toggle("#\(tag)", isOn: setBinding(tag, in: $selection)).toggleStyle(.checkbox) }
                }.padding(6)
            }
        }
    }
}
