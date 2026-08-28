import XCTest
@testable import SkillboxCore

final class DocsTests: AgentboxTestCase {
    func testDocCreateAssignPreviewAndSyncGeneratesClaudeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "docs-project", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "# Guidelines\nDo the thing.")

        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        let preview = try await service.previewDocs(projectID: project.id)
        XCTAssertEqual(preview.count, 2)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        let claude = try XCTUnwrap(preview.first { $0.file.hasSuffix("CLAUDE.md") })
        XCTAssertEqual(agents.content, "# Guidelines\nDo the thing.\n")
        XCTAssertEqual(claude.content, "@AGENTS.md\n")
        XCTAssertEqual(agents.added, ["standard"])
        XCTAssertEqual(claude.added, ["standard"])

        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "# Guidelines\nDo the thing.\n")
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
    }
    func testDocTagAssignmentAndSwitchingSelectionReplacesContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let first = try await service.createDoc(id: "first", name: "First", tags: ["backend"], content: "one")
        let second = try await service.createDoc(id: "second", name: "Second", tags: [], content: "two")

        try await service.setDocs(projectID: project.id, docIDs: [], tags: ["Backend"])
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "one\n")

        try await service.setDocs(projectID: project.id, docIDs: [second.id], tags: [])
        let preview = try await service.previewDocs(projectID: project.id)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        XCTAssertEqual(agents.added, [second.id])
        XCTAssertEqual(agents.removed, [first.id])
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "two\n")
    }
    func testMultipleMatchingDocumentsIsAConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        _ = try await service.createDoc(id: "a", name: "A", tags: ["shared"], content: "a")
        _ = try await service.createDoc(id: "b", name: "B", tags: ["shared"], content: "b")
        try await service.setDocs(projectID: project.id, docIDs: [], tags: ["shared"])

        do { _ = try await service.previewDocs(projectID: project.id); XCTFail("Oczekiwano konfliktu") }
        catch let error as SkillboxError { XCTAssertTrue(error.localizedDescription.contains("Konflikt dokumentu")) }
    }
    func testUnmanagedAgentsFileWithDifferentContentBlocksDocSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "hand written".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "d", name: "D", tags: [], content: "generated")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        do { _ = try await service.previewDocs(projectID: project.id); XCTFail("Oczekiwano konfliktu") }
        catch let error as SkillboxError { XCTAssertTrue(error.localizedDescription.contains("Konflikt dokumentu")) }
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "hand written")
    }
    /// The one exception to the conflict above: a hand-written file that already holds byte-identical
    /// text is adopted silently, the same leniency `directoryMatches` gives skills.
    func testUnmanagedFileByteIdenticalToDocumentIsAdoptedWithoutConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "shared text\n".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "d", name: "D", tags: [], content: "shared text")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
    }
    /// Nothing selected and nothing previously managed must leave a foreign file completely alone —
    /// no conflict, no write, no manifest.
    func testProjectWithNoDocumentSelectedLeavesExistingAgentsFileUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "totally unrelated content".write(to: projectURL.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])

        let preview = try await service.previewDocs(projectID: project.id)
        let agents = try XCTUnwrap(preview.first { $0.file.hasSuffix("AGENTS.md") })
        XCTAssertEqual(agents.content, "totally unrelated content")
        _ = try await service.syncDocs(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "totally unrelated content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
    }
    func testUnsyncRemovesManagedDocumentFilesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "hello")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appending(path: "CLAUDE.md").path))

        let removed = try await service.unsyncProject(id: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "AGENTS.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: "CLAUDE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appending(path: ".skillbox/docs-manifest.json").path))
        XCTAssertTrue(removed.contains { $0.contains("standard") }, "\(removed)")
    }
    /// The transaction's rollback copy is taken before any write, across skills, MCP and docs alike —
    /// a doc-level write failure must undo a skill file the same transaction already wrote.
    func testProjectTransactionRollsBackSkillsWhenDocWriteFailsLater() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source/demo")
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "version one".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: source.path)
        let project = try await service.addProject(name: "rollback-doc", path: projectURL.path, tools: [.claude])
        try await service.configureProject(id: project.id, skillIDs: ["demo"], tags: [])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "first version")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertEqual(try String(contentsOf: projectURL.appending(path: "AGENTS.md"), encoding: .utf8), "first version\n")

        // A second change, blocked from ever landing: the skill gets a new version, and AGENTS.md is
        // replaced by a directory so the write that would follow it fails.
        try "version two".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.update(skillID: "demo")
        try FileManager.default.removeItem(at: projectURL.appending(path: "AGENTS.md"))
        try FileManager.default.createDirectory(at: projectURL.appending(path: "AGENTS.md"), withIntermediateDirectories: true)

        do { _ = try await service.syncProjectTransaction(projectID: project.id); XCTFail("Oczekiwano błędu zapisu") } catch {}
        let restoredSkill = try String(contentsOf: projectURL.appending(path: ".claude/skills/demo/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(restoredSkill, "version one")
    }
    func testDeletingDocumentRemovesItFromProjectAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectURL = root.appending(path: "project")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let project = try await service.addProject(name: "p", path: projectURL.path, tools: [.claude])
        let doc = try await service.createDoc(id: "standard", name: "Standard", tags: [], content: "text")
        try await service.setDocs(projectID: project.id, docIDs: [doc.id], tags: [])

        try await service.deleteDoc(id: doc.id)
        let config = try await service.docsConfiguration()
        XCTAssertTrue(config.docs.isEmpty)
        let afterDelete = try await service.storedSelection(id: project.id)
        XCTAssertEqual(afterDelete.docIDs, [])
        let preview = try await service.previewDocs(projectID: project.id)
        XCTAssertTrue(preview.allSatisfy { $0.content.isEmpty })
    }
    func testAddDocTagsMergesWithExistingAndNormalizesCase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root)
        let one = try await service.createDoc(id: "one", name: "One", tags: ["seo"], content: "a")
        let two = try await service.createDoc(id: "two", name: "Two", tags: [], content: "b")
        try await service.addDocTags(docIDs: [one.id, two.id], tags: ["Audit", "seo"])
        let docs = try await service.docsConfiguration().docs
        XCTAssertEqual(docs.first { $0.id == one.id }?.tags, ["audit", "seo"])
        XCTAssertEqual(docs.first { $0.id == two.id }?.tags, ["audit", "seo"])
    }
    /// `docs.json` rides along with every other library file: it must survive a full local backup
    /// and restore round trip, and an older backup made before documents existed must still restore.
    func testFullLocalBackupRestoresDocumentsAndOlderBackupsWithoutDocsJSONStillRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.createDoc(id: "standard", name: "Standard", tags: ["backend"], content: "hello")
        let backup = try await service.createFullBackup(applicationVersion: "test")

        _ = try await service.createDoc(id: "extra", name: "Extra", tags: [], content: "world")
        try await service.restoreFullBackup(named: backup.name)
        let restored = try await service.docsConfiguration().docs
        XCTAssertEqual(restored.map(\.id), ["standard"])

        // Simulate a backup made before documents existed: remove docs.json from the package, then
        // add a document that only exists on disk right now — a legacy restore must leave it alone
        // instead of wiping it because the old package has nothing to say about it.
        let legacyPackage = root.appending(path: "data/backups/full/\(backup.name)/docs.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPackage.path))
        try FileManager.default.removeItem(at: legacyPackage)
        _ = try await service.createDoc(id: "current-only", name: "Current only", tags: [], content: "kept")
        try await service.restoreFullBackup(named: backup.name)
        let afterLegacyRestore = try await service.docsConfiguration().docs
        XCTAssertEqual(Set(afterLegacyRestore.map(\.id)), ["standard", "current-only"], "docs.json spoza backupu powinno przetrwać restore starszego pakietu bez docs.json")
    }
}
