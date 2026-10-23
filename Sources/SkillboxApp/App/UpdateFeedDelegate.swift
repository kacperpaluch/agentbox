import SwiftUI
import SkillboxCore
import Sparkle

@MainActor final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "cacheBust" }
        items.append(URLQueryItem(name: "cacheBust", value: String(Int(Date.now.timeIntervalSince1970))))
        components.queryItems = items
        return components.url?.absoluteString
    }
}
