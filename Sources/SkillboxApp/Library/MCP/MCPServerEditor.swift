import SwiftUI
import SkillboxCore

struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let original: MCPServer; let existingTags: [String]
    @State private var name: String; @State private var transport: MCPTransport; @State private var command: String; @State private var arguments: String; @State private var url: String; @State private var enabled: Bool; @State private var tags: String
    @State private var fields: [MCPManagedField] = []
    @State private var editingJSON = false
    @State private var jsonText = ""
    /// Set when the saved variables and headers could not be read. The form then cannot be saved:
    /// it rebuilds them from `fields`, and an empty list would erase them.
    @State private var fieldsError: String?
    @State private var switchError = ""
    init(model: AppModel, server: MCPServer, existingTags: [String]) { self.model = model; original = server; self.existingTags = existingTags; _name = State(initialValue: server.name); _transport = State(initialValue: server.transport); _command = State(initialValue: server.command); _arguments = State(initialValue: server.arguments.joined(separator: "\n")); _url = State(initialValue: server.url); _enabled = State(initialValue: server.enabled); _tags = State(initialValue: (server.tags ?? []).joined(separator: ", ")) }
    /// The JSON view only makes sense once the server is actually saved — a brand-new, unsaved one
    /// has nothing in the store yet to export or to match by id.
    private var isExisting: Bool { model.mcp.servers.contains { $0.id == original.id } }
    var body: some View { VStack(spacing: 0) { ScrollView { Form { Text("Serwer MCP").font(.title2.bold()); TextField("Nazwa techniczna", text: $name); HStack { TextField("Tagi, oddzielone przecinkami", text: $tags); ExistingTagMenu(tags: existingTags, text: $tags) }; Toggle("Włączony", isOn: $enabled)
        if isExisting {
            Picker("Widok", selection: Binding(get: { editingJSON }, set: { toJSON in Task { await switchView(toJSON: toJSON) } })) { Text("Formularz").tag(false); Text("JSON").tag(true) }
                .pickerStyle(.segmented).disabled(fieldsError != nil)
            if !switchError.isEmpty { Label(switchError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
        }
        if let fieldsError { Label("Nie udało się wczytać zmiennych i nagłówków: \(fieldsError). Zapis jest zablokowany, żeby ich nie usunąć.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
        if editingJSON && isExisting {
            Text("Pełna konfiguracja tego serwera, wartości wprost. Zapis `${VAR}` oznacza odczyt zmiennej systemowej; pozostałe wartości są przechowywane lokalnie w bibliotece.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $jsonText).font(.system(.body, design: .monospaced)).frame(height: 340).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        } else {
            Picker("Transport", selection: $transport) { Text("Lokalny STDIO").tag(MCPTransport.stdio); Text("Zdalny HTTP").tag(MCPTransport.http); Text("Zdalny SSE").tag(MCPTransport.sse) }.pickerStyle(.segmented)
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
        Button("Zapisz") { Task { if await save() { dismiss() } } }.buttonStyle(.borderedProminent).disabled(name.isEmpty || fieldsError != nil || (editingJSON && isExisting ? jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (transport == .stdio ? command.isEmpty : url.isEmpty)) || model.isWorking)
    } }.sheetFrame(width: 760, height: 660).task {
        // A server that is not saved yet has no fields to read.
        guard isExisting else { return }
        do { fields = try await model.managedFields(for: original) } catch { fieldsError = error.localizedDescription }
    } }
    private var formServer: MCPServer {
        MCPServer(id: original.id, name: name, transport: transport, command: command, arguments: arguments.split(whereSeparator: \.isNewline).map(String.init), url: url, enabled: enabled, tags: AppModel.csv(tags))
    }
    /// Both views edit one draft: the JSON shows the unsaved form, and going back reads the edited
    /// JSON into the form. JSON that does not parse keeps the JSON view open with the reason.
    private func switchView(toJSON: Bool) async {
        guard toJSON != editingJSON else { return }
        switchError = ""
        do {
            if toJSON {
                jsonText = try await model.mcpServerDraftJSON(formServer, fields: fields)
            } else {
                let draft = try await model.mcpServerDraft(fromJSON: jsonText, name: name)
                transport = draft.server.transport; command = draft.server.command
                arguments = draft.server.arguments.joined(separator: "\n"); url = draft.server.url
                fields = draft.fields
            }
            editingJSON = toJSON
        } catch { switchError = error.localizedDescription }
    }
    private func save() async -> Bool {
        if editingJSON && isExisting { return await model.updateMCPServerJSON(original.id, name: name, json: jsonText, enabled: enabled, tags: AppModel.csv(tags)) }
        return await model.saveMCPServer(formServer, fields: fields)
    }
}
