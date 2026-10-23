import SwiftUI
import SkillboxCore

/// Shared by all three panes: does this entry match what the user typed and the tag they picked?
func libraryMatches(name: String, id: String, tags: [String], search: String, selectedTag: String) -> Bool {
    let tagOK = selectedTag.isEmpty || tags.contains { $0.caseInsensitiveCompare(selectedTag) == .orderedSame }
    guard tagOK else { return false }
    guard !search.isEmpty else { return true }
    return name.localizedStandardContains(search)
        || id.localizedStandardContains(search)
        || tags.contains { $0.localizedStandardContains(search) }
}
