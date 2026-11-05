import XCTest
@testable import SkillboxCore

/// One test per defect found in the code review of 0.39.2. Each checks the effect — the file on
/// disk, the stored record, the command's outcome — rather than the helper that produced it.
final class Review039RegressionTests: AgentboxTestCase {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func folder(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func skill(at url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\ntreść\n".write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    // 4. Pointing a project at a new folder cleaned the old one before saving the record.
    func testFailedSaveOfANewProjectFolderKeepsTheOldFolderAndRecord() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill(at: root.appending(path: "source/demo")).path)
        let old = try folder(root.appending(path: "old")), new = try folder(root.appending(path: "new"))
        let project = try await service.addProject(Project(name: "p", path: old.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let synced = old.appending(path: ".claude/skills/demo/SKILL.md")
        XCTAssertTrue(fm.fileExists(atPath: synced.path))

        let before = try await service.storedProjects()
        var moved = try XCTUnwrap(before.first)
        moved.path = new.path
        let selection = try await service.selection(for: .project(project.id))
        SkillboxService.injectedFailure = { if $0 == "unsync:commit" { throw SkillboxError.commandFailed("wymuszony błąd") } }
        defer { SkillboxService.injectedFailure = nil }
        await XCTAssertThrowsErrorAsync(try await service.updateProject(moved, selection: selection))

        XCTAssertTrue(fm.fileExists(atPath: synced.path), "nieudany zapis przywraca pliki w starym folderze")
        let afterFailure = try await service.storedProjects()
        XCTAssertEqual(afterFailure.first?.path, old.path, "rekord dalej wskazuje stary folder")

        SkillboxService.injectedFailure = nil
        try await service.updateProject(moved, selection: selection)
        XCTAssertFalse(fm.fileExists(atPath: synced.path), "udana zmiana sprząta stary folder")
        let afterSuccess = try await service.storedProjects()
        XCTAssertEqual(afterSuccess.first?.path, new.path)
    }

    // 3. A library copy that failed halfway stayed in the chosen folder.
    func testFailedLibraryCopyLeavesTheChosenFolderEmpty() async throws {
        let root = try temp()
        let library = root.appending(path: "data")
        let service = try SkillboxService(root: library)
        _ = try await service.addLocal(path: try skill(at: root.appending(path: "source/demo")).path)
        let blocked = library.appending(path: "zablokowany")
        try "x".write(to: blocked, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        let target = root.appending(path: "nowa")

        await XCTAssertThrowsErrorAsync(try await service.copyLibrary(to: target))

        let left = try fm.contentsOfDirectory(atPath: target.path).filter { $0 != ".DS_Store" }
        XCTAssertEqual(left, [], "po nieudanej kopii folder jest znów pusty, więc kolejna próba może ruszyć")
    }

    // 8. A full backup whose metadata could not be read disappeared from the list.
    func testDamagedFullBackupIsListedWithItsReason() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let backup = try await service.createFullBackup(applicationVersion: "test")
        try "{ zepsuty".write(to: root.appending(path: "data/backups/full/\(backup.name)/backup.json"), atomically: true, encoding: .utf8)

        let listed = try await service.fullBackups()
        XCTAssertEqual(listed.map(\.name), [backup.name])
        XCTAssertNotNil(listed.first?.problem)
        await XCTAssertThrowsErrorAsync(try await service.restoreFullBackup(named: backup.name))
    }

    // 6. A snapshot entry that is a symbolic link passed the check by its spelling.
    func testSnapshotThatIsASymbolicLinkIsRefused() async throws {
        let root = try temp()
        let library = root.appending(path: "data")
        let service = try SkillboxService(root: library)
        _ = try await service.addLocal(path: try skill(at: root.appending(path: "source/demo")).path)
        let outside = try folder(root.appending(path: "outside"))
        try fm.copyItem(at: library.appending(path: "catalog.json"), to: outside.appending(path: "catalog.json"))
        let snapshots = try folder(library.appending(path: ".agentbox-snapshots"))
        try fm.createSymbolicLink(at: snapshots.appending(path: "link"), withDestinationURL: outside)

        await XCTAssertThrowsErrorAsync(try await service.restoreLibrarySnapshot(named: "link"))
    }

    // LOW. An unreadable folder choice silently opened the default library instead.
    func testUnreadableRootPreferenceIsAnError() throws {
        let home = try temp()
        XCTAssertNil(try AgentboxRootPreference.load(home: home), "brak pliku to brak wyboru")
        let file = try folder(home.appending(path: ".config/agentbox")).appending(path: "root")
        try Data([0xFF, 0xFE, 0x00]).write(to: file)
        XCTAssertThrowsError(try AgentboxRootPreference.load(home: home))
    }

    // LOW. An unreadable skills folder in a project looked like "nothing to adopt".
    func testUnreadableProjectSkillsFolderIsAnError() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let projectURL = try folder(root.appending(path: "project"))
        let skills = try folder(projectURL.appending(path: ".claude/skills"))
        let project = try await service.addProject(Project(name: "p", path: projectURL.path), selection: AttachmentSelection(tools: [.claude]))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: skills.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path) }

        await XCTAssertThrowsErrorAsync(try await service.adoptableSkills(projectID: project.id))
    }

    // LOW. A damaged Claude settings file looked like "no plugins installed".
    func testDamagedClaudeSettingsAreAnError() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let projectURL = try folder(root.appending(path: "project"))
        try fm.createDirectory(at: projectURL.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{ zepsuty".write(to: projectURL.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await service.claudePlugins(projectPath: projectURL.path))
    }

    // LOW. A file accepted as a project folder.
    func testAFileIsNotAProjectFolder() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let file = root.appending(path: "plik.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await service.addProject(name: "p", path: file.path, tools: [.claude]))
    }

    // 13. `root-adopt` matched projects by the spelling of their path.
    func testRootAdoptFindsProjectsThroughASymbolicLink() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        let real = try folder(root.appending(path: "workspace"))
        let app = try folder(real.appending(path: "app"))
        let link = root.appending(path: "skrot")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try await service.addProject(Project(name: "app", path: app.path), selection: AttachmentSelection(tools: [.claude]))

        _ = try await AgentboxCommand.run(["project", "root-adopt", "grupa", link.path], service: service)

        let adopted = try await service.storedProjects()
        XCTAssertNotNil(adopted.first?.rootID, "projekt dołącza do folderu wskazanego przez dowiązanie")
    }
}
