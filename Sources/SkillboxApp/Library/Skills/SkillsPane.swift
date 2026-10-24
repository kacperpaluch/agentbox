import SwiftUI
import SkillboxCore

/// The skills half of the library. Search and the tag filter come from `LibraryView`, which owns them
/// for all three kinds; grouping and sorting stay here, because only skills have a repository to be
/// grouped by.
struct SkillsPane: View {
    @Bindable var model: AppModel; @Binding var showGit: Bool
    let search: String
    let selectedTag: String
    @State private var showNewSkill = false
    @State private var sort: SkillSort = .name
    @State private var grouping: SkillGrouping = .repository
    /// The list's own selection: click, ⌘ and ⇧ work as everywhere on the Mac. One skill opens in the
    /// detail; several turn the detail and the bar into bulk actions. `model.selection` keeps the one
    /// skill whose text is loaded.
    @State private var selected = Set<String>()
    private var checked: Set<String> { selected.intersection(model.skills.map(\.id)) }
    /// Group names, one per line. Groups start open — a list of closed groups looked empty — and stay
    /// the way they were left between launches.
    @AppStorage("AgentboxCollapsedSkillGroups") private var collapsedStorage = ""
    private var collapsed: Set<String> {
        get { Set(collapsedStorage.split(separator: "\n").map(String.init)) }
        nonmutating set { collapsedStorage = newValue.sorted().joined(separator: "\n") }
    }
    @State private var showBatchTags = false
    @State private var confirmBatchDelete = false
    var tags: [String] { Array(Set(model.skills.flatMap(\.tags))).sorted() }
    var filtered: [Skill] {
        var result = model.skills.filter { libraryMatches(name: $0.name, id: $0.id, tags: $0.tags, search: search, selectedTag: selectedTag) }
        switch sort { case .name: result.sort { $0.name < $1.name }; case .newest: result.sort { $0.updatedAt > $1.updatedAt }; case .source: result.sort { $0.source.kind.rawValue < $1.source.kind.rawValue } }
        return result
    }
    var groups: [SkillGroup] {
        switch grouping {
        case .none: return [SkillGroup(name: "Wszystkie skille", skills: filtered)]
        case .source:
            return Dictionary(grouping: filtered) { $0.source.kind == .git ? "Git" : "Lokalne" }.map { SkillGroup(name: $0.key, skills: $0.value) }.sorted { $0.name < $1.name }
        case .repository:
            return Dictionary(grouping: filtered) { skill in
                guard skill.source.kind == .git else { return "Lokalne" }
                let trimmed = skill.source.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let component = trimmed.split(separator: "/").last.map(String.init) ?? skill.source.location
                return component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            }.map { SkillGroup(name: $0.key, skills: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tag:
            var values: [String: [Skill]] = [:]
            for skill in filtered { if skill.tags.isEmpty { values["Bez tagów", default: []].append(skill) } else { for tag in skill.tags { values["#\(tag)", default: []].append(skill) } } }
            return values.map { SkillGroup(name: $0.key, skills: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                actionBar
                if !model.unregisteredSkills.isEmpty { unregisteredBanner }
                skillList
            }
            // Both panes fill the height: without it an empty detail let the list shrink to its own
            // height and float in the middle, pushing the detail off the right edge.
            .frame(minWidth: 410, idealWidth: 480, maxHeight: .infinity)
            if checked.count > 1 {
                bulkDetail
            } else if let id = model.selection, let skill = model.skills.first(where: { $0.id == id }) {
                SkillDetail(model: model, skill: skill)
            } else {
                ContentUnavailableView("Wybierz skill", systemImage: "text.book.closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if let id = model.selection { selected = [id] } }
        .onChange(of: selected) {
            // A header row is not a skill; picking one keeps the skill that was open.
            if checked.count == 1, let id = checked.first, id != model.selection { model.selection = id }
        }
        .onChange(of: model.selection) { previous, current in
            if let current, checked.count < 2, !selected.contains(current) { selected = [current] }
            // A click on a group header selects no skill (nil, or the header's row id). Keep the skill
            // that was open instead of emptying the detail; a deleted skill is not restored.
            let isSkill: (String?) -> Bool = { id in model.skills.contains { $0.id == id } }
            if !isSkill(current), isSkill(previous) { model.selection = previous; return }
            Task { await model.loadMarkdown() }
        }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: tags) { text in await model.addTags(checked, text: text) } }
        .sheet(isPresented: $showNewSkill) { NewSkillView(existingTags: tags, existingIDs: Set(model.skills.map(\.id))) { draft in await model.createSkill(draft) } }
        .confirmationDialog("Usunąć \(PolishNoun.skill(checked.count))?", isPresented: $confirmBatchDelete) {
            Button("Usuń \(PolishNoun.skill(checked.count))", role: .destructive) {
                let ids = checked
                selected.removeAll()
                Task { await model.deleteSkills(ids) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Skille zostaną usunięte z biblioteki i przypisań projektów. Znikną z folderów projektów przy kolejnej synchronizacji.")
        }
    }

    /// A skill saved straight into the library folder — by an assistant, an editor, Finder — is not
    /// in the catalog until someone adds it. Offered here instead of registered on the spot, because
    /// the folder may still be in the middle of being written.
    private var unregisteredBanner: some View {
        let ready = model.unregisteredSkills.filter { $0.problem == nil }
        let blocked = model.unregisteredSkills.filter { $0.problem != nil }
        return HStack(alignment: .top, spacing: Space.section - 2) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.unregisteredSkills.count == 1 ? "Nowy skill w folderze biblioteki" : "Nowe skille w folderze biblioteki: \(model.unregisteredSkills.count)").font(.callout.weight(.medium))
                if !ready.isEmpty { Text(ready.map(\.id).joined(separator: ", ")).rowMetadata().lineLimit(2) }
                ForEach(blocked) { item in
                    Label("\(item.id): \(item.problem ?? "")", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer()
            if !ready.isEmpty {
                Button(ready.count == 1 ? "Dodaj do biblioteki" : "Dodaj \(ready.count) do biblioteki") { Task { await model.registerUnregisteredSkills() } }
                    .buttonStyle(.borderedProminent).disabled(model.isWorking)
            }
        }
        .padding(.horizontal, Space.page).padding(.vertical, Space.row + 2)
        .background(.quaternary.opacity(0.4))
    }

    /// Several skills selected: what can be done to all of them at once.
    private var bulkDetail: some View {
        ContentUnavailableView {
            Label("Wybrano \(PolishNoun.skill(checked.count))", systemImage: "square.stack.3d.up")
        } description: {
            Text(model.skills.filter { checked.contains($0.id) }.map(\.name).sorted().prefix(12).joined(separator: ", "))
        } actions: {
            Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
            Button(role: .destructive) { confirmBatchDelete = true } label: { Label("Usuń…", systemImage: "trash") }.disabled(model.isWorking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // One row instead of two stacked toolbars: the add actions swap for a selection bar the moment
    // several skills are selected (the Mail/Finder pattern), and filtering lives in the same row as
    // the running total instead of a separate bar with its own background underneath it.
    private var actionBar: some View {
        ActionBar {
            if checked.count < 2 {
                Menu {
                    Button { showGit = true } label: { Label("Z repozytorium Git…", systemImage: "arrow.down.circle") }
                    Button { chooseSkill() } label: { Label("Z folderu na dysku…", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { showNewSkill = true } label: { Label("Napisz własny…", systemImage: "square.and.pencil") }
                } label: {
                    Label("Dodaj skill", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
                .menuIndicator(.visible)
                .tint(.accentColor)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button(role: .destructive) { confirmBatchDelete = true } label: { Label("Usuń", systemImage: "trash") }.buttonStyle(.bordered)
                    .disabled(model.isWorking)
                Button("Odznacz") { selected = model.selection.map { [$0] } ?? [] }.buttonStyle(.bordered)
            }
            Spacer()
            filterMenu
            Button { Task { await model.checkUpdates() } } label: {
                Label("Sprawdź aktualizacje", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            if !model.updateAvailable.isEmpty {
                Button { Task { await model.updateAllAvailable() } } label: {
                    Label("Aktualizuj \(model.updateAvailable.count)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(model.isWorking)
                .help("Pobierz wszystkie wykryte aktualizacje skilli")
            }
            Text("\(filtered.count) z \(model.skills.count)").rowMetadata()
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Grupowanie", selection: $grouping) { ForEach(SkillGrouping.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Sortowanie", selection: $sort) { ForEach(SkillSort.allCases) { Text($0.rawValue).tag($0) } }
            Divider()
            Button("Rozwiń wszystko") { collapsed = [] }
            Button("Zwiń wszystko") { collapsed = Set(groups.map(\.name)) }
        } label: { Label("Grupuj i sortuj", systemImage: "line.3.horizontal.decrease.circle") }
    }

    private var skillList: some View {
        // Native selection: arrow keys and VoiceOver move through skills, which a tap gesture never allowed.
        List(selection: $selected) {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: groupExpansion(group.name)) {
                    ForEach(group.items) { item in
                        SkillRow(skill: item.skill, updateAvailable: model.updateAvailable.contains(item.skill.id))
                            .tag(item.skill.id)
                    }
                } label: {
                    HStack(spacing: Space.tight + 2) {
                        Toggle("Zaznacz grupę \(group.name)", isOn: groupCheckBinding(group.skills)).labelsHidden().toggleStyle(.checkbox)
                            .help("Zaznacz całą grupę")
                        Image(systemName: grouping == .repository ? "shippingbox" : grouping == .tag ? "tag" : grouping == .source ? "tray.full" : "square.grid.2x2").foregroundStyle(.tint)
                        Text(group.name).sectionLabel()
                        Text("\(group.skills.count)").rowMetadata()
                        Spacer()
                        let updates = group.skills.count { model.updateAvailable.contains($0.id) }
                        if updates > 0 { MetaBadge(text: "\(updates) aktualizacji", tint: .orange) }
                    }
                    .selectionDisabled()
                }
            }
        }
        .onDeleteCommand { if !checked.isEmpty { confirmBatchDelete = true } }
    }

    private func groupCheckBinding(_ skills: [Skill]) -> Binding<Bool> { let ids = Set(skills.map(\.id)); return Binding(get: { !ids.isEmpty && ids.isSubset(of: checked) }, set: { if $0 { selected = checked.union(ids) } else { selected = checked.subtracting(ids) } }) }
    private func groupExpansion(_ name: String) -> Binding<Bool> { Binding(get: { !search.isEmpty || !collapsed.contains(name) || grouping == .none }, set: { if $0 { collapsed.remove(name) } else { collapsed.insert(name) } }) }
    private func chooseSkill() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { Task { await model.addLocal(url) } } }
}
