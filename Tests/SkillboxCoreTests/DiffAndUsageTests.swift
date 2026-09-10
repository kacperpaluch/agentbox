import XCTest
@testable import SkillboxCore

/// The two questions a fleet of projects makes hard to answer: what exactly will change in this
/// file, and who else uses this thing.
final class DiffAndUsageTests: AgentboxTestCase {

    // MARK: Diff

    func testDiffMarksOnlyWhatActuallyChanges() {
        let lines = TextDiff.lines(old: "a\nb\nc\n", new: "a\nB\nc\n")
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["b"])
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["B"])
        XCTAssertEqual(lines.filter { $0.kind == .same }.map(\.text), ["a", "c", ""])
    }

    func testANewFileIsAllAdditionsAndARemovedFileIsAllRemovals() {
        XCTAssertTrue(TextDiff.lines(old: "", new: "a\nb").allSatisfy { $0.kind == .added })
        XCTAssertTrue(TextDiff.lines(old: "a\nb", new: "").allSatisfy { $0.kind == .removed })
        XCTAssertTrue(TextDiff.lines(old: "a\nb", new: "a\nb").isEmpty, "brak zmian to pusty wynik, a nie ściana tekstu")
    }

    /// An `AGENTS.md` is mostly text nobody touched. Showing all of it to point at one changed line
    /// is how a diff view becomes useless.
    func testUntouchedMiddleOfALongFileIsCollapsed() {
        let old = (1...40).map { "linia \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "linia 20", with: "linia 20 poprawiona")

        let lines = TextDiff.lines(old: old, new: new, context: 2)

        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["linia 20 poprawiona"])
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["linia 20"])
        XCTAssertEqual(lines.filter { $0.kind == .same }.count, 4, "po dwie linie kontekstu z każdej strony")
        XCTAssertEqual(lines.filter { $0.kind == .gap }.count, 2, "reszta pliku zwinięta w dwa znaczniki")
        XCTAssertTrue(lines.contains { $0.kind == .gap && $0.text.contains("17") })
    }

    func testDiffAgainstAFileThatDoesNotExistYet() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "AGENTS.md")

        XCTAssertTrue(TextDiff.lines(file: file.path, content: "nowa treść").allSatisfy { $0.kind == .added })

        try "nowa treść".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(TextDiff.lines(file: file.path, content: "nowa treść").isEmpty)
    }

    // MARK: Usage

    /// The list has to be the *effective* one: a project inheriting a parent folder, or picking the
    /// skill up through a tag, never names it in its own record.
    func testSkillUsageFollowsTagsInheritanceAndExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        for id in ["notes", "review"] {
            let source = root.appending(path: "source/\(id)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: \(id)\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            _ = try await service.addLocal(path: source.path)
        }
        try await service.setTags(skillID: "review", tags: ["wspólne"])
        let folder = root.appending(path: "group")
        for name in ["a", "b"] { try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true) }
        _ = try await service.addProjectRoot(
            ProjectRoot(name: "group", path: folder.path, tools: [.claude]),
            folders: [folder.appending(path: "a").path, folder.appending(path: "b").path],
            selection: AttachmentSelection(tools: [.claude], skillIDs: ["notes"], skillTags: ["wspólne"])
        )
        let standalone = root.appending(path: "solo")
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        _ = try await service.addProject(Project(name: "solo", path: standalone.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["notes"]))

        let notes = try await service.usage(ofSkill: "notes")
        XCTAssertEqual(notes.projects, ["a", "b", "solo"], "projekty dziedziczące folder też go dostają")
        XCTAssertEqual(notes.roots, ["group"])
        XCTAssertFalse(notes.global)
        XCTAssertEqual(notes.summary, "3 projekty, folder nadrzędny: group")

        // Picked up only through a tag, and never named by any project.
        let review = try await service.usage(ofSkill: "review")
        XCTAssertEqual(review.projects, ["a", "b"])

        // A project may opt out of what its folder assigns; it must then leave the list.
        let allStored = try await service.storedProjects()
        var stored = try XCTUnwrap(allStored.first { $0.name == "a" })
        stored.overridesRoot = true
        try await service.updateProject(stored, selection: AttachmentSelection(tools: [.claude], excludedSkillIDs: ["notes"]))
        let afterExclusion = try await service.usage(ofSkill: "notes")
        XCTAssertEqual(afterExclusion.projects, ["b", "solo"])
    }

    func testServerDocumentAndPluginUsageAreAnsweredTheSameWay() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let server = MCPServer(name: "context7", transport: .stdio, command: "npx")
        try await service.saveMCPServer(server)
        _ = try await service.createDoc(id: "zasady", name: "Zasady", content: "treść")
        let plugin = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(plugin)
        let folder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await service.addProject(
            Project(name: "project", path: folder.path),
            selection: AttachmentSelection(tools: [.claude], serverIDs: [server.id], docIDs: ["zasady"], claudePluginIDs: [plugin.id])
        )
        XCTAssertEqual(project.name, "project")

        let serverUsage = try await service.usage(ofServer: server.id)
        let docUsage = try await service.usage(ofDoc: "zasady")
        let pluginUsage = try await service.usage(ofPlugin: plugin.id)

        XCTAssertEqual(serverUsage.projects, ["project"])
        XCTAssertEqual(docUsage.projects, ["project"])
        XCTAssertEqual(pluginUsage.projects, ["project"])
        XCTAssertEqual(serverUsage.summary, "1 projekt")
    }

    func testNothingUsesItIsAnAnswerToo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let source = root.appending(path: "source/lonely")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: lonely\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: source.path)

        let usage = try await service.usage(ofSkill: "lonely")

        XCTAssertTrue(usage.isUnused)
        XCTAssertNil(usage.summary)
    }
}
