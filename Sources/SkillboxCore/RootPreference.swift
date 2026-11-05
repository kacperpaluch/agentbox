import Foundation

public enum AgentboxRootPreference {
    /// `nil` when no folder was chosen. A file that exists but cannot be read throws: falling back
    /// to the default folder would quietly open a different library than the one the user chose.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL? {
        let file = home.appending(path: ".config/agentbox/root")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : URL(fileURLWithPath: text)
    }

    public static func save(_ root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = home.appending(path: ".config/agentbox/root")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (root.standardizedFileURL.path + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
