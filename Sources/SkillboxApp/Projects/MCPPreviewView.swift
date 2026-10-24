import SwiftUI
import SkillboxCore

struct MCPPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel; let project: Project
    @State private var preview: ProjectSyncPreview?; @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja · \(project.name)").font(.title2.bold())
            Text("Pełny plan zmian. Jeśli którykolwiek zapis się nie powiedzie, całość zostanie wycofana.").font(.caption).foregroundStyle(.secondary)
            Label("Pliki projektu mogą zawierać jawne, niezaszyfrowane sekrety. Agentbox dopisuje je do .git/info/exclude i nie zapisuje wartości lokalnych do pliku już śledzonego przez Git.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if preview?.mcp.contains(where: { $0.file.hasSuffix(".jsonc") }) == true { Label("W pliku OpenCode JSONC podmieniany jest wyłącznie zarządzany klucz `mcp`. Komentarze i pozostałe klucze zostają bez zmian.", systemImage: "text.badge.checkmark").font(.caption).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if preview == nil { ProgressView() }
            else if let preview { ScrollView { VStack(alignment: .leading, spacing: 12) {
                Text("Skille").font(.headline)
                ForEach(preview.skills, id: \.tool) { item in GroupBox { VStack(alignment: .leading, spacing: 6) { Text(item.target).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed) }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "folder") } }
                Text("MCP").font(.headline).padding(.top, 4)
                ForEach(preview.mcp, id: \.tool.rawValue) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); FileChangeDisclosure(file: item.file, content: item.content, emptyMeansRemoval: "Plik nie jest potrzebny — nie zostanie utworzony, a istniejący pusty szkielet zostanie usunięty.") }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "doc.text") } }
                if !preview.docs.isEmpty {
                    Text("Dokumenty").font(.headline).padding(.top, 4)
                    ForEach(preview.docs, id: \.file) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); FileChangeDisclosure(file: item.file, content: item.content, leaveAsIs: item.leaveAsIs, emptyMeansRemoval: "Plik nie jest potrzebny — nie zostanie utworzony, a istniejący zarządzany plik zostanie usunięty.") }.padding(7) } label: { Label(URL(fileURLWithPath: item.file).lastPathComponent, systemImage: "doc.text") } }
                }
                if !preview.plugins.isEmpty {
                    Text("Pluginy Claude").font(.headline).padding(.top, 4)
                    ForEach(preview.plugins) { item in ClaudePluginPreviewRow(item: item) }
                }
            } } }
            HStack { Spacer(); Button("Zamknij") { dismiss() }; Button("Synchronizuj") { Task { if await model.syncEverything(project) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || preview == nil || model.isWorking) }
        }.padding(24).sheetFrame(width: 820, height: 700)
        // Okno arkusza zasłania overlay z App.swift, więc postęp musi być rysowany też tutaj.
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .task { do { preview = try await model.previewProjectSync(project) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    }
}
