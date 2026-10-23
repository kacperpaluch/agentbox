import SwiftUI
import SkillboxCore
import Sparkle

struct CheckForUpdatesView: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { Button("Sprawdź aktualizacje…") { model.check() }.disabled(!model.canCheckForUpdates) }
}
