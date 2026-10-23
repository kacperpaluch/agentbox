import SwiftUI
import SkillboxCore

/// A skill written or pasted straight into Agentbox, with no folder on disk and no repository.
struct NewSkillDraft {
    var id = ""
    var name = ""
    var description = ""
    var content = ""
    var tags: [String] = []
    /// Scripts and other resources copied in next to `SKILL.md`.
    var attachments: [URL] = []
}
