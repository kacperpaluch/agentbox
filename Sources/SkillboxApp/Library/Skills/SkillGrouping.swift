import SwiftUI
import SkillboxCore

enum SkillGrouping: String, CaseIterable, Identifiable { case repository = "Repozytorium", tag = "Tag", source = "Źródło", none = "Bez grupowania"; var id: String { rawValue } }
