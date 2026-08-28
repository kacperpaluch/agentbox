import SwiftUI
import AppKit
import Combine
import SkillboxCore

enum SkillSort: String, CaseIterable, Identifiable { case name = "Nazwa", newest = "Najnowsze", source = "Źródło"; var id: String { rawValue } }
enum SkillGrouping: String, CaseIterable, Identifiable { case repository = "Repozytorium", tag = "Tag", source = "Źródło", none = "Bez grupowania"; var id: String { rawValue } }

/// The skills half of the library. Search and the tag filter come from `LibraryView`, which owns them
/// for all three kinds; grouping and sorting stay here, because only skills have a repository to be
/// grouped by.
struct SkillsPane: View {
    @ObservedObject var model: AppModel; @Binding var showGit: Bool
    let search: String
    let selectedTag: String
    @State private var showNewSkill = false
    @State private var sort: SkillSort = .name
    @State private var grouping: SkillGrouping = .repository
    @State private var checked = Set<String>()
    @State private var expanded = Set<String>()
    @State private var showBatchTags = false
    var tags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    var filtered: [Skill] {
        var result = model.skills.filter { libraryMatches(name: $0.name, id: $0.id, tags: $0.tags, search: search, selectedTag: selectedTag) }
        switch sort { case .name: result.sort { $0.name < $1.name }; case .newest: result.sort { $0.updatedAt > $1.updatedAt }; case .source: result.sort { $0.source.kind.rawValue < $1.source.kind.rawValue } }
        return result
    }
    var groups: [(name: String, skills: [Skill])] {
        switch grouping {
        case .none: return [("Wszystkie skille", filtered)]
        case .source:
            return Dictionary(grouping: filtered) { $0.source.kind == .git ? "Git" : "Lokalne" }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        case .repository:
            return Dictionary(grouping: filtered) { skill in
                guard skill.source.kind == .git else { return "Lokalne" }
                let trimmed = skill.source.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let component = trimmed.split(separator: "/").last.map(String.init) ?? skill.source.location
                return component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            }.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        case .tag:
            var values: [String: [Skill]] = [:]
            for skill in filtered { if skill.tags.isEmpty { values["Bez tagów", default: []].append(skill) } else { for tag in skill.tags { values["#\(tag)", default: []].append(skill) } } }
            return values.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                actionBar
                skillList
            }
            .frame(minWidth: 410, idealWidth: 480)
            if let id = model.selection, let skill = model.skills.first(where: { $0.id == id }) {
                SkillDetail(model: model, skill: skill)
            } else {
                ContentUnavailableView("Wybierz skill", systemImage: "text.book.closed")
            }
        }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: tags) { text in Task { await model.addTags(checked, text: text); checked.removeAll() } } }
        .sheet(isPresented: $showNewSkill) { NewSkillView(existingTags: tags, existingIDs: Set(model.skills.map(\.id))) { draft in Task { await model.createSkill(draft) } } }
    }

    // One row instead of two stacked toolbars: the add actions swap for a selection bar the moment
    // something is checked (the Mail/Finder pattern), and filtering lives in the same row as the
    // running total instead of a separate bar with its own background underneath it.
    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { showGit = true } label: { Label("Z Git", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent)
                Button { chooseSkill() } label: { Label("Z dysku", systemImage: "folder.badge.plus") }.buttonStyle(.bordered)
                Button { showNewSkill = true } label: { Label("Napisz własny", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            filterMenu
            Button { Task { await model.checkUpdates() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sprawdź aktualizacje")
            Text("\(filtered.count) z \(model.skills.count)").rowMetadata()
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Grupowanie", selection: $grouping) { ForEach(SkillGrouping.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Sortowanie", selection: $sort) { ForEach(SkillSort.allCases) { Text($0.rawValue).tag($0) } }
            Divider()
            Button("Rozwiń wszystko") { expanded = Set(groups.map(\.name)) }
            Button("Zwiń wszystko") { expanded.removeAll() }
        } label: { Label("Grupuj i sortuj", systemImage: "line.3.horizontal.decrease.circle") }
    }

    private var skillList: some View {
        List {
            ForEach(groups, id: \.name) { group in
                DisclosureGroup(isExpanded: groupExpansion(group.name)) {
                    ForEach(group.skills) { skill in
                        HStack(alignment: .top, spacing: Space.row + 1) {
                            Toggle("", isOn: checkBinding(skill.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
                            SkillRow(skill: skill, updateAvailable: model.updateAvailable.contains(skill.id))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selection = skill.id; Task { await model.loadMarkdown() } }
                        .listRowBackground(model.selection == skill.id ? Color.accentColor.opacity(0.13) : Color.clear)
                    }
                } label: {
                    HStack(spacing: Space.tight + 2) {
                        Toggle("", isOn: groupCheckBinding(group.skills)).labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: grouping == .repository ? "shippingbox" : grouping == .tag ? "tag" : grouping == .source ? "tray.full" : "square.grid.2x2").foregroundStyle(.tint)
                        Text(group.name).sectionLabel()
                        Text("\(group.skills.count)").rowMetadata()
                        Spacer()
                        let updates = group.skills.filter { model.updateAvailable.contains($0.id) }.count
                        if updates > 0 { MetaBadge(text: "\(updates) aktualizacji", tint: .orange) }
                    }
                }
            }
        }
    }

    private func checkBinding(_ id: String) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }
    private func groupCheckBinding(_ skills: [Skill]) -> Binding<Bool> { let ids = Set(skills.map(\.id)); return Binding(get: { !ids.isEmpty && ids.isSubset(of: checked) }, set: { if $0 { checked.formUnion(ids) } else { checked.subtract(ids) } }) }
    private func groupExpansion(_ name: String) -> Binding<Bool> { Binding(get: { !search.isEmpty || expanded.contains(name) || grouping == .none }, set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } }) }
    private func chooseSkill() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { Task { await model.addLocal(url) } } }
}

