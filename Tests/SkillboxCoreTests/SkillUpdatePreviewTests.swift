import XCTest
@testable import SkillboxCore

final class SkillUpdatePreviewTests: AgentboxTestCase {
    private var root: URL!
    private var repo: URL { root.appending(path: "repo") }
    private var library: URL { root.appending(path: "library") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for name in ["one", "two"] {
            try FileManager.default.createDirectory(at: repo.appending(path: name), withIntermediateDirectories: true)
            try write("\(name)/SKILL.md", "old \(name)")
        }
        try runGit(["init"], in: repo)
        try commit()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws { try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8) }
    private func commit() throws {
        try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "change"], in: repo)
    }
    private func imported() async throws -> SkillboxService {
        let service = try SkillboxService(root: library)
        _ = try await service.addGitCollection(url: repo.absoluteString)
        return service
    }
    private func libraryText(_ name: String) throws -> String { try String(contentsOf: library.appending(path: "skills/\(name)/SKILL.md"), encoding: .utf8) }

    func testOnlyChangedSkillIsOfferedAndAcceptanceUsesReviewedBytes() async throws {
        let service = try await imported()
        try write("one/SKILL.md", "reviewed")
        try commit()
        let plan = try await service.previewSkillUpdates()
        XCTAssertEqual(plan.updates.map(\.id), ["one"])
        XCTAssertEqual(plan.unchanged, ["two"])
        XCTAssertEqual(try libraryText("one"), "old one", "podgląd nie zapisuje biblioteki")
        let available = try await service.checkUpdates()
        XCTAssertEqual(available, ["one"])

        try write("one/SKILL.md", "new remote version after preview")
        try commit()
        _ = try await service.applySkillUpdates(plan.updates)

        XCTAssertEqual(try libraryText("one"), "reviewed")
        let saved = try await service.listSkills().first { $0.id == "one" }
        XCTAssertEqual(saved?.source.revision, plan.updates.first?.revision)
        let backups = try await service.fullBackups()
        let backup = try XCTUnwrap(backups.first)
        let backedUp = library.appending(path: "backups/full/\(backup.name)/skills/one/SKILL.md")
        XCTAssertEqual(try String(contentsOf: backedUp, encoding: .utf8), "old one", "backup jest sprzed aktualizacji")
    }

    func testUnrelatedCommitDoesNotOfferUpdatesOrCreateBackup() async throws {
        let service = try await imported()
        try write("README.md", "not part of either skill")
        try commit()
        let plan = try await service.previewSkillUpdates()
        XCTAssertTrue(plan.updates.isEmpty)
        _ = try await service.applySkillUpdates(plan.updates)
        let backups = try await service.fullBackups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testResourcesBinaryDeletionsPermissionsAndLinksAreReviewedAndPreserved() async throws {
        try write("one/remove.txt", "old resource")
        try write("one/run.sh", "echo example")
        try commit()
        let service = try await imported()
        try FileManager.default.removeItem(at: repo.appending(path: "one/remove.txt"))
        let binary = Data([0, 255, 1, 2])
        try binary.write(to: repo.appending(path: "one/image.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appending(path: "one/run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: repo.appending(path: "one/link").path, withDestinationPath: "SKILL.md")
        try commit()
        let plan = try await service.previewSkillUpdates()
        let update = try XCTUnwrap(plan.updates.first)
        XCTAssertEqual(Set(update.changes.map(\.path)), ["remove.txt", "run.sh", "image.bin", "link"])
        XCTAssertNil(update.changes.first { $0.path == "image.bin" }?.newText)
        XCTAssertTrue(update.changes.first { $0.path == "run.sh" }?.note.contains("755") == true)
        _ = try await service.applySkillUpdates([update])
        let installed = library.appending(path: "skills/one")
        XCTAssertEqual(try Data(contentsOf: installed.appending(path: "image.bin")), binary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appending(path: "remove.txt").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appending(path: "run.sh").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.appending(path: "link").path), "SKILL.md")
    }

    func testStalePreviewDoesNotOverwriteEitherSkill() async throws {
        let service = try await imported()
        for name in ["one", "two"] { try write("\(name)/SKILL.md", "new \(name)") }
        try commit()
        let plan = try await service.previewSkillUpdates()
        try "edited while preview open".write(to: library.appending(path: "skills/two/SKILL.md"), atomically: true, encoding: .utf8)
        await XCTAssertThrowsErrorAsync(try await service.applySkillUpdates(plan.updates))
        XCTAssertEqual(try libraryText("one"), "old one")
        XCTAssertEqual(try libraryText("two"), "edited while preview open")
    }

    func testPermissionOnlyUpdateReachesProjectDuringSynchronization() async throws {
        try write("one/run.sh", "echo example")
        try commit()
        let service = try await imported()
        let folder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await service.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["one"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let script = folder.appending(path: ".claude/skills/one/run.sh")
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: script.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appending(path: "one/run.sh").path)
        try commit()
        let plan = try await service.previewSkillUpdates()
        _ = try await service.applySkillUpdates(plan.updates)
        _ = try await service.syncProjectTransaction(projectID: project.id)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        let report = try await service.projectConfiguration(projectID: project.id)
        XCTAssertEqual(report.items.first { $0.reference == .skill("one") }?.state, "Aktualny")
    }

    func testFailedCatalogSaveRollsBackAllReplacedSkills() async throws {
        let service = try await imported()
        let originalCatalog = try Data(contentsOf: library.appending(path: "catalog.json"))
        for name in ["one", "two"] { try write("\(name)/SKILL.md", "new \(name)") }
        try commit()
        let plan = try await service.previewSkillUpdates()
        let snapshots = library.appending(path: ".agentbox-snapshots")
        if FileManager.default.fileExists(atPath: snapshots.path) { try FileManager.default.removeItem(at: snapshots) }
        try Data("obstruction".utf8).write(to: snapshots)
        await XCTAssertThrowsErrorAsync(try await service.applySkillUpdates(plan.updates))
        XCTAssertEqual(try libraryText("one"), "old one")
        XCTAssertEqual(try libraryText("two"), "old two")
        XCTAssertEqual(try Data(contentsOf: library.appending(path: "catalog.json")), originalCatalog)
    }

    func testUnsafeSourceLinkFailsItsSkillWithoutReadingOutside() async throws {
        let service = try await imported()
        try FileManager.default.createSymbolicLink(atPath: repo.appending(path: "one/outside").path, withDestinationPath: "../../outside")
        try commit()
        let plan = try await service.previewSkillUpdates()
        XCTAssertEqual(plan.failed.map(\.id), ["one"])
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertEqual(try libraryText("one"), "old one")
    }

    func testOnlyChosenUpdatesAreAppliedAndCLIHasReadOnlyPreview() async throws {
        let service = try await imported()
        for name in ["one", "two"] { try write("\(name)/SKILL.md", "new \(name)") }
        try commit()
        let output = try await AgentboxCommand.run(["update", "--all", "--dry-run"], service: service)
        XCTAssertTrue(output.contains { $0.contains("+ new one") })
        XCTAssertEqual(try libraryText("one"), "old one")
        let plan = try await service.previewSkillUpdates()
        _ = try await service.applySkillUpdates(plan.updates.filter { $0.id == "two" })
        XCTAssertEqual(try libraryText("one"), "old one")
        XCTAssertEqual(try libraryText("two"), "new two")
    }
}
