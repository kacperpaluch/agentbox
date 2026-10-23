import SwiftUI
import SkillboxCore

struct MCPImportView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let onOpenManual: () -> Void
    private enum AddMode: String, CaseIterable, Identifiable {
        case creator = "Kreator", json = "JSON", ai = "AI"
        var id: String { rawValue }
    }
    @State private var source = ""
    @State private var summary: MCPImportSummary?
    @State private var error = ""
    @State private var working = false
    @State private var selected = Set<String>()
    @State private var showFormatHelp = false
    @State private var singleServerName = ""
    @State private var mode: AddMode = .creator
    @State private var openAIKey = ""
    @AppStorage("AgentboxOpenAIModel") private var openAIModel = "gpt-5-mini"
    private var usesAI: Bool { mode == .ai }
    private var needsReanalysis: Bool { summary?.isSingleServerInput == true && summary?.servers.first?.name != singleServerName }
    var body: some View { VStack(alignment: .leading, spacing: 0) { ScrollView { VStack(alignment: .leading, spacing: 14) {
        Text("Dodaj serwer MCP").font(.title2.bold())
        Text("Wybierz sposób dodania. Każda ścieżka kończy się przeglądem konfiguracji przed zapisem.").font(.caption).foregroundStyle(.secondary)
        Picker("Sposób dodania", selection: $mode) { ForEach(AddMode.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented)
        if mode == .creator {
            GroupBox("Kreator ręczny") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Wypełnij formularz: nazwa, sposób połączenia, argumenty, zmienne i nagłówki.").foregroundStyle(.secondary)
                    Button("Otwórz kreator") { onOpenManual(); dismiss() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.row)
            }
        } else {
        HStack {
            Text(usesAI ? "Wklej instrukcję instalacji, fragment README albo opisz serwer." : "Wklej mapę serwerów albo konfigurację jednego serwera.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !usesAI { Button(showFormatHelp ? "Ukryj format" : "Jaki format?") { showFormatHelp.toggle() }.buttonStyle(.link) }
            Button("Wybierz plik…") { chooseFile() }
        }
        if usesAI {
            HStack {
                SecureField("Klucz API OpenAI", text: $openAIKey); TextField("Model", text: $openAIModel).frame(width: 160)
                Button("Usuń zapamiętany klucz") { forgetOpenAIKey() }.disabled(working)
            }
            Text("Klucz zostaje zapisany w pęku kluczy, a model w ustawieniach — przy kolejnym dodawaniu są już wypełnione. Treść instrukcji zostanie wysłana do OpenAI; wynik nie zostanie zapisany automatycznie — najpierw go przejrzysz.").font(.caption).foregroundStyle(.orange)
        }
        if showFormatHelp { formatHelp }
        TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        TextField("Nazwa pojedynczego serwera (opcjonalnie)", text: $singleServerName)
            .help("Dotyczy tylko JSON-a opisującego jeden serwer. Pusta nazwa zostanie rozsądnie zaproponowana z argumentów.")
        if let summary {
            GroupBox("Rozpoznano") { VStack(alignment: .leading, spacing: 8) {
                if summary.isSingleServerInput { Text("To konfiguracja jednego serwera. Zostanie zapisany jako „\(summary.servers.first?.name ?? singleServerName)”. Zmień nazwę powyżej i ponownie analizuj, jeśli potrzeba.").font(.caption).foregroundStyle(.secondary) }
                HStack { Text("\(PolishNoun.server(summary.servers.count)) · lokalne: \(summary.stdioCount) · HTTP: \(summary.httpCount)"); Spacer(); Button("Wszystkie") { selected = Set(summary.servers.map(\.name)) }.buttonStyle(.link); Button("Wyczyść") { selected.removeAll() }.buttonStyle(.link) }
                ForEach(summary.servers) { server in Toggle(isOn: Binding(get: { selected.contains(server.name) }, set: { if $0 { selected.insert(server.name) } else { selected.remove(server.name) } })) { HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe"); Text(server.name); Spacer() } }.toggleStyle(.checkbox) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }.padding(24) }; Divider(); HStack { if working { ProgressView() }; if summary != nil { Text(needsReanalysis ? "Zmień nazwę → Analizuj ponownie" : "Wybrano: \(selected.count)").font(.caption).foregroundStyle(needsReanalysis ? .orange : .secondary) }; Spacer(); Button("Anuluj") { dismiss() }; if mode != .creator { Button(usesAI ? "Przygotuj z AI" : "Analizuj") { Task { await prepare() } }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (usesAI && openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || working); Button("Importuj wybrane") { Task { await importNow() } }.buttonStyle(.borderedProminent).disabled(summary == nil || selected.isEmpty || needsReanalysis || working) } }.padding(16).background(.bar)
    }.sheetFrame(width: 760, height: 680).task { if openAIKey.isEmpty { openAIKey = OpenAIKeyStore.load() } } }
    private func forgetOpenAIKey() {
        do { try OpenAIKeyStore.delete(); openAIKey = ""; error = "" }
        catch { self.error = error.localizedDescription; model.reportError(error) }
    }
    private func prepare() async { working = true; error = ""; summary = nil; selected.removeAll(); defer { working = false }; do { if usesAI { try OpenAIKeyStore.save(openAIKey); source = try await model.generateMCP(source, apiKey: openAIKey, model: openAIModel) }; let analyzed = try await model.analyzeMCP(source, singleServerName: singleServerName.isEmpty ? nil : singleServerName); summary = analyzed; if analyzed.isSingleServerInput, singleServerName.isEmpty { singleServerName = analyzed.servers.first?.name ?? "" }; selected = Set(analyzed.servers.map(\.name)) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    private func importNow() async { working = true; error = ""; defer { working = false }; do { _ = try await model.importMCP(source, serverNames: selected, classifications: [:], singleServerName: summary?.isSingleServerInput == true ? singleServerName : nil); dismiss() } catch { self.error = error.localizedDescription; model.reportError(error) } }
    private func chooseFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.canChooseFiles = true; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { do { source = try String(contentsOf: url, encoding: .utf8); summary = nil } catch { self.error = error.localizedDescription } } }

    /// The three shapes `analyzeMCP` actually accepts — collapsed by default so it does not compete
    /// with the paste box, but one click away the moment someone is unsure what to paste.
    private var formatHelp: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Agentbox rozpoznaje mapę serwerów oraz JSON jednego serwera:").font(.caption.weight(.medium))
                Text("• cały eksport Claude z kluczem `mcpServers` na zewnątrz").font(.caption).foregroundStyle(.secondary)
                Text("• samą mapę serwerów, bez `mcpServers` dookoła").font(.caption).foregroundStyle(.secondary)
                Text("• plik JSON w jednym z tych formatów — przyciskiem „Wybierz plik…”").font(.caption).foregroundStyle(.secondary)
                Text("• pojedynczy obiekt z `command`/`args`/`env` lub `url` — podaj nazwę nad analizą albo zaakceptuj propozycję").font(.caption).foregroundStyle(.secondary)
                Text("""
                {
                  "context7": {
                    "command": "npx",
                    "args": ["-y", "@upstash/context7-mcp"]
                  },
                  "docsearch": {
                    "type": "http",
                    "url": "https://mcp.example.com/mcp",
                    "headers": { "Authorization": "Bearer TOKEN" }
                  }
                }
                """)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(Space.row).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }.padding(Space.row)
        }
    }
}
