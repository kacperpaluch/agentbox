import SwiftUI
import SkillboxCore

/// The three things Agentbox can attach to a place. They were three sidebar sections doing the same
/// four operations — list, search, tag, delete — which made the sidebar look like it held three
/// unrelated features instead of one library with three kinds of entry in it.
enum LibraryKind: String, CaseIterable, Identifiable {
    case skills = "Skille", mcp = "MCP", docs = "Dokumenty", plugins = "Pluginy"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .skills: "square.grid.2x2"
        case .mcp: "network"
        case .docs: "doc.text"
        case .plugins: "puzzlepiece.extension"
        }
    }
}
