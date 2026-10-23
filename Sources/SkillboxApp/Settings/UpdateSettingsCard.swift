import SwiftUI
import SkillboxCore
import Sparkle

struct UpdateSettingsCard: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { GroupBox("Aktualizacje Agentbox") { VStack(alignment: .leading, spacing: 10) {
        Toggle("Automatycznie sprawdzaj aktualizacje", isOn: Binding(
            get: { model.automaticallyChecks },
            set: { value in model.setAutomaticallyChecks(value) }
        ))
        Toggle("Automatycznie pobieraj i instaluj", isOn: Binding(
            get: { model.automaticallyDownloads },
            set: { value in model.setAutomaticallyDownloads(value) }
        )).disabled(!model.automaticallyChecks)
        HStack { Text(AppVersion.display).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Sprawdź teraz") { model.check() }.disabled(!model.canCheckForUpdates) }
        Text("Aktualizacje są pobierane z GitHub Releases i weryfikowane podpisem EdDSA przed instalacją.").font(.caption).foregroundStyle(.secondary)
    }.padding(8) } }
}
