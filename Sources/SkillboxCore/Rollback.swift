import Foundation

/// Collects what a rollback could not put back, so the failure is reported instead of swallowed.
///
/// Undoing a half-finished write is the last line of defence, and for a long time each of the six
/// places that did it wrote its own `try?` around the restore — which meant that when the rollback
/// itself failed, the user was told the operation had been undone while their files sat in an
/// in-between state. Twice a review found it; a shared type makes the rule one thing to get right
/// rather than six.
struct RollbackReport {
    private(set) var failures: [String] = []

    /// Attempts one restoring step, remembering the reason if it does not work.
    mutating func attempt(_ what: String, _ action: () throws -> Void) {
        do { try action() } catch { failures.append("\(what): \(error.localizedDescription)") }
    }

    var succeeded: Bool { failures.isEmpty }

    /// The error to report: the original one when everything was put back, or one naming both the
    /// original failure and what could not be restored. `keeping` is the copy that must survive for
    /// the user to have anything to recover from — it belongs in the message only if it is really
    /// left on disk.
    func error(after original: Error, keeping path: String? = nil) -> Error {
        guard !succeeded else { return original }
        var text = "\(original.localizedDescription) — a cofanie zmian też się nie powiodło: \(failures.joined(separator: "; "))"
        if let path { text += ". Kopia sprzed zmiany została zachowana w \(path)" }
        return SkillboxError.commandFailed(text)
    }
}

/// A private, on-disk copy made before touching any file. Unlike an array of Data, it survives
/// a failed rollback. Used by metadata writes, snapshot recovery and Claude settings together.
struct FileRollback {
    let directory: URL
    private let entries: [(target: URL, saved: URL?)]

    init(files: [URL]) throws {
        let fm = FileManager.default
        // Read every original first; an unreadable file is not a missing file.
        let originals = try files.map { file in
            (file, fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil)
        }
        directory = SkillboxService.scratchDirectory()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copies: [(target: URL, saved: URL?)] = []
        do {
            for (index, original) in originals.enumerated() {
                let saved = directory.appending(path: "\(index)-\(original.0.lastPathComponent)")
                if let data = original.1 {
                    guard fm.createFile(atPath: saved.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                        throw SkillboxError.commandFailed("nie można utworzyć kopii \(original.0.lastPathComponent)")
                    }
                }
                copies.append((original.0, original.1 == nil ? nil : saved))
            }
            let mapping = copies.map { ["target": $0.target.path, "copy": $0.saved?.lastPathComponent ?? ""] }
            let data = try JSONSerialization.data(withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys])
            guard fm.createFile(atPath: directory.appending(path: "restore.json").path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw SkillboxError.commandFailed("nie można zapisać opisu kopii ratunkowej")
            }
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        entries = copies
    }

    func perform(_ operation: () throws -> Void) throws {
        let fm = FileManager.default
        var keep = false
        defer { if !keep { try? fm.removeItem(at: directory) } }
        do { try operation() } catch {
            var report = RollbackReport()
            for entry in entries.reversed() {
                report.attempt(entry.target.path) {
                    if let saved = entry.saved {
                        try SkillboxStore.writeData(try Data(contentsOf: saved), to: entry.target)
                    } else if fm.fileExists(atPath: entry.target.path) {
                        // Never recursively remove something another writer put in our way.
                        let type = try fm.attributesOfItem(atPath: entry.target.path)[.type] as? FileAttributeType
                        guard type != .typeDirectory else { throw SkillboxError.unsafePath(entry.target.path) }
                        try fm.removeItem(at: entry.target)
                    }
                }
            }
            keep = !report.succeeded
            throw report.error(after: error, keeping: keep ? directory.path : nil)
        }
    }
}
