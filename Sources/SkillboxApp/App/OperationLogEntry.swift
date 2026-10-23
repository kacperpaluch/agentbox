import SwiftUI
import SkillboxCore

struct OperationLogEntry: Identifiable {
    enum Kind { case success, error }
    let id = UUID(); let date = Date.now; let kind: Kind; let text: String
}
