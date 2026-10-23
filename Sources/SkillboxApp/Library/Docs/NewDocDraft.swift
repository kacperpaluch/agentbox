import SwiftUI
import SkillboxCore

/// A document written straight into Agentbox, with no folder or repository behind it — the document
/// counterpart of `NewSkillDraft`.
struct NewDocDraft {
    var id = ""
    var name = ""
    var content = ""
    var tags: [String] = []
}
