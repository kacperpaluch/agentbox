import SwiftUI
import SkillboxCore

extension MCPServer {
    /// What a list row can say about how the server starts without showing a value: the command
    /// and the first argument that is not an option (usually the package), or only the host of a
    /// URL. Other arguments, query strings and paths can carry tokens, so they stay in the editor.
    var launchSummary: String {
        switch transport {
        case .stdio:
            let package = arguments.first { !$0.hasPrefix("-") && !$0.contains("=") }
            return [URL(fileURLWithPath: command).lastPathComponent, package].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        default:
            return URLComponents(string: url)?.host ?? "adres URL"
        }
    }
}
