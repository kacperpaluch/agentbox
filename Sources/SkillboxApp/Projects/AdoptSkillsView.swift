import SwiftUI
import SkillboxCore

struct AdoptSkillsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let project: Project
    @State private var candidates: [AdoptableSkill]?
    @State private var drifted: [DriftedSkill]?
    @State private var selected = Set<String>()
    @State private var selectedChanges = Set<String>()
    @State private var error = ""
    /// A failed "Przejmij" keeps the sheet open with its reason, next to a freshly read list.
    @State private var adoptError = ""
    /// Git-backed skills are listed so the user learns why they cannot be taken, but they are not
    /// selectable — `adoptSkillChanges` refuses them for the same reason.
    private var selectable: Int { (candidates?.count ?? 0) + (drifted?.filter { !$0.isGitBacked }.count ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Przejmij z projektu").font(.title2.bold())
            Text("Wszystko, co w \(project.name) czeka na przeniesienie do biblioteki: katalogi ze `SKILL.md`, których biblioteka jeszcze nie zna, oraz zarządzane skille zmienione tutaj po ostatniej synchronizacji. Nic nie znika z projektu.").font(.caption).foregroundStyle(.secondary)
            if !adoptError.isEmpty { Label(adoptError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if candidates == nil { ProgressView() }
            else if candidates?.isEmpty == true && drifted?.isEmpty == true { ContentUnavailableView("Brak kandydatów", systemImage: "checkmark.circle", description: Text("Wszystkie skille w tym projekcie są zarządzane i zgodne z biblioteką.")) }
            else {
                List {
                    if let drifted, !drifted.isEmpty {
                        Section("Zmienione w tym projekcie") {
                            ForEach(drifted) { item in
                                Toggle(isOn: Binding(get: { selectedChanges.contains(item.id) }, set: { if $0 { selectedChanges.insert(item.id) } else { selectedChanges.remove(item.id) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.skillID).fontWeight(.medium)
                                            if item.isGitBacked { MetaBadge(text: "z Git", tint: .orange) }
                                        }
                                        Text(item.isGitBacked
                                             ? "Skill pochodzi z repozytorium — zmianę trzeba wprowadzić w źródle, bo aktualizacja i tak zastąpi kopię w bibliotece."
                                             : "Wersja z projektu zastąpi kopię w bibliotece; pozostałe projekty dostaną ją przy swojej synchronizacji.")
                                            .font(.caption).foregroundStyle(item.isGitBacked ? .orange : .secondary)
                                    }
                                }.toggleStyle(.checkbox).disabled(item.isGitBacked)
                            }
                        }
                    }
                    if let candidates, !candidates.isEmpty {
                        Section("Nieznane bibliotece") {
                            ForEach(candidates) { item in
                                Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.suggestedID).fontWeight(.medium)
                                        Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            HStack {
                if selectable > 0 {
                    Button("Zaznacz wszystkie") {
                        selected = Set((candidates ?? []).map(\.id))
                        selectedChanges = Set((drifted ?? []).filter { !$0.isGitBacked }.map(\.id))
                    }
                    Button("Wyczyść") { selected.removeAll(); selectedChanges.removeAll() }
                }
                Spacer()
                Button("Zamknij") { dismiss() }
                Button("Przejmij \(selected.count + selectedChanges.count)") {
                    let newSkills = (candidates ?? []).filter { selected.contains($0.id) }
                    let changes = (drifted ?? []).filter { selectedChanges.contains($0.id) }
                    Task {
                        adoptError = ""
                        if await model.adoptFromProject(newSkills: newSkills, changes: changes) { dismiss() }
                        else { adoptError = model.message; selected.removeAll(); selectedChanges.removeAll(); await load() }
                    }
                }.buttonStyle(.borderedProminent).disabled((selected.isEmpty && selectedChanges.isEmpty) || model.isWorking)
            }
        }
        .padding(24).sheetFrame(width: 640, height: 520)
        .task { await load() }
    }

    private func load() async {
        do {
            candidates = try await model.adoptableSkills(project)
            drifted = try await model.driftedSkills(project)
        } catch { self.error = error.localizedDescription }
    }
}
