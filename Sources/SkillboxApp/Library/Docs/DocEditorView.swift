import SwiftUI
import SkillboxCore

/// Edits one document's tags and content. Two separate save actions, same as `SkillDetail` — tags
/// commit on their own next to the field, content commits with the main "Zapisz" at the bottom.
struct DocEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let original: AgentDoc
    let existingTags: [String]
    @State private var name: String
    @State private var tags: String
    @State private var content: String
    init(model: AppModel, doc: AgentDoc, existingTags: [String]) {
        self.model = model; original = doc; self.existingTags = existingTags
        _name = State(initialValue: doc.name); _tags = State(initialValue: doc.tags.joined(separator: ", ")); _content = State(initialValue: doc.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original.id).font(.title2.bold())
            Text("Tekst trafia jako AGENTS.md; CLAUDE.md dostaje import @AGENTS.md, bez osobnej edycji.").font(.callout).foregroundStyle(.secondary)
            TextField("Nazwa", text: $name)
            HStack {
                TextField("tagi, oddzielone przecinkami", text: $tags)
                ExistingTagMenu(tags: existingTags, text: $tags)
                Button("Zapisz tagi") { Task { await model.saveDocTags(original.id, text: tags) } }.buttonStyle(.bordered)
            }
            GroupBox("Treść AGENTS.md") { TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 360) }
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { Task { if await model.saveDocContent(original.id, name: name, content: content) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking) }
        }
        .padding(24)
        .sheetFrame(width: 760, height: 700)
    }
}
