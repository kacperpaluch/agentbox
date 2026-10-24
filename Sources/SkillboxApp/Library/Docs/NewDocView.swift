import SwiftUI
import SkillboxCore

struct NewDocView: View {
    @Environment(\.dismiss) private var dismiss
    let existingTags: [String]
    let existingIDs: Set<String>
    /// Reports whether the document was created, so a rejected identifier does not take the
    /// written content with it.
    let onCreate: (NewDocDraft) async -> Bool
    @State private var saving = false
    @State private var name = ""
    @State private var identifier = ""
    @State private var identifierEdited = false
    @State private var tags = ""
    @State private var content = ""

    private var suggestedID: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-") }
    private var effectiveID: String { (identifierEdited ? identifier : suggestedID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var idValid: Bool { effectiveID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil }
    private var idTaken: Bool { existingIDs.contains(effectiveID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nowy dokument").font(.title2.bold())
            Text("Tekst trafia jako AGENTS.md; CLAUDE.md dostaje import @AGENTS.md, bez osobnej edycji.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Nazwa", text: $name); TextField("Identyfikator", text: Binding(get: { identifierEdited ? identifier : suggestedID }, set: { identifier = $0; identifierEdited = true })) }
            if !effectiveID.isEmpty && !idValid { Label("Identyfikator może zawierać tylko małe litery, cyfry i pojedyncze myślniki.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if idTaken { Label("Dokument o tym identyfikatorze już jest w bibliotece.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            HStack { TextField("tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }
            GroupBox("Treść AGENTS.md") { TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 320) }
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz dokument") { Task { saving = true; defer { saving = false }; if await onCreate(NewDocDraft(id: effectiveID, name: name, content: content, tags: AppModel.csv(tags))) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || !idValid || idTaken || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24)
        .sheetFrame(width: 720, height: 640)
    }
}
