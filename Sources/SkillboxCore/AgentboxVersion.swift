import Foundation

/// The version the `agentbox` executable reports. It lives in `Agentbox.app/Contents/Helpers`, so
/// the app's own `Info.plist` one level up is the only version there is — no second copy to keep
/// in step with it. Resolved through symlinks, because the installed command is a link to it.
public enum AgentboxVersion {
    public static func describe(executable: URL?) -> String {
        guard let executable else { return "agentbox (wersja nieznana)" }
        let plist = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            // Run straight from `.build` (`swift run agentbox`): there is no bundle around it.
            return "agentbox (wersja deweloperska, spoza Agentbox.app)"
        }
        let build = info["CFBundleVersion"] as? String
        return "agentbox \(version)" + (build.map { " (\($0))" } ?? "")
    }
}
