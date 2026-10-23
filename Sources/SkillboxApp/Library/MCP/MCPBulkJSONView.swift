import SwiftUI
import SkillboxCore

/// Edit-and-save for the whole MCP configuration as JSON: no analyze/select/classify step, because
/// this text already came straight out of the library — every server in it is meant to be applied.
/// That ceremony stays in `MCPImportView`, which is for a config pasted in from somewhere else.
struct MCPBulkJSONView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var text: String
    @State private var error = ""
    @State private var working = false

    init(model: AppModel, text: String) {
        self.model = model
        _text = State(initialValue: text)
    }
    var body: some View { VStack(alignment: .leading, spacing: 14) {
        Text("Edytuj konfigurację MCP jako JSON").font(.title2.bold())
        Text("Wartości wprost, łącznie z sekretami. Zapis nadpisuje po nazwie serwery obecne w tekście, resztę zostawia bez zmian — usunięcie serwera z tekstu go tu nie kasuje. Wartość `${ZMIENNA}` przekazuje zmienną systemową; każda inna wartość — także token — zostaje zapisana w mcp.json i trafia do plików projektów, do których serwer jest przypisany.").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 420).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        HStack { if working { ProgressView() }; Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working) }
    }.padding(24).sheetFrame(width: 720, height: 600) }
    private func save() async {
        working = true; error = ""; defer { working = false }
        do { _ = try await model.importMCPJSONAll(text); dismiss() } catch { self.error = error.localizedDescription; model.reportError(error) }
    }
}
