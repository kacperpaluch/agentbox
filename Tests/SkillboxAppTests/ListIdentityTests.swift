import XCTest
import SwiftUI
@testable import AgentboxApp
import SkillboxCore

/// Rows of an outline must never share an identity: a group named like the only skill inside it
/// ("miodkuj" holding "miodkuj") could not be collapsed, because the outline toggled the skill row.
@MainActor
final class ListIdentityTests: XCTestCase {
    func testAGroupNamedLikeItsOnlySkillCollapses() async throws {
        UserDefaults.standard.removeObject(forKey: "AgentboxCollapsedSkillGroups")
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root.appending(path: "library"), startsAutomatically: false)
        await model.reload()
        model.skills = [Skill(id: "miodkuj", name: "miodkuj", source: SkillSource(kind: .git, location: "https://github.com/example/miodkuj"))]
        let host = NSHostingView(rootView: SkillsPane(model: model, showGit: .constant(false), search: "", selectedTag: "").frame(width: 900, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); UserDefaults.standard.removeObject(forKey: "AgentboxCollapsedSkillGroups") }
        try await Task.sleep(for: .seconds(1))
        let outline = try XCTUnwrap(Self.outline(in: host))
        XCTAssertEqual(outline.numberOfRows, 2, "grupa i jej skill")

        // What a click on the disclosure arrow does.
        outline.collapseItem(outline.item(atRow: 0))
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(outline.numberOfRows, 1, "zwinięta grupa chowa swój skill")
    }

    func testGroupAndRowIdentitiesNeverCollide() {
        let skill = Skill(id: "miodkuj", name: "miodkuj", source: SkillSource(kind: .local, location: "/x"))
        let first = SkillGroup(name: "miodkuj", skills: [skill]), second = SkillGroup(name: "#seo", skills: [skill])
        let ids = [first.id, second.id] + first.items.map(\.id) + second.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ten sam skill w dwóch grupach to dwa różne wiersze")
        XCTAssertFalse(ids.contains(skill.id))
    }

    func testSelectingAGroupStandsForItsVisibleProjects() {
        let a = Project(name: "a", path: "/w/a"), b = Project(name: "b", path: "/w/b"), c = Project(name: "c", path: "/x/c")
        let work = ProjectGroup(path: "/w", root: nil, projects: [a, b]), other = ProjectGroup(path: "/x", root: nil, projects: [c])
        let entries = [(group: work, shown: [a, b]), (group: other, shown: [c])]
        let groupRow = ProjectTableRow(group: work).id
        XCTAssertEqual(ProjectTableRow.projects(for: [groupRow], in: entries).map(\.name), ["a", "b"])
        XCTAssertEqual(ProjectTableRow.projects(for: [groupRow, a.id.uuidString, c.id.uuidString], in: entries).map(\.name), ["a", "b", "c"], "projekt zaznaczony razem z grupą liczy się raz")
        XCTAssertNotEqual(groupRow, ProjectTableRow(project: a, in: work).id)
    }

    private static func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }
}
