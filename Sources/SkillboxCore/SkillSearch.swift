import Foundation

/// The text of one `SKILL.md`, kept for searching the library by what a skill says.
public struct SkillSearchText: Sendable, Equatable {
    public let modified: Date
    public let text: String
    public init(modified: Date, text: String) { self.modified = modified; self.text = text }
}

extension SkillboxService {
    /// `SKILL.md` texts keyed by skill id. A file whose modification date is unchanged keeps the
    /// text from `cache`, so a reload costs one `stat` per skill instead of reading every file.
    ///
    /// A file that cannot be read is left out: search then finds the skill by name and tags only.
    /// That is safe here because nothing is ever written from this text — the editor reads the
    /// file through `skillMarkdown`, which refuses an unreadable one.
    public func skillSearchTexts(reusing cache: [String: SkillSearchText] = [:]) async throws -> [String: SkillSearchText] {
        let library = await store.skillsDirectory
        var result: [String: SkillSearchText] = [:]
        for skill in try await store.catalog().skills {
            let file = library.appending(path: skill.id).appending(path: "SKILL.md")
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if let cached = cache[skill.id], cached.modified == modified { result[skill.id] = cached; continue }
            if let text = try? String(contentsOf: file, encoding: .utf8) { result[skill.id] = SkillSearchText(modified: modified, text: text) }
        }
        return result
    }
}
