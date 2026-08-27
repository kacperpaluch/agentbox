import SwiftUI
import AppKit
import Combine
import SkillboxCore

struct BatchTagView: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int; let existingTags: [String]
    var noun = "skilli"
    let onSave: (String) -> Void
    @State private var tags = ""
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Dodaj tagi").font(.title2.bold()); Text("Wybrano \(count) \(noun). Nowe tagi zostaną dopisane do już istniejących.").foregroundStyle(.secondary); HStack { TextField("np. seo, marketing, audit", text: $tags).textFieldStyle(.roundedBorder); ExistingTagMenu(tags: existingTags, text: $tags) }; HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Dodaj") { onSave(tags); dismiss() }.buttonStyle(.borderedProminent).disabled(AppModel.csv(tags).isEmpty) } }.padding(24).frame(width: 520) }
}
struct ExistingTagMenu: View {
    let tags: [String]; @Binding var text: String
    var body: some View { Menu("Używane tagi") { if tags.isEmpty { Text("Brak tagów") } else { ForEach(tags, id: \.self) { tag in Button("#\(tag)") { var values = Set(AppModel.csv(text)); values.insert(tag); text = values.sorted().joined(separator: ", ") } } } }.disabled(tags.isEmpty) }
}
struct AddGitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var subpath = ""
    let onAdd: (String, String) -> Void
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("Dodaj z Git").font(.title2.bold()); Text("Adres repozytorium lub link GitHub do konkretnego folderu. Możesz wkleić kilka adresów — po jednym w linii.").font(.caption).foregroundStyle(.secondary); TextEditor(text: $url).font(.system(.body, design: .monospaced)).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)); TextField("Podfolder, np. skills (opcjonalnie)", text: $subpath); Text("Dla linku GitHub `/tree/branch/folder` branch i podfolder zostaną rozpoznane automatycznie. Zwykły URL repozytorium importuje wszystkie znalezione katalogi z SKILL.md.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Importuj") { onAdd(url, subpath); dismiss() }.buttonStyle(.borderedProminent).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 580) }
}
/// A skill written or pasted straight into Agentbox, with no folder on disk and no repository.
struct NewSkillDraft {
    var id = ""
    var name = ""
    var description = ""
    var content = ""
    var tags: [String] = []
}
struct NewSkillView: View {
    @Environment(\.dismiss) private var dismiss
    let existingTags: [String]
    let existingIDs: Set<String>
    let onCreate: (NewSkillDraft) -> Void
    @State private var name = ""
    @State private var identifier = ""
    @State private var identifierEdited = false
    @State private var description = ""
    @State private var tags = ""
    @State private var content = ""

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
            Text("Treść trafia prosto do biblioteki jako `SKILL.md`. Taki skill można później edytować w Agentbox — w przeciwieństwie do skilli z Git, które nadpisuje aktualizacja.").font(.callout).foregroundStyle(.secondary)
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
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz skill") { onCreate(NewSkillDraft(id: effectiveID, name: name, description: description, content: content, tags: AppModel.csv(tags))); dismiss() }.buttonStyle(.borderedProminent).disabled(!idValid || idTaken || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24)
        .frame(width: 720, height: 640)
    }
}
