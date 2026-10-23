import SwiftUI
import SkillboxCore

struct AddGitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var subpath = ""
    /// See `NewSkillView.onCreate`.
    let onAdd: (String, String) async -> Bool
    @State private var adding = false
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("Dodaj z Git").font(.title2.bold()); Text("Adres repozytorium lub link GitHub do konkretnego folderu. Możesz wkleić kilka adresów — po jednym w linii.").font(.caption).foregroundStyle(.secondary); TextEditor(text: $url).font(.system(.body, design: .monospaced)).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)); TextField("Podfolder, np. skills (opcjonalnie)", text: $subpath); Text("Dla linku GitHub `/tree/branch/folder` branch i podfolder zostaną rozpoznane automatycznie. Zwykły URL repozytorium importuje wszystkie znalezione katalogi z SKILL.md.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Importuj") { Task { adding = true; defer { adding = false }; if await onAdd(url, subpath) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(adding || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 580) }
}
