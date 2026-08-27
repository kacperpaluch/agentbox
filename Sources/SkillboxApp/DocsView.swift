import SwiftUI
import AppKit
import Combine
import SkillboxCore

/// The library of shared `AGENTS.md` texts. Each one, once assigned to a project, also produces that
/// project's `CLAUDE.md` automatically as a generated `@AGENTS.md` import — there is nothing to write
/// or edit for `CLAUDE.md` separately.
struct DocsView: View {
    @ObservedObject var model: AppModel
    @State private var editingDoc: AgentDoc?
    @State private var creatingDoc = false
    @State private var docToDelete: AgentDoc?
    @State private var checked = Set<String>()
    @State private var showBatchTags = false
    private var existingTags: [String] { Array(Set(model.docs.docs.flatMap(\.tags))).sorted() }
    private var sortedDocs: [AgentDoc] { model.docs.docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if model.docs.docs.isEmpty {
                ContentUnavailableView("Brak dokumentów", systemImage: "doc.text", description: Text("Dodaj tekst, który ma trafić jako AGENTS.md do wybranych projektów. CLAUDE.md w tych projektach powstanie automatycznie."))
            } else {
                List {
                    Section("Dokumenty") {
                        ForEach(sortedDocs) { doc in
                            HStack(alignment: .top, spacing: Space.row + 1) {
                                Toggle("", isOn: checkBinding(doc.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
                                DocRow(doc: doc, onEdit: { editingDoc = doc }, onDelete: { docToDelete = doc })
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingDoc = doc }
                        }
                    }
                }
            }
        }
        .navigationTitle("Dokumenty")
        .sheet(isPresented: $creatingDoc) { NewDocView(existingTags: existingTags, existingIDs: Set(model.docs.docs.map(\.id))) { draft in Task { _ = await model.createDoc(id: draft.id, name: draft.name, tags: draft.tags, content: draft.content) } } }
        .sheet(item: $editingDoc) { doc in DocEditorView(model: model, doc: doc, existingTags: existingTags) }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: existingTags, noun: "dokumentów") { text in Task { await model.addDocTags(checked, text: text); checked.removeAll() } } }
        .confirmationDialog("Usunąć dokument \(docToDelete?.name ?? "")?", isPresented: Binding(get: { docToDelete != nil }, set: { if !$0 { docToDelete = nil } })) {
            Button("Usuń", role: .destructive) { if let docToDelete { Task { await model.deleteDoc(docToDelete.id) } }; docToDelete = nil }
            Button("Anuluj", role: .cancel) { docToDelete = nil }
        } message: { Text("Dokument zniknie z biblioteki i z przypisań projektów. AGENTS.md i wygenerowany CLAUDE.md znikną z projektów, które go używały, przy kolejnej synchronizacji.") }
    }

    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { creatingDoc = true } label: { Label("Nowy dokument", systemImage: "plus") }.buttonStyle(.borderedProminent)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            Text("\(model.docs.docs.count) dokumentów").rowMetadata()
        }
    }

    private func checkBinding(_ id: String) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
}

private struct DocRow: View {
    let doc: AgentDoc
    let onEdit: () -> Void
    let onDelete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: "doc.text").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.row) {
                    Text(doc.name).rowTitle()
                    ForEach(doc.tags, id: \.self) { TagPill(tag: $0) }
                }
                Text("AGENTS.md + CLAUDE.md (@AGENTS.md) · \(doc.content.count) znaków").rowMetadata()
            }
            Spacer()
            Button("Edytuj", action: onEdit).controlSize(.small)
            RowMenu {
                Button("Edytuj…", action: onEdit)
                Divider()
                Button("Usuń…", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, Space.tight)
    }
}

/// A document written straight into Agentbox, with no folder or repository behind it — the document
/// counterpart of `NewSkillDraft`.
struct NewDocDraft {
    var id = ""
    var name = ""
    var content = ""
    var tags: [String] = []
}
struct NewDocView: View {
    @Environment(\.dismiss) private var dismiss
    let existingTags: [String]
    let existingIDs: Set<String>
    let onCreate: (NewDocDraft) -> Void
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
            Text("Treść trafia jako AGENTS.md do projektów, które dostaną ten dokument. CLAUDE.md w tych projektach Agentbox generuje sam jako import @AGENTS.md — nie trzeba pisać go osobno.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Nazwa", text: $name); TextField("Identyfikator", text: Binding(get: { identifierEdited ? identifier : suggestedID }, set: { identifier = $0; identifierEdited = true })) }
            if !effectiveID.isEmpty && !idValid { Label("Identyfikator może zawierać tylko małe litery, cyfry i pojedyncze myślniki.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if idTaken { Label("Dokument o tym identyfikatorze już jest w bibliotece.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            HStack { TextField("tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }
            GroupBox("Treść AGENTS.md") { TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 320) }
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Utwórz dokument") { onCreate(NewDocDraft(id: effectiveID, name: name, content: content, tags: AppModel.csv(tags))); dismiss() }.buttonStyle(.borderedProminent).disabled(!idValid || idTaken || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24)
        .frame(width: 720, height: 640)
    }
}

/// Edits one document's tags and content. Two separate save actions, same as `SkillDetail` — tags
/// commit on their own next to the field, content commits with the main "Zapisz" at the bottom.
struct DocEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
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
            Text("Ten sam tekst trafia jako AGENTS.md w każdym projekcie, do którego jest przypisany. CLAUDE.md tych projektów to wygenerowany import @AGENTS.md — synchronizuje się razem z AGENTS.md, bez osobnej edycji.").font(.callout).foregroundStyle(.secondary)
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
        .frame(width: 760, height: 700)
    }
}
