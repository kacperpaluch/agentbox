import SwiftUI
import Combine
import SkillboxCore
import Sparkle

// Stays an ObservableObject: it mirrors Sparkle's KVO properties through Combine publishers.
@MainActor final class UpdateSettingsModel: ObservableObject {
    @Published var canCheckForUpdates: Bool
    @Published var automaticallyChecks: Bool
    @Published var automaticallyDownloads: Bool
    private let updater: SPUUpdater
    private var cancellables = Set<AnyCancellable>()

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyDownloads = $0 }.store(in: &cancellables)
    }

    func setAutomaticallyChecks(_ value: Bool) { updater.automaticallyChecksForUpdates = value }
    func setAutomaticallyDownloads(_ value: Bool) { updater.automaticallyDownloadsUpdates = value }
    func check() { updater.checkForUpdates() }
}
