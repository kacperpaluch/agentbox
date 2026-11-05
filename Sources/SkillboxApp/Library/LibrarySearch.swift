import SwiftUI
import SkillboxCore

/// Shared by all three panes: does this entry match what the user typed and the tag they picked?
/// `content` is what the entry says — a skill's `SKILL.md`, a document's text — so a skill whose
/// name nobody remembers is still found by what it is about.
func libraryMatches(name: String, id: String, tags: [String], content: String? = nil, search: String, selectedTag: String) -> Bool {
    let tagOK = selectedTag.isEmpty || tags.contains { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }
    guard tagOK else { return false }
    guard !search.isEmpty else { return true }
    return libraryNameMatches(name: name, id: id, tags: tags, search: search) || content?.localizedStandardContains(search) == true
}

/// Whether the name, id or a tag matches — the rows say "w treści" when only the content did.
func libraryNameMatches(name: String, id: String, tags: [String], search: String) -> Bool {
    name.localizedStandardContains(search) || id.localizedStandardContains(search) || tags.contains { $0.localizedStandardContains(search) }
}
