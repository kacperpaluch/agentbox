import Foundation

public enum AgentboxRootPreference {
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let file = home.appending(path: ".config/agentbox/root")
        guard let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return URL(fileURLWithPath: text)
    }

    public static func save(_ root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = home.appending(path: ".config/agentbox/root")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (root.standardizedFileURL.path + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
