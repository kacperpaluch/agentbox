import SkillboxCore

/// One group in the skills list. Its id lives in its own namespace: a group named like the only skill
/// inside it ("miodkuj" holding "miodkuj") shared one identity with that row in the outline, so the
/// disclosure arrow collapsed the skill instead of the group.
struct SkillGroup: Identifiable {
    let name: String
    let skills: [Skill]
    var id: String { "group/\(name)" }
    /// A skill can sit in several tag groups at once; each appearance is its own row.
    var items: [SkillGroupItem] { skills.map { SkillGroupItem(groupID: id, skill: $0) } }
}
