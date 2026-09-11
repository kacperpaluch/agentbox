import SwiftUI
import SkillboxCore

struct SkillUpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let plan: SkillUpdatePlan
    let synchronizing: Bool
    @State private var selected = Set<String>()
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aktualizacje skilli").font(.title2.bold())
            Text("Wybierz aktualizacje do przyjęcia. Zapis obejmie dokładnie sprawdzone pliki; wcześniej powstanie pełny backup biblioteki. Metadane .git i .DS_Store nie są częścią podglądu skilla.").font(.caption).foregroundStyle(.secondary)
            if synchronizing { Label("Po przyjęciu wyboru Agentbox zsynchronizuje projekty. Odznaczone aktualizacje pozostaną na później.", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
            Label("Pliki skilli mogą zawierać prywatne dane i kod. Podgląd pokazuje ich jawną treść.", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.failed, id: \.id) { failure in Text("Nie udało się sprawdzić \(failure.id): \(failure.reason)").foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                    if plan.updates.isEmpty { Text("Brak zmian do przyjęcia\(plan.failed.isEmpty ? " — skille są aktualne." : " w poprawnie sprawdzonych skillach.")") }
                    ForEach(plan.updates) { update in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(update.skill.name, isOn: Binding(get: { selected.contains(update.id) }, set: { if $0 { selected.insert(update.id) } else { selected.remove(update.id) } })).toggleStyle(.checkbox).font(.headline)
                                Text("Rewizja: \(update.skill.source.revision.map { String($0.prefix(12)) } ?? "lokalna") → \(update.revision.map { String($0.prefix(12)) } ?? "lokalna")").font(.caption).foregroundStyle(.secondary)
                                Text(update.usage.projects.isEmpty ? "Brak przypisanych projektów" : "Projekty: " + update.usage.projects.joined(separator: ", ")).font(.caption)
                                if update.usage.global { Text("Używany także globalnie na tym Macu").font(.caption) }
                                SkillChangesView(changes: update.changes)
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !plan.unchanged.isEmpty { Text("Bez zmian: \(plan.unchanged.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Sprawdź ponownie") { Task { await model.prepareUpdateReview(synchronizing: synchronizing) } }.disabled(model.isWorking)
                Spacer()
                Button("Anuluj") { dismiss() }.disabled(model.isWorking)
                Button(synchronizing ? "Przyjmij wybór i synchronizuj" : "Przyjmij wybrane (\(selected.count))") {
                    Task {
                        if await model.acceptSkillUpdates(plan, selected: selected, synchronizing: synchronizing) { dismiss() }
                        else { error = model.message }
                    }
                }.buttonStyle(.borderedProminent).disabled(model.isWorking || (selected.isEmpty && !synchronizing))
            }
        }
        .padding(24).sheetFrame(width: 860, height: 700)
        .onAppear { selected = Set(plan.updates.map(\.id)) }
        .interactiveDismissDisabled(model.isWorking)
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
    }
}

struct SkillChangesView: View {
    let changes: [SkillFileChange]
    var body: some View {
        ForEach(changes) { change in
            DisclosureGroup("\(change.kind) · \(change.path)") {
                VStack(alignment: .leading, spacing: 5) {
                    if !change.note.isEmpty { Text(change.note).font(.caption).foregroundStyle(.secondary) }
                    if change.oldText != nil || change.newText != nil {
                        SkillTextDiff(old: change.oldText ?? "", new: change.newText ?? "")
                    }
                }.padding(.vertical, 6)
            }
        }
    }
}

private struct SkillTextDiff: View {
    let old: String, new: String
    @State private var lines: [DiffLine] = []
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) { ForEach(lines) { DiffLineRow(line: $0) } }
            .task { lines = TextDiff.lines(old: old, new: new) }
    }
}
