import SwiftUI
import SkillboxCore

/// The library of shared `AGENTS.md` texts. Each one, once assigned to a project, also produces that
/// project's `CLAUDE.md` automatically as a generated `@AGENTS.md` import — there is nothing to write
/// or edit for `CLAUDE.md` separately.
struct DocsPane: View {
    let model: AppModel
    let search: String
    let selectedTag: String
    @State private var editingDoc: AgentDoc?
    @State private var creatingDoc = false
    @State private var docToDelete: AgentDoc?
    /// Read while the dialog is open, so the question says how far the deletion reaches.
    @State private var usageForDeletion: UsageReport?
    @State private var checked = Set<String>()
    /// The highlighted row; Return or a double click opens it.
    @State private var selected: String?
    @State private var showBatchTags = false
    private var existingTags: [String] { Array(Set(model.docs.docs.flatMap(\.tags))).sorted() }
    private var sortedDocs: [AgentDoc] {
        model.docs.docs
            .filter { libraryMatches(name: $0.name, id: $0.id, tags: $0.tags, search: search, selectedTag: selectedTag) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if model.docs.docs.isEmpty {
                ContentUnavailableView("Brak dokumentów", systemImage: "doc.text", description: Text("Dodaj tekst, który ma trafić jako AGENTS.md do wybranych projektów. CLAUDE.md w tych projektach powstanie automatycznie."))
            } else if sortedDocs.isEmpty {
                ContentUnavailableView("Nic nie pasuje", systemImage: "magnifyingglass", description: Text("Zmień wyszukiwanie albo wybrany tag."))
            } else {
                List(selection: $selected) {
                    ForEach(sortedDocs) { doc in
                        HStack(alignment: .top, spacing: Space.row + 1) {
                            Toggle("Zaznacz \(doc.name)", isOn: checkBinding(doc.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
                            DocRow(doc: doc, usageKey: AnyHashable([AnyHashable(doc.id), AnyHashable(doc.tags), AnyHashable(model.selections)]), usage: { await model.usage(ofDoc: doc.id) }, onEdit: { editingDoc = doc }, onDelete: { docToDelete = doc })
                        }
                        .tag(doc.id)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let doc = doc(in: ids) {
                        Button("Edytuj…") { editingDoc = doc }
                        Divider()
                        Button("Usuń…", role: .destructive) { docToDelete = doc }
                    }
                } primaryAction: { ids in editingDoc = doc(in: ids) }
            }
        }
        .sheet(isPresented: $creatingDoc) { NewDocView(existingTags: existingTags, existingIDs: Set(model.docs.docs.map(\.id))) { draft in await model.createDoc(id: draft.id, name: draft.name, tags: draft.tags, content: draft.content) } }
        .sheet(item: $editingDoc) { doc in DocEditorView(model: model, doc: doc, existingTags: existingTags) }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: existingTags, noun: .document) { text in let ok = await model.addDocTags(checked, text: text); if ok { checked.removeAll() }; return ok } }
        .confirmationDialog("Usunąć dokument \(docToDelete?.name ?? "")?", item: $docToDelete) { docToDelete in
            Button("Usuń", role: .destructive) { Task { await model.deleteDoc(docToDelete.id) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("\((usageForDeletion?.summary).map { "Używany przez: \($0). " } ?? "")Dokument zniknie z biblioteki i z przypisań projektów. AGENTS.md i wygenerowany CLAUDE.md (albo dopisany do własnego CLAUDE.md import) znikną z projektów, które go używały, przy kolejnej synchronizacji.") }
        .task(id: docToDelete?.id) { usageForDeletion = docToDelete == nil ? nil : await model.usage(ofDoc: docToDelete!.id) }
    }

    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { creatingDoc = true } label: { Label("Dodaj dokument", systemImage: "plus") }.buttonStyle(.borderedProminent)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            Text(sortedDocs.count == model.docs.docs.count ? PolishNoun.document(model.docs.docs.count) : "\(sortedDocs.count) z \(model.docs.docs.count)").rowMetadata()
        }
    }

    private func doc(in ids: Set<String>) -> AgentDoc? { ids.count == 1 ? model.docs.docs.first { ids.contains($0.id) } : nil }
    private func checkBinding(_ id: String) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
}
