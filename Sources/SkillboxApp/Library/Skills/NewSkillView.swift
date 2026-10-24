import SwiftUI
import SkillboxCore

struct NewSkillView: View {
    @Environment(\.dismiss) private var dismiss
    let existingTags: [String]
    let existingIDs: Set<String>
    /// Reports whether the skill was created. The sheet used to close on the click, so a
    /// duplicate identifier threw away the whole draft.
    let onCreate: (NewSkillDraft) async -> Bool
    @State private var saving = false
    @State private var name = ""
    @State private var identifier = ""
    @State private var identifierEdited = false
    @State private var description = ""
    @State private var tags = ""
    @State private var content = ""
    @State private var attachments: [URL] = []

    /// Content pasted with its own YAML block is a finished `SKILL.md`, so the name and description
    /// fields would be a lie — Agentbox saves such a paste untouched and says so.
    private var pastedComplete: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") }
    private var suggestedID: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-") }
    private var effectiveID: String { (identifierEdited ? identifier : suggestedID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var idValid: Bool { effectiveID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil }
    private var idTaken: Bool { existingIDs.contains(effectiveID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nowy skill").font(.title2.bold())
            Text("Treść trafia do biblioteki jako `SKILL.md` i można ją później edytować w Agentbox.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Nazwa", text: $name); TextField("Identyfikator", text: Binding(get: { identifierEdited ? identifier : suggestedID }, set: { identifier = $0; identifierEdited = true })) }
            if !effectiveID.isEmpty && !idValid { Label("Identyfikator może zawierać tylko małe litery, cyfry i pojedyncze myślniki.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if idTaken { Label("Skill o tym identyfikatorze już jest w bibliotece.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            TextField("Opis (trafia do nagłówka SKILL.md)", text: $description).disabled(pastedComplete)
            HStack { TextField("tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }
            GroupBox(pastedComplete ? "Treść — wklejony SKILL.md zostanie zapisany bez zmian" : "Treść") {
                TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 240)
            }
            Text(pastedComplete
                 ? "Wykryto nagłówek YAML, więc Agentbox nie dopisuje własnego."
                 : "Agentbox dopisze nagłówek YAML z nazwą i opisem. Wklej gotowy plik z blokiem `---`, aby zachować własny nagłówek.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dodaj skrypty i pliki…") { for url in chooseSkillFiles() where !attachments.contains(url) { attachments.append(url) } }
                Text(attachments.isEmpty
                     ? "Opcjonalnie. Folder trafia do skilla pod swoją nazwą (np. `scripts/`), plik — obok `SKILL.md`."
                     : attachments.map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if !attachments.isEmpty { Button("Wyczyść") { attachments = [] } }
            }
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz skill") { Task { saving = true; defer { saving = false }; if await onCreate(NewSkillDraft(id: effectiveID, name: name, description: description, content: content, tags: AppModel.csv(tags), attachments: attachments)) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(saving || !idValid || idTaken || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24)
        .sheetFrame(width: 720, height: 640)
    }
}
