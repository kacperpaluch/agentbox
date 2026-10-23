import SkillboxCore

/// A skill as it appears in one group of the list.
struct SkillGroupItem: Identifiable {
    let groupID: String
    let skill: Skill
    var id: String { "\(groupID)/\(skill.id)" }
}
