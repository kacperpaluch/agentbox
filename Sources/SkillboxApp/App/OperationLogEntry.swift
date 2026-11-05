import SwiftUI
import SkillboxCore

struct OperationLogEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case success, error }
    var id = UUID(); var date = Date.now; let kind: Kind; let text: String
    /// What "Kopiuj" puts on the clipboard: enough for a bug report or a note on its own.
    var copyText: String { "\(date.formatted(date: .numeric, time: .standard)) — \(kind == .error ? "błąd" : "sukces"): \(text)" }
}

/// The operation history on disk, so yesterday's error can still be read today.
///
/// It lives outside the library on purpose: the library is watched, and a log written there would
/// wake the watcher, whose reload can record an entry, which writes the log again. The texts can
/// quote configuration, so the file is 0600 from its first byte and its folder 0700 — the same rule
/// as every other copy of user values.
struct OperationLogFile {
    let url: URL

    static var standard: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Agentbox/operation-log.json")
    }

    /// The saved entries. A file that cannot be decoded is moved aside, not overwritten, and the
    /// returned message says where it went.
    func load() -> (entries: [OperationLogEntry], problem: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return ([], nil) }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode([OperationLogEntry].self, from: Data(contentsOf: url)), nil)
        } catch {
            let aside = url.appendingPathExtension("damaged-\(Int(Date.now.timeIntervalSince1970))")
            let moved = (try? fm.moveItem(at: url, to: aside)) != nil
            return ([], "Nie można odczytać historii operacji (\(error.localizedDescription)); " + (moved ? "zachowano ją jako \(aside.path)" : "plik został w \(url.path)"))
        }
    }

    func save(_ entries: [OperationLogEntry]) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted]
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: try encoder.encode(entries), attributes: [.posixPermissions: 0o600]) else {
            throw SkillboxError.commandFailed("nie można zapisać historii operacji w \(directory.path)")
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) } else { try fm.moveItem(at: temporary, to: url) }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}
