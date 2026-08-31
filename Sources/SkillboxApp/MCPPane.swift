import SwiftUI
import AppKit
import Combine
import SkillboxCore

/// The MCP-server half of the library. Search and the tag filter come from `LibraryView`.
struct MCPPane: View {
    @ObservedObject var model: AppModel
    let search: String
    let selectedTag: String
    @State private var editingServer: MCPServer?
    @State private var serverToDuplicate: MCPServer?
    @State private var serverToDelete: MCPServer?
    @State private var showAdd = false
    @State private var bulkJSON: String?
    @State private var checked = Set<UUID>()
    @State private var showBatchTags = false
    private var existingTags: [String] { Array(Set(model.mcp.servers.flatMap { $0.tags ?? [] })).sorted() }
    private var filtered: [MCPServer] {
        model.mcp.servers
            .filter { libraryMatches(name: $0.name, id: $0.name, tags: $0.tags ?? [], search: search, selectedTag: selectedTag) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if model.mcp.servers.isEmpty {
                ContentUnavailableView("Brak serwerów MCP", systemImage: "network", description: Text("Zaimportuj konfigurację z JSON albo dodaj serwer ręcznie."))
            } else if filtered.isEmpty {
                ContentUnavailableView("Nic nie pasuje", systemImage: "magnifyingglass", description: Text("Zmień wyszukiwanie albo wybrany tag."))
            } else {
                List {
                    Section("Serwery") {
                        ForEach(filtered) { server in
                            HStack(alignment: .top, spacing: Space.row + 1) {
                                Toggle("", isOn: checkBinding(server.id)).labelsHidden().toggleStyle(.checkbox).padding(.top, 5)
                                MCPServerRow(server: server, onDetails: { editingServer = server }, onDuplicate: { serverToDuplicate = server }, onDelete: { serverToDelete = server })
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            MCPImportView(model: model) {
                editingServer = MCPServer(name: "", transport: .stdio)
            }
        }
        .sheet(item: $editingServer) { server in MCPServerEditor(model: model, server: server, existingTags: existingTags) }
        .sheet(item: $serverToDuplicate) { server in MCPDuplicateView(model: model, server: server) }
        .sheet(item: Binding(get: { bulkJSON.map(IdentifiableString.init) }, set: { bulkJSON = $0?.value })) { text in MCPBulkJSONView(model: model, text: text.value) }
        .sheet(isPresented: $showBatchTags) { BatchTagView(count: checked.count, existingTags: existingTags, noun: "serwerów MCP") { text in Task { await model.addMCPServerTags(checked, text: text); checked.removeAll() } } }
        .confirmationDialog("Usunąć serwer \(serverToDelete?.name ?? "")?", isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })) { Button("Usuń", role: .destructive) { if let serverToDelete { Task { await model.deleteMCPServer(serverToDelete.id) } }; serverToDelete = nil }; Button("Anuluj", role: .cancel) { serverToDelete = nil } } message: { Text("Serwer zostanie usunięty także z bezpośrednich przypisań projektów.") }
    }

    // Same contextual-bar pattern as the Library: add actions when nothing is checked, a selection
    // bar the moment something is.
    private var actionBar: some View {
        ActionBar {
            if checked.isEmpty {
                Button { showAdd = true } label: { Label("Dodaj serwer", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { Task { bulkJSON = await model.exportMCPConfigurationJSON() } } label: {
                    Label("Edytuj całą konfigurację", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
                .disabled(model.mcp.servers.isEmpty)
            } else {
                Text("Wybrano \(checked.count)").rowMetadata()
                Button { showBatchTags = true } label: { Label("Dodaj tagi", systemImage: "tag") }.buttonStyle(.borderedProminent)
                Button("Anuluj") { checked.removeAll() }.buttonStyle(.bordered)
            }
            Spacer()
            Text(filtered.count == model.mcp.servers.count ? "\(model.mcp.servers.count) serwerów" : "\(filtered.count) z \(model.mcp.servers.count)").rowMetadata()
        }
    }

    private func checkBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } }) }

}

private struct MCPDuplicateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let server: MCPServer
    @State private var name: String
    @State private var error = ""

    init(model: AppModel, server: MCPServer) {
        self.model = model; self.server = server
        _name = State(initialValue: "\(server.name)-copy")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Duplikuj serwer MCP").font(.title2.bold())
            Text("Powstanie niezależna kopia 1:1 — z transportem, URL-em, argumentami, zmiennymi, nagłówkami, wartościami lokalnymi i tagami. Przypisania do projektów nie są kopiowane.").font(.caption).foregroundStyle(.secondary)
            TextField("Nowa nazwa techniczna", text: $name)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Anuluj") { dismiss() }; Button("Duplikuj") { Task { await duplicate() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking) }
        }
        .padding(24).sheetFrame(width: 560, height: 220)
    }

    private func duplicate() async {
        error = ""
        if await model.duplicateMCPServer(server, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
        else { error = model.message }
    }
}

/// One line per selected plugin, saying plainly whether synchronization still has work to do for
/// it. The distinction matters: an already declared plugin is left alone, a missing one is handed
/// to Claude Code.
struct ClaudePluginPreviewRow: View {
    let item: ClaudePluginPreview
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.isInstalled ? "Już w projekcie: \(item.name)" : "Zostanie zainstalowany: \(item.name)")
                Text(item.plugin).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(item.scope.displayName).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: item.isInstalled ? "checkmark.circle" : "puzzlepiece.extension")
        }
        .font(.caption)
        .foregroundStyle(item.isInstalled ? Color.secondary : Color.primary)
    }
}

