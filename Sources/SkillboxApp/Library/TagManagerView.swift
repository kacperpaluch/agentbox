import SwiftUI
import SkillboxCore

/// Every tag with what uses it, and one way to rename it everywhere at once. Renaming to a name
/// already in use merges the two, which is how two spellings of one idea become one tag.
struct TagManagerView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var tags: [TagSummary]?
    @State private var error = ""
    @State private var editing: TagSummary?
    @State private var newName = ""
    @State private var pending: Rename?

    struct Rename: Identifiable { let from: TagSummary; let to: String; let merges: Bool; var id: String { from.name + "→" + to } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tagi").font(.title2.bold())
                Spacer()
                Button("Zamknij") { dismiss() }
            }
            Text("Zmiana nazwy obejmuje skille, serwery MCP, dokumenty i wszystkie miejsca, które przypisują przez ten tag — projekty, foldery, Ten Mac i domyślne dla nowych projektów. Nazwa, która już istnieje, łączy oba tagi. Przed zapisem powstaje snapshot biblioteki.")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let tags {
                if tags.isEmpty {
                    ContentUnavailableView("Brak tagów", systemImage: "tag", description: Text("Tagi dodasz w szczegółach skilla, serwera albo dokumentu."))
                } else {
                    List(tags) { tag in row(tag) }
                }
            } else if error.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
        .padding(24)
        .sheetFrame(width: 640, height: 560)
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .task { await load() }
        .confirmationDialog(pending.map { $0.merges ? "Połączyć #\($0.from.name) z #\($0.to)?" : "Zmienić #\($0.from.name) na #\($0.to)?" } ?? "", item: $pending) { rename in
            Button(rename.merges ? "Połącz" : "Zmień nazwę") { Task { await apply(rename) } }
            Button("Anuluj", role: .cancel) {}
        } message: { rename in
            Text("Obejmie: \(Self.scope(rename.from)).\(rename.merges ? " #\(rename.from.name) zniknie, a wszystko, co go miało, dostanie #\(rename.to)." : "")")
        }
    }

    @ViewBuilder private func row(_ tag: TagSummary) -> some View {
        HStack {
            Image(systemName: "tag").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(tag.name)").rowTitle()
                Text(Self.scope(tag)).rowMetadata()
            }
            Spacer()
            if editing?.name == tag.name {
                TextField("Nowa nazwa", text: $newName).frame(width: 160).onSubmit { propose(tag) }
                Button("Zmień") { propose(tag) }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Anuluj") { editing = nil }
            } else {
                Button("Zmień nazwę…") { editing = tag; newName = tag.name }.disabled(model.isWorking)
            }
        }
    }

    static func scope(_ tag: TagSummary) -> String {
        var parts: [String] = []
        if tag.skills > 0 { parts.append("skille: \(tag.skills)") }
        if tag.servers > 0 { parts.append("serwery: \(tag.servers)") }
        if tag.docs > 0 { parts.append("dokumenty: \(tag.docs)") }
        if tag.places > 0 { parts.append("miejsca: \(tag.places)") }
        return parts.joined(separator: " · ")
    }

    private func propose(_ tag: TagSummary) {
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty, target != tag.name else { editing = nil; return }
        pending = Rename(from: tag, to: target, merges: tags?.contains { $0.name == target } == true)
    }

    private func apply(_ rename: Rename) async {
        if await model.renameTag(rename.from.name, to: rename.to) { editing = nil; error = ""; await load() }
        else { error = model.message }
    }

    private func load() async {
        do { tags = try await model.tagSummaries() } catch { self.error = error.localizedDescription }
    }
}
