import SwiftUI
import SkillboxCore

struct SkillDetail: View {
    let model: AppModel; let skill: Skill; @State private var newTag = ""; @State private var confirmDelete = false
    var showsUpdates = true
    @State private var usage: UsageReport?
    /// The dialog names what the deletion will actually reach, instead of leaving the user to guess
    /// how far a library item spread.
    private var deleteWarning: String {
        let base = "Skill zostanie usunięty z biblioteki i przypisań projektów. Zniknie z folderów projektów przy kolejnej synchronizacji."
        guard let summary = usage?.summary else { return base }
        return "Używany przez: \(summary). " + base
    }
    @State private var isEditing = false
    @State private var draft = ""
    private var isEditable: Bool { skill.source.kind == .local }
    /// Files picked for this skill whose names it already has; they wait here for a confirmation.
    @State private var replacement: [URL] = []
    private var libraryDirectory: URL { URL(fileURLWithPath: model.rootPath).appending(path: "skills").appending(path: skill.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editorBar
            Divider()
            files
            content
        }
        .confirmationDialog("Zastąpić istniejące pliki skilla?", isPresented: Binding(get: { !replacement.isEmpty }, set: { if !$0 { replacement = [] } })) {
            Button("Zastąp", role: .destructive) { let files = replacement; Task { await model.addSkillFiles(skill.id, files: files, replacing: true) } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text("Skill ma już: \(existing(in: replacement).joined(separator: ", ")). Obecna zawartość zostanie zastąpiona wybraną.") }
        .onChange(of: skill.id) { newTag = ""; isEditing = false; draft = "" }
        .confirmationDialog("Usunąć skill \(skill.name)?", isPresented: $confirmDelete) {
            Button("Usuń skill", role: .destructive) { Task { await model.deleteSkill(skill.id) } }
            Button("Anuluj", role: .cancel) {}
        } message: { Text(deleteWarning) }
        .task(id: skill.id) { usage = await model.usage(ofSkill: skill.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.section - 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.title2.bold())
                    Text(skill.source.location).rowMetadata().lineLimit(1)
                }
                Spacer()
                if showsUpdates && model.updateAvailable.contains(skill.id) {
                    Button("Aktualizuj") { Task { await model.update(skill.id) } }.buttonStyle(.borderedProminent).tint(.orange)
                } else if model.hasCheckedUpdates && skill.source.kind == .git {
                    Label("Aktualny", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Button("Usuń", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
            }
            if let summary = usage?.summary {
                Label("Używany przez: \(summary)", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
                    .help((usage?.projects ?? []).joined(separator: ", "))
            } else if usage != nil {
                Label("Nieprzypisany do żadnego projektu", systemImage: "circle.dashed").font(.caption).foregroundStyle(.secondary)
            }
            tagEditor
        }
        .padding(Space.page)
    }

    /// Tags as pills that save on their own: × removes one, typing a name and Return adds it, the menu
    /// offers the ones other skills use. No separate "save" step to forget.
    private var tagEditor: some View {
        let unused = Set(model.skills.flatMap(\.tags)).subtracting(skill.tags).sorted()
        return HStack(spacing: Space.tight + 2) {
            ForEach(skill.tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text("#\(tag)")
                    Button("Usuń tag \(tag)", systemImage: "xmark") { saveTags(skill.tags.filter { $0 != tag }) }
                        .labelStyle(.iconOnly).imageScale(.small)
                        .buttonStyle(.plain).help("Usuń tag \(tag)").disabled(model.isWorking)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, Space.row - 1).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
            TextField("Dodaj tag", text: $newTag)
                .textFieldStyle(.roundedBorder).frame(width: 130)
                .onSubmit { saveTags(skill.tags + AppModel.csv(newTag)); newTag = "" }
            if !unused.isEmpty {
                Menu("Dodaj używany tag", systemImage: "plus") { ForEach(unused, id: \.self) { tag in Button("#\(tag)") { saveTags(skill.tags + [tag]) } } }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton).fixedSize().help("Dodaj tag używany przez inne skille")
            }
            Spacer()
        }
    }
    private func saveTags(_ tags: [String]) {
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0.lowercased()).inserted }
        Task { await model.saveTags(skill.id, text: unique.joined(separator: ", ")) }
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
                    .disabled(model.markdownSkillID != skill.id)
                Button { addFiles() } label: { Label("Dodaj pliki…", systemImage: "doc.badge.plus") }.buttonStyle(.bordered)
                    .disabled(model.markdownSkillID != skill.id || model.isWorking)
                    .help("Skrypty i zasoby kopiowane do skilla. Folder trafia pod swoją nazwą, plik — obok SKILL.md.")
                Spacer()
            } else {
                Label("Skill z Git — edycja w aplikacji jest wyłączona, bo aktualizacja zastąpiłaby zmiany.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, Space.section).padding(.vertical, Space.row)
    }

    /// Top-level names among `urls` that the skill already holds.
    private func existing(in urls: [URL]) -> [String] {
        let present = Set(model.skillFiles.map { String($0.path.prefix { $0 != "/" }).lowercased() })
        return urls.map(\.lastPathComponent).filter { present.contains($0.lowercased()) }
    }

    private func addFiles() {
        let urls = chooseSkillFiles()
        guard !urls.isEmpty else { return }
        if existing(in: urls).isEmpty { Task { await model.addSkillFiles(skill.id, files: urls) } } else { replacement = urls }
    }

    @ViewBuilder private var files: some View {
        if model.markdownSkillID == skill.id, !model.skillFiles.isEmpty {
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack {
                    Text("Pliki dodatkowe (\(model.skillFiles.count))").font(.caption.bold())
                    Spacer()
                    Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([libraryDirectory]) }.buttonStyle(.link).font(.caption)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.skillFiles) { file in
                            HStack {
                                Text(file.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if file.isExecutable { MetaBadge(text: "wykonywalny", tint: .green) }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).rowMetadata()
                            }
                        }
                    }
                }.frame(maxHeight: 110)
            }
            .padding(.horizontal, Space.section).padding(.vertical, Space.row)
            Divider()
        }
    }

    @ViewBuilder private var content: some View {
        if isEditing {
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).padding(6)
        } else {
            ScrollView { SkillMarkdownView(document: SkillMarkdown.parse(model.markdownSkillID == skill.id ? model.markdown : "")).padding() }
        }
    }
}
