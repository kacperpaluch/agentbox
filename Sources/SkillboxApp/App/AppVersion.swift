import SwiftUI
import SkillboxCore

enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var display: String {
        let version = short
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Wersja \(version) (\(build))"
    }
}
