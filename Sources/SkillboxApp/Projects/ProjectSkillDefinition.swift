import SwiftUI
import SkillboxCore

struct ProjectSkillDefinition: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let skill: Skill
    var body: some View {
        VStack {
            HStack { Spacer(); Button("Zamknij") { dismiss() } }.padding()
            SkillDetail(model: model, skill: skill, showsUpdates: false)
        }.sheetFrame(width: 800, height: 650)
            .task { model.selection = skill.id; await model.loadMarkdown() }
    }
}
