import SwiftUI
import SkillboxCore

enum SkillSort: String, CaseIterable, Identifiable { case name = "Nazwa", newest = "Najnowsze", source = "Źródło"; var id: String { rawValue } }
