import SwiftUI
import SkillboxCore

/// What `Dodaj wiele` produces: either a parent folder plus the subfolders picked from it, or —
/// when the user does not want shared settings — plain projects, exactly as before.
struct BatchProjectRequest {
    var root: ProjectRoot?
    var folders: [String] = []
    var projects: [Project] = []
    var selection = AttachmentSelection()
    /// Subfolders left unticked are an answer too, so by default they are not proposed again.
    var treatingExistingAsKnown = true
}