/// Two lines per server: name, transport and tags on top; the supporting counts (arguments,
/// variables, secrets) quiet underneath instead of trailing off the end of one long line.
private struct MCPServerRow: View {
    let server: MCPServer
    let onDetails: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    private var secretCount: Int { (server.secretEnvironment?.count ?? 0) + (server.secretHeaders?.count ?? 0) }
    private var variableCount: Int { server.environment.count + (server.literalEnvironment?.count ?? 0) + (server.secretEnvironment?.count ?? 0) }
    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: server.transport == .stdio ? "terminal" : "globe").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.row) {
                    Text(server.name).rowTitle()
                    MetaBadge(text: server.transport == .stdio ? "Lokalny" : "HTTP")
                    ForEach(server.tags ?? [], id: \.self) { TagPill(tag: $0) }
                }
                Text("\(server.arguments.count) argumentów · \(variableCount) zmiennych\(secretCount > 0 ? " · \(secretCount) sekretów lokalnych" : "")").rowMetadata()
            }
            Spacer()
            Button("Szczegóły", action: onDetails).controlSize(.small)
            RowMenu {
                Button("Szczegóły…", action: onDetails)
                Button("Duplikuj…", action: onDuplicate)
                Divider()
                Button("Usuń…", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, Space.tight)
    }
}
/// Wraps a `String` so it can back a `.sheet(item:)` — used to present the bulk JSON editor
/// pre-filled with a freshly generated export instead of an always-empty `.sheet(isPresented:)`.
struct IdentifiableString: Identifiable { let value: String; var id: String { value } }
/// Edit-and-save for the whole MCP configuration as JSON: no analyze/select/classify step, because
/// this text already came straight out of the library — every server in it is meant to be applied.
/// That ceremony stays in `MCPImportView`, which is for a config pasted in from somewhere else.
struct MCPBulkJSONView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State var text: String
    @State private var error = ""
    @State private var working = false
    var body: some View { VStack(alignment: .leading, spacing: 14) {
        Text("Edytuj konfigurację MCP jako JSON").font(.title2.bold())
        Text("Wartości wprost, łącznie z sekretami. Zapis nadpisuje po nazwie serwery obecne w tekście, resztę zostawia bez zmian — usunięcie serwera z tekstu go tu nie kasuje. Klucze wyglądające na token/hasło/API key automatycznie zostają tylko na tym Macu.").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 420).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        HStack { if working { ProgressView() }; Spacer(); Button("Anuluj") { dismiss() }; Button("Zapisz") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working) }
    }.padding(24).sheetFrame(width: 720, height: 600) }
    private func save() async {
        working = true; error = ""; defer { working = false }
        do { _ = try await model.importMCPJSONAll(text); dismiss() } catch { self.error = error.localizedDescription; model.reportError(error) }
    }
}
struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let original: MCPServer; let existingTags: [String]
    @State private var name: String; @State private var transport: MCPTransport; @State private var command: String; @State private var arguments: String; @State private var url: String; @State private var enabled: Bool; @State private var tags: String
    @State private var fields: [MCPManagedField] = []
    @State private var editingJSON = false
    @State private var jsonText = ""
    init(model: AppModel, server: MCPServer, existingTags: [String]) { self.model = model; original = server; self.existingTags = existingTags; _name = State(initialValue: server.name); _transport = State(initialValue: server.transport); _command = State(initialValue: server.command); _arguments = State(initialValue: server.arguments.joined(separator: "\n")); _url = State(initialValue: server.url); _enabled = State(initialValue: server.enabled); _tags = State(initialValue: (server.tags ?? []).joined(separator: ", ")) }
    /// The JSON view only makes sense once the server is actually saved — a brand-new, unsaved one
    /// has nothing in the store yet to export or to match by id.
    private var isExisting: Bool { model.mcp.servers.contains { $0.id == original.id } }
    var body: some View { VStack(spacing: 0) { ScrollView { Form { Text("Serwer MCP").font(.title2.bold()); TextField("Nazwa techniczna", text: $name); HStack { TextField("Tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }; Toggle("Włączony", isOn: $enabled)
        if isExisting { Picker("Widok", selection: $editingJSON) { Text("Formularz").tag(false); Text("JSON").tag(true) }.pickerStyle(.segmented).onChange(of: editingJSON) { if editingJSON { Task { jsonText = await model.exportMCPServerJSON(original.id) } } } }
        if editingJSON && isExisting {
            Text("Pełna konfiguracja tego serwera, wartości wprost. Zapis `${VAR}` oznacza odczyt zmiennej systemowej; pozostałe wartości są przechowywane lokalnie w bibliotece.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $jsonText).font(.system(.body, design: .monospaced)).frame(height: 340).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        } else {
            Picker("Transport", selection: $transport) { Text("Lokalny STDIO").tag(MCPTransport.stdio); Text("Zdalny HTTP").tag(MCPTransport.http) }.pickerStyle(.segmented)
            if transport == .stdio { TextField("Polecenie, np. npx", text: $command); Text("Argumenty — jeden na linię").font(.caption).foregroundStyle(.secondary); TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 75) } else { TextField("URL", text: $url) }
        }
        // The JSON view already shows env/header values in plain text, so showing this section too
        // would just be the same fields twice in two formats — it appears only in form mode.
        if !(editingJSON && isExisting) {
            GroupBox("Zmienne i nagłówki") { VStack(alignment: .leading, spacing: 10) { Text("Wartości są przechowywane lokalnie wprost. Aby użyć zmiennej systemowej, wpisz `${NAZWA_ZMIENNEJ}`.").font(.caption).foregroundStyle(.secondary); ForEach($fields) { $field in MCPManagedFieldRow(field: $field) { fields.removeAll { $0.id == field.id } } }; HStack { Button("Dodaj zmienną") { fields.append(MCPManagedField(location: .environment, key: "", classification: .literal)) }; Button("Dodaj nagłówek") { fields.append(MCPManagedField(location: .header, key: "", classification: .literal)) } } }.padding(7) }
        }
    }.padding(24) }
    // Pinned below the scrolling form, so the action stays reachable on any display.
    SheetFooter {
        Button("Anuluj") { dismiss() }
        Button("Zapisz") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(name.isEmpty || (editingJSON && isExisting ? jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (transport == .stdio ? command.isEmpty : url.isEmpty)) || model.isWorking)
    } }.sheetFrame(width: 760, height: 660).task { fields = await model.managedFields(for: original) } }
    private func save() async -> Bool {
        if editingJSON && isExisting { return await model.updateMCPServerJSON(original.id, name: name, json: jsonText, enabled: enabled, tags: AppModel.csv(tags)) }
        let server = MCPServer(id: original.id, name: name, transport: transport, command: command, arguments: arguments.split(whereSeparator: \.isNewline).map(String.init), url: url, enabled: enabled, tags: AppModel.csv(tags))
        return await model.saveMCPServer(server, fields: fields)
    }
}
struct MCPManagedFieldRow: View {
    @Binding var field: MCPManagedField
    let onDelete: () -> Void
    var body: some View { HStack { Picker("Miejsce", selection: $field.location) { Text("Zmienna").tag(MCPImportField.Location.environment); Text("Nagłówek").tag(MCPImportField.Location.header) }.labelsHidden().frame(width: 105); TextField("Nazwa", text: $field.key).frame(minWidth: 120); TextField("Wartość lub ${ZMIENNA}", text: $field.value); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } } }
}
struct MCPImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
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
    @State private var openAIModel = "gpt-5-mini"
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
            HStack { SecureField("Klucz API OpenAI", text: $openAIKey); TextField("Model", text: $openAIModel).frame(width: 160) }
            Text("Klucz jest używany wyłącznie dla tego żądania i nie jest zapisywany. Treść instrukcji zostanie wysłana do OpenAI; wynik nie zostanie zapisany automatycznie — najpierw go przejrzysz.").font(.caption).foregroundStyle(.orange)
        }
        if showFormatHelp { formatHelp }
        TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        TextField("Nazwa pojedynczego serwera (opcjonalnie)", text: $singleServerName)
            .help("Dotyczy tylko JSON-a opisującego jeden serwer. Pusta nazwa zostanie rozsądnie zaproponowana z argumentów.")
        if let summary {
            GroupBox("Rozpoznano") { VStack(alignment: .leading, spacing: 8) {
                if summary.isSingleServerInput { Text("To konfiguracja jednego serwera. Zostanie zapisany jako „\(summary.servers.first?.name ?? singleServerName)”. Zmień nazwę powyżej i ponownie analizuj, jeśli potrzeba.").font(.caption).foregroundStyle(.secondary) }
                HStack { Text("\(summary.servers.count) serwerów · \(summary.stdioCount) lokalnych · \(summary.httpCount) HTTP"); Spacer(); Button("Wszystkie") { selected = Set(summary.servers.map(\.name)) }.buttonStyle(.link); Button("Wyczyść") { selected.removeAll() }.buttonStyle(.link) }
                ForEach(summary.servers) { server in Toggle(isOn: Binding(get: { selected.contains(server.name) }, set: { if $0 { selected.insert(server.name) } else { selected.remove(server.name) } })) { HStack { Image(systemName: server.transport == .stdio ? "terminal" : "globe"); Text(server.name); Spacer() } }.toggleStyle(.checkbox) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }.padding(24) }; Divider(); HStack { if working { ProgressView() }; if summary != nil { Text(needsReanalysis ? "Zmień nazwę → Analizuj ponownie" : "Wybrano: \(selected.count)").font(.caption).foregroundStyle(needsReanalysis ? .orange : .secondary) }; Spacer(); Button("Anuluj") { dismiss() }; if mode != .creator { Button(usesAI ? "Przygotuj z AI" : "Analizuj") { Task { await prepare() } }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (usesAI && openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || working); Button("Importuj wybrane") { Task { await importNow() } }.buttonStyle(.borderedProminent).disabled(summary == nil || selected.isEmpty || needsReanalysis || working) } }.padding(16).background(.bar)
    }.sheetFrame(width: 760, height: 680) }
    private func prepare() async { working = true; error = ""; summary = nil; selected.removeAll(); defer { working = false }; do { if usesAI { source = try await model.generateMCP(source, apiKey: openAIKey, model: openAIModel) }; let analyzed = try await model.analyzeMCP(source, singleServerName: singleServerName.isEmpty ? nil : singleServerName); summary = analyzed; if analyzed.isSingleServerInput, singleServerName.isEmpty { singleServerName = analyzed.servers.first?.name ?? "" }; selected = Set(analyzed.servers.map(\.name)) } catch { self.error = error.localizedDescription; model.reportError(error) } }
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
                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .padding(Space.row).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }.padding(Space.row)
        }
    }
}
struct MCPPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel; let project: Project
    @State private var preview: ProjectSyncPreview?; @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja · \(project.name)").font(.title2.bold())
            Text("Poniżej znajduje się pełny plan zmian skilli i konfiguracji MCP. Całość zostanie wycofana, jeśli którykolwiek zapis się nie powiedzie.").font(.caption).foregroundStyle(.secondary)
            Label("Pliki projektu mogą zawierać jawne sekrety. Agentbox doda je do lokalnego .git/info/exclude, ale nie szyfruje ich na dysku.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if preview?.mcp.contains(where: { $0.file.hasSuffix(".jsonc") }) == true { Label("Plik OpenCode JSONC zostanie przepisany jako JSON. Komentarze i dotychczasowe formatowanie zostaną usunięte.", systemImage: "text.badge.xmark").font(.caption).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if preview == nil { ProgressView() }
            else if let preview { ScrollView { VStack(alignment: .leading, spacing: 12) {
                Text("Skille").font(.headline)
                ForEach(preview.skills, id: \.tool) { item in GroupBox { VStack(alignment: .leading, spacing: 6) { Text(item.target).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: item.updated, removed: item.removed) }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "folder") } }
                Text("MCP").font(.headline).padding(.top, 4)
                ForEach(preview.mcp, id: \.tool.rawValue) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); DisclosureGroup("Podgląd pliku") { Text(item.content.isEmpty ? "Plik nie jest potrzebny — nie zostanie utworzony, a istniejący pusty szkielet zostanie usunięty." : item.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) } }.padding(7) } label: { Label(item.tool.rawValue.capitalized, systemImage: "doc.text") } }
                if !preview.docs.isEmpty {
                    Text("Dokumenty").font(.headline).padding(.top, 4)
                    ForEach(preview.docs, id: \.file) { item in GroupBox { VStack(alignment: .leading, spacing: 8) { Text(item.file).font(.caption).foregroundStyle(.secondary); SyncChangeRows(added: item.added, updated: [], removed: item.removed); DisclosureGroup("Podgląd pliku") { Text(item.content.isEmpty ? "Plik nie jest potrzebny — nie zostanie utworzony, a istniejący zarządzany plik zostanie usunięty." : item.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) } }.padding(7) } label: { Label(URL(fileURLWithPath: item.file).lastPathComponent, systemImage: "doc.text") } }
                }
                if !preview.plugins.isEmpty {
                    Text("Pluginy Claude").font(.headline).padding(.top, 4)
                    ForEach(preview.plugins) { item in ClaudePluginPreviewRow(item: item) }
                }
            } } }
            HStack { Spacer(); Button("Zamknij") { dismiss() }; Button("Synchronizuj skille, MCP, dokumenty i pluginy") { Task { await model.syncEverything(project) } }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || preview == nil || model.isWorking) }
        }.padding(24).sheetFrame(width: 820, height: 700).task { do { preview = try await model.previewProjectSync(project) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    }
}
struct SyncChangeRows: View {
    let added: [String], updated: [String], removed: [String]
    var body: some View { VStack(alignment: .leading, spacing: 3) { if added.isEmpty && updated.isEmpty && removed.isEmpty { Text("Brak zmian").font(.caption).foregroundStyle(.secondary) }; ForEach(added, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.green) }; ForEach(updated, id: \.self) { Label($0, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue) }; ForEach(removed, id: \.self) { Label($0, systemImage: "minus.circle.fill").foregroundStyle(.orange) } }.font(.caption) }
}
