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

    /// The second client fails; the first one, already written, must come back as it was.
    func testFailingClientRollsBackTheClientsAlreadyWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let home = root.appending(path: "home")
        let service = try SkillboxService(root: root.appending(path: "data"))
        for id in ["old", "new"] {
            let source = root.appending(path: "source/\(id)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try id.write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            _ = try await service.addLocal(path: source.path)
        }
        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode], skillIDs: ["old"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)
        let claude = home.appending(path: ".claude/skills")
        let before = try SkillTree.read(claude)

        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode], skillIDs: ["new"]), for: .global)
        defer { SkillboxService.injectedFailure = nil }
        SkillboxService.injectedFailure = { if $0 == "global:opencode" { throw SkillboxError.commandFailed("wymuszony błąd") } }
        await XCTAssertThrowsErrorAsync(try await service.syncGlobalSelection(home: home))
        XCTAssertEqual(try SkillTree.read(claude), before, "Claude wraca do stanu sprzed synchronizacji")
    }

    // MARK: Global document

    private func docLibrary() throws -> (SkillboxService, home: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (try SkillboxService(root: root.appending(path: "data")), home, root)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Every ticked client gets the full text in its own user-level file — Claude Code in
    /// `CLAUDE.md`, the others in `AGENTS.md` — and loses it again when the document is unpicked.
    func testGlobalDocumentReachesEveryTickedClientAndLeavesWithIt() async throws {
        let (service, home, _) = try docLibrary()
        let fm = FileManager.default
        try await service.createDoc(id: "zasady", content: "Odpowiadaj po polsku.")
        // An empty placeholder holds nothing to lose, so it is taken over instead of blocking.
        try fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try "".write(to: Tool.codex.globalDocURL(home: home), atomically: true, encoding: .utf8)
        try await service.setSelection(AttachmentSelection(tools: [.claude, .codex, .vibe], docIDs: ["zasady"]), for: .global)

        let preview = try await service.previewGlobalDocs(home: home)
        XCTAssertEqual(preview.map(\.tool), [.claude, .codex, .vibe])
        XCTAssertTrue(preview.allSatisfy { $0.changed && $0.added == ["zasady"] })
        _ = try await service.syncGlobalSelection(home: home)
        for tool in [Tool.claude, .codex, .vibe] {
            XCTAssertEqual(try text(tool.globalDocURL(home: home)), "Odpowiadaj po polsku.\n", "\(tool)")
        }
        XCTAssertEqual(Tool.claude.globalDocURL(home: home).lastPathComponent, "CLAUDE.md")
        XCTAssertFalse(fm.fileExists(atPath: Tool.opencode.globalDocURL(home: home).path), "OpenCode nie był zaznaczony")
        let settled = try await service.previewGlobalDocs(home: home)
        XCTAssertFalse(settled.contains(where: \.changed))

        try await service.saveDocContent(docID: "zasady", name: "", content: "Odpowiadaj krótko.")
        let edited = try await service.previewGlobalDocs(home: home)
        XCTAssertTrue(edited.allSatisfy(\.updated), "\(edited)")
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertEqual(try text(Tool.vibe.globalDocURL(home: home)), "Odpowiadaj krótko.\n")

        try await service.setSelection(AttachmentSelection(tools: [.claude, .codex, .vibe]), for: .global)
        let unpicked = try await service.previewGlobalDocs(home: home)
        XCTAssertTrue(unpicked.allSatisfy { $0.removed == ["zasady"] })
        _ = try await service.syncGlobalSelection(home: home)
        for tool in [Tool.claude, .codex, .vibe] {
            let file = tool.globalDocURL(home: home)
            XCTAssertFalse(fm.fileExists(atPath: file.path), "\(tool)")
            XCTAssertFalse(fm.fileExists(atPath: file.deletingLastPathComponent().appending(path: ".skillbox").path), "\(tool): manifest znika razem z plikiem")
        }
        let gone = try await service.previewGlobalDocs(home: home)
        XCTAssertTrue(gone.isEmpty, "bez dokumentu i bez śladów nic nie jest czytane")
    }

    /// Unticking a client takes back only the file Agentbox wrote for it.
    func testUntickedClientLosesItsDocument() async throws {
        let (service, home, _) = try docLibrary()
        try await service.createDoc(id: "zasady", content: "tekst")
        try await service.setSelection(AttachmentSelection(tools: [.claude, .opencode], docIDs: ["zasady"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)
        try await service.setSelection(AttachmentSelection(tools: [.claude], docIDs: ["zasady"]), for: .global)

        let preview = try await service.previewGlobalDocs(home: home)
        XCTAssertEqual(preview.first { $0.tool == .opencode }?.removed, ["zasady"])
        _ = try await service.syncGlobalSelection(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Tool.opencode.globalDocURL(home: home).path))
        XCTAssertEqual(try text(Tool.claude.globalDocURL(home: home)), "tekst\n")
    }

    /// A `CLAUDE.md` the user wrote is not Agentbox's to replace, and the conflict is found before
    /// anything is written — the skills of the same run stay out too.
    func testOwnGlobalInstructionsStopTheWholeRun() async throws {
        let (service, home, root) = try docLibrary()
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: source.path)
        try await service.createDoc(id: "zasady", content: "tekst")
        let own = Tool.claude.globalDocURL(home: home)
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "moje własne".write(to: own, atomically: true, encoding: .utf8)
        try await service.setSelection(AttachmentSelection(tools: [.claude], skillIDs: ["notes"], docIDs: ["zasady"]), for: .global)

        await XCTAssertThrowsErrorAsync(try await service.syncGlobalSelection(home: home))
        XCTAssertEqual(try text(own), "moje własne")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/notes").path))
    }

    /// The last document write fails: skills and the documents written before it come back.
    func testFailingDocumentRollsBackSkillsAndEarlierDocuments() async throws {
        let (service, home, root) = try docLibrary()
        let source = root.appending(path: "source/notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "skill".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: source.path)
        try await service.createDoc(id: "stary", content: "stary")
        try await service.createDoc(id: "nowy", content: "nowy")
        try await service.setSelection(AttachmentSelection(tools: [.claude, .vibe], docIDs: ["stary"]), for: .global)
        _ = try await service.syncGlobalSelection(home: home)

        try await service.setSelection(AttachmentSelection(tools: [.claude, .vibe], skillIDs: ["notes"], docIDs: ["nowy"]), for: .global)
        defer { SkillboxService.injectedFailure = nil }
        SkillboxService.injectedFailure = { if $0 == "global-doc:vibe" { throw SkillboxError.commandFailed("wymuszony błąd") } }
        await XCTAssertThrowsErrorAsync(try await service.syncGlobalSelection(home: home))
        SkillboxService.injectedFailure = nil

        XCTAssertEqual(try text(Tool.claude.globalDocURL(home: home)), "stary\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/notes").path))
        let again = try await service.previewGlobalDocs(home: home)
        XCTAssertTrue(again.allSatisfy { $0.added == ["nowy"] && $0.removed == ["stary"] }, "manifesty też wróciły: \(again)")
    }

    /// Two documents matching the Mac's tags is a conflict, as it is in a project.
    func testTwoDocumentsMatchingTheMacIsAConflict() async throws {
        let (service, home, _) = try docLibrary()
        try await service.createDoc(id: "a", tags: ["mac"], content: "a")
        try await service.createDoc(id: "b", tags: ["mac"], content: "b")
        try await service.setSelection(AttachmentSelection(tools: [.claude], docTags: ["mac"]), for: .global)
        await XCTAssertThrowsErrorAsync(try await service.previewGlobalDocs(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Tool.claude.globalDocURL(home: home).path))
    }
}