struct SkillRow: View {
    let skill: Skill
    let updateAvailable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight + 1) {
            HStack {
                Image(systemName: skill.source.kind == .git ? "network" : "internaldrive").foregroundStyle(.tint)
                Text(skill.name).rowTitle()
                Spacer()
                if updateAvailable { MetaBadge(text: "Aktualizacja", tint: .orange) }
            }
            if skill.tags.isEmpty { Text("bez tagów").font(.caption).foregroundStyle(.tertiary) } else { FlowTags(tags: skill.tags) }
        }
        .padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SkillDetail: View {
    @ObservedObject var model: AppModel; let skill: Skill; @State private var tags = ""; @State private var confirmDelete = false
    @State private var isEditing = false
    @State private var draft = ""
    private var isEditable: Bool { skill.source.kind == .local }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editorBar
            Divider()
            content
        }
        .onAppear { tags = skill.tags.joined(separator: ", ") }
        .onChange(of: skill.id) { tags = skill.tags.joined(separator: ", "); isEditing = false; draft = "" }
        .confirmationDialog("Usunąć skill \(skill.name)?", isPresented: $confirmDelete) {
            Button("Usuń skill", role: .destructive) { Task { await model.deleteSkill(skill.id) } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Skill zostanie usunięty z biblioteki i przypisań projektów. Zniknie z folderów projektów przy kolejnej synchronizacji.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.section - 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.title2.bold())
                    Text(skill.source.location).rowMetadata().lineLimit(1)
                }
                Spacer()
                if model.updateAvailable.contains(skill.id) {
                    Button("Aktualizuj") { Task { await model.update(skill.id) } }.buttonStyle(.borderedProminent).tint(.orange)
                } else if model.hasCheckedUpdates && skill.source.kind == .git {
                    Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Button("Usuń", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
            }
            HStack {
                TextField("tagi, oddzielone przecinkami", text: $tags).textFieldStyle(.roundedBorder)
                ExistingTagMenu(tags: Array(Set(model.skills.flatMap(\.tags))).sorted(), text: $tags)
                Button("Zapisz tagi") { Task { await model.saveTags(skill.id, text: tags) } }.buttonStyle(.bordered)
            }
        }
        .padding(Space.page)
    }

    @ViewBuilder private var editorBar: some View {
        HStack(spacing: Space.row) {
            if isEditing {
                Button("Zapisz zmiany") { Task { if await model.saveSkillMarkdown(skill.id, content: draft) { isEditing = false } } }
                    .buttonStyle(.borderedProminent).disabled(model.isWorking)
                Button("Anuluj") { isEditing = false; draft = model.markdown }.buttonStyle(.bordered)
                Spacer()
                Text("Zapis oznacza projekty z tym skillem jako nieaktualne.").rowMetadata()
            } else if isEditable {
                Button { draft = model.markdown; isEditing = true } label: { Label("Edytuj SKILL.md", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                Spacer()
            } else {
                Label("Skill z Git — edycja w aplikacji jest wyłączona, bo aktualizacja zastąpiłaby zmiany.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, Space.section).padding(.vertical, Space.row)
    }

    @ViewBuilder private var content: some View {
        if isEditing {
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).padding(6)
        } else {
            ScrollView { Text(model.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
        }
    }
}
