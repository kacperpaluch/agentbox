import SkillboxCore

/// What one skill checkbox means in a place's selection. A skill can arrive two ways — ticked on its
/// own or pulled in by a tag — and the user should not have to know which: unticking a tag-covered
/// skill records an exclusion, ticking it again takes the exclusion back. Kept out of the view so the
/// rule is tested instead of read off a checkbox.
enum SkillPick {
    /// The first selected tag that pulls the skill in, compared case-insensitively like the sync does.
    static func coveringTag(_ skill: Skill, in selection: AttachmentSelection) -> String? {
        let wanted = Set(selection.skillTags.map { $0.lowercased() })
        return skill.tags.sorted().first { wanted.contains($0.lowercased()) }
    }

    /// An exclusion wins over everything, exactly as synchronization resolves it.
    static func isIncluded(_ skill: Skill, in selection: AttachmentSelection) -> Bool {
        guard !selection.excludedSkillIDs.contains(skill.id) else { return false }
        return selection.skillIDs.contains(skill.id) || coveringTag(skill, in: selection) != nil
    }

    static func setting(_ skill: Skill, included: Bool, in selection: AttachmentSelection) -> AttachmentSelection {
        var result = selection
        let covered = coveringTag(skill, in: selection) != nil
        result.skillIDs.removeAll { $0 == skill.id }
        result.excludedSkillIDs.removeAll { $0 == skill.id }
        if included, !covered { result.skillIDs.append(skill.id) }
        if !included, covered { result.excludedSkillIDs.append(skill.id) }
        result.skillIDs.sort(); result.excludedSkillIDs.sort()
        return result
    }
}
