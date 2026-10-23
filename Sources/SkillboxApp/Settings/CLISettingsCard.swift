import SwiftUI
import SkillboxCore

struct CLISettingsCard: View {
    @State private var model = CLISettingsModel()
    var body: some View { GroupBox("Wiersz poleceń (CLI)") { VStack(alignment: .leading, spacing: 10) {
        Text(model.status).font(.caption).foregroundStyle(model.installed ? .green : .secondary).textSelection(.enabled)
        HStack { Text("Po instalacji użyj np. `agentbox project list` w nowym oknie Terminala.").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.installed ? "Zainstalowano" : "Zainstaluj CLI") { model.install() }.disabled(model.installed) }
    }.padding(8) }.onAppear { model.refresh() } }
}
