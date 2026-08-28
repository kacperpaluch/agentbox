import XCTest
@testable import SkillboxCore

final class GlobalSyncTests: AgentboxTestCase {
    func testGlobalSelectionIsPersistedAndSynchronizedIntoUserSkillDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/notes"); let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "globalny".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        try await service.setTags(skillID: "notes", tags: ["wszedzie"])
        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode], skillTags: ["wszedzie"]), for: .global)

        let preview = try await service.previewGlobalSync(home: home)
        XCTAssertEqual(preview.map(\.added), [["notes"], ["notes"]])
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".claude/skills/notes/SKILL.md"), encoding: .utf8), "globalny")
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".config/opencode/skills/notes/SKILL.md"), encoding: .utf8), "globalny")
        // Codex was never selected, so its directory must stay untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".codex/skills").path))

        let reloaded = try await service.selection(for: .global)
        XCTAssertEqual(reloaded.tools, [.claude, .opencode])
        XCTAssertEqual(reloaded.skillTags, ["wszedzie"])

        // Deselecting removes the managed copy again.
        try await service.setSelection(AttachmentSelection(tools: [.claude]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/notes").path))
    }
}
