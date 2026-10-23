import SwiftUI
import SkillboxCore
import Sparkle

@main struct AgentboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateFeedDelegate: UpdateFeedDelegate
    private let updaterController: SPUStandardUpdaterController
    init() { let delegate = UpdateFeedDelegate(); updateFeedDelegate = delegate; updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) }
    var body: some Scene {
        WindowGroup { ContentView(updater: updaterController.updater) }.defaultSize(width: 1100, height: 720)
            .commands { CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: updaterController.updater) } }
    }
}
