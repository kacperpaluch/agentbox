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

    /// A group header has no tag, so the list put its row id (or nothing) into the selection and the
    /// detail emptied — with the list then shrinking into the middle of the window.
    func testSelectingAGroupHeaderKeepsTheOpenSkill() async throws {
        UserDefaults.standard.removeObject(forKey: "AgentboxCollapsedSkillGroups")
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root.appending(path: "library"), startsAutomatically: false)
        await model.reload()
        model.skills = ["alpha", "beta"].map { Skill(id: $0, name: $0, source: SkillSource(kind: .git, location: "https://github.com/example/repo-\($0)")) }
        model.selection = "alpha"
        let host = NSHostingView(rootView: SkillsPane(model: model, showGit: .constant(false), search: "", selectedTag: "").frame(width: 1000, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        let outline = try XCTUnwrap(Self.outline(in: host))

        outline.selectRowIndexes([3], byExtendingSelection: false)   // skill "beta"
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.selection, "beta")
        outline.selectRowIndexes([2], byExtendingSelection: false)   // header of the "repo-beta" group
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.selection, "beta", "nagłówek grupy nie zamyka otwartego skilla")
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
        XCTAssertTrue(ProjectTableRow.projects(for: [ProjectTableRow.mac.id], in: entries).isEmpty, "wiersz „Ten Mac” nie oznacza żadnego projektu")
        XCTAssertFalse(([groupRow] + [a, b, c].map { ProjectTableRow(project: $0, in: work).id }).contains(ProjectTableRow.mac.id))
    }

    private static func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }
}
