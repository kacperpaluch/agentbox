import SwiftUI
import SkillboxCore

/// Asks for the files and folders a skill should carry besides `SKILL.md`.
@MainActor func chooseSkillFiles() -> [URL] {
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.prompt = "Dodaj"
    return panel.runModal() == .OK ? panel.urls : []
}
