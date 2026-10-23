import SwiftUI
import SkillboxCore

struct BatchTagView: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int; let existingTags: [String]
    var noun = PolishNoun.skill
    /// See `NewSkillView.onCreate` — the sheet closes only once the tags are actually saved.
    let onSave: (String) async -> Bool
    @State private var saving = false
    @State private var tags = ""
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Dodaj tagi").font(.title2.bold()); Text("Wybrano \(noun(count)). Nowe tagi zostaną dopisane do już istniejących.").foregroundStyle(.secondary); HStack { TextField("np. seo, marketing, audit", text: $tags).textFieldStyle(.roundedBorder); ExistingTagMenu(tags: existingTags, text: $tags) }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj") { Task { saving = true; defer { saving = false }; if await onSave(tags) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || AppModel.csv(tags).isEmpty) } }.padding(24).frame(width: 520) }
}
