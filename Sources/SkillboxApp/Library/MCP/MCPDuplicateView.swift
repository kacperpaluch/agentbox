import SwiftUI
import SkillboxCore

struct MCPDuplicateView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
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
            Text("Powstanie niezależna kopia z wszystkimi wartościami i tagami, bez przypisań do projektów.").font(.caption).foregroundStyle(.secondary)
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
