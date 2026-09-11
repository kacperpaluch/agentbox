import XCTest
@testable import AgentboxApp
import SkillboxCore

/// The window's own logic: what an action leaves in `message`, what lands in the operation log,
/// when statuses are recomputed and what the library watcher is allowed to wake up for.
///
/// Every test drives a real service on a temporary library — the same way the core suites work —
/// because the interesting behaviour here is the ordering between an action, the reload that
/// follows it and the published state a view reads.
@MainActor
final class AppModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A model on a library of its own. The real one must never be touched by a test.
    private func makeModel() async throws -> AppModel {
        let model = AppModel(root: root.appending(path: "library"), startsAutomatically: false)
        await model.reload()
        XCTAssertNil(model.serviceError)
        return model
    }

    private func makeSkill(_ id: String, content: String = "wersja 1") throws -> URL {
        let folder = root.appending(path: "source/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(id)\ndescription: Demo\n---\n\(content)\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return folder
    }

    private func makeProjectFolder(_ name: String) throws -> URL {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Reload

    func testReloadPublishesEverythingAViewReads() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))

        XCTAssertEqual(model.skills.map(\.id), ["demo"])
        XCTAssertEqual(model.projects.map(\.name), ["app"])
        XCTAssertEqual(model.storedProjects.map(\.name), ["app"])
        // A project that has never been synchronized is not "aktualny", and the badge reads that
        // dictionary directly.
        let status = try XCTUnwrap(model.statuses[try XCTUnwrap(model.projects.first).id])
        XCTAssertNotEqual(status.state, .synced)
    }

    /// Every action ends with a reload, and the statuses have to come with it. Without that the
    /// badge kept saying `Aktualny` until the user happened to press `Sprawdź stan`.
    func testStatusIsRecomputedAfterEveryAction() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        let project = try XCTUnwrap(model.projects.first)

        await model.syncEverything(project)
        XCTAssertEqual(model.statuses[project.id]?.state, .synced)

        // Editing the skill through the app must flip the badge without any further user action.
        _ = await model.saveSkillMarkdown("demo", content: "---\nname: demo\ndescription: Demo\n---\nwersja 2\n")
        XCTAssertNotEqual(model.statuses[project.id]?.state, .synced)

        await model.syncEverything(project)
        XCTAssertEqual(model.statuses[project.id]?.state, .synced)
    }

    // MARK: Messages and the operation log

    func testFailedActionReportsTheReasonAndKeepsItInTheLog() async throws {
        let model = try await makeModel()
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude]))
        // A second project with the same name is refused by the service.
        await model.addProject(Project(name: "app", path: try makeProjectFolder("other").path), selection: AttachmentSelection(tools: [.claude]))

        XCTAssertTrue(model.message.contains("app"), "komunikat musi nazwać powód: \(model.message)")
        XCTAssertEqual(model.operationLog.first?.kind, .error)
        XCTAssertEqual(model.projects.count, 1, "nieudana akcja nie może zostawić projektu w bibliotece")
    }

    func testSuccessfulActionIsRecordedAsSuccess() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))

        // The automatic daily backup logs itself too, so the entry is looked up rather than
        // assumed to be first.
        let entry = model.operationLog.first { $0.text.contains("Dodano skill") }
        XCTAssertEqual(entry?.kind, .success)
    }

    /// `Synchronizuj wszystko` reports three different outcomes and the wording is what tells the
    /// user whether anything actually happened.
    func testSyncAllDistinguishesWrittenProjectsFromUnchangedOnes() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))
        for name in ["one", "two"] {
            let folder = try makeProjectFolder(name)
            await model.addProject(Project(name: name, path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        }

        let first = await model.syncAllProjects()
        XCTAssertEqual(first.filter { $0.state == .synced }.count, 2)
        XCTAssertTrue(model.message.contains("2"), "pierwszy przebieg zapisuje oba projekty: \(model.message)")

        let second = await model.syncAllProjects()
        XCTAssertEqual(second.filter { $0.state == .upToDate }.count, 2)
        XCTAssertTrue(model.message.contains("bez zmian"), "drugi przebieg nie ma nic do zapisania: \(model.message)")
    }

    /// One unreachable repository must not swallow the skills that did update — the message is the
    /// only place the user learns which half succeeded.
    func testUpdateAllReportsFailedSkillsAlongsideUpdatedOnes() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("keeper"))
        let repo = try makeProjectFolder("gone")
        try "---\nname: gone\ndescription: Demo\n---\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        await model.addGit(repo.absoluteURL.absoluteString, subpath: "")
        XCTAssertEqual(model.skills.count, 2, "przygotowanie: dwa skille w bibliotece")
        try FileManager.default.removeItem(at: repo)
        _ = try makeSkill("keeper", content: "wersja 2")
        model.updateAvailable = ["keeper", "gone"]

        await model.updateAllAvailable()

        XCTAssertTrue(model.message.contains("Nie udało się"), "komunikat musi wymienić nieudane: \(model.message)")
        XCTAssertTrue(model.message.contains("gone"))
        let plan = try XCTUnwrap(model.updateReview)
        XCTAssertEqual(plan.updates.map(\.id), ["keeper"], "\(plan.failed)")
        XCTAssertFalse(model.markdown.contains("wersja 2"), "podgląd jeszcze nie zapisuje")
        let accepted = await model.acceptSkillUpdates(plan, selected: ["keeper"], synchronizing: false)
        XCTAssertTrue(accepted)
        XCTAssertFalse(model.updateAvailable.contains("keeper"), "zaktualizowany skill znika z listy dostępnych")
        XCTAssertTrue(model.updateAvailable.contains("gone"), "nieudany skill zostaje do ponowienia")
    }

    func testDeletingAProjectWithItsFilesSaysHowMuchWasRemoved() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        let project = try XCTUnwrap(model.projects.first)
        await model.syncEverything(project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: ".claude/skills/demo/SKILL.md").path))

        await model.deleteProject(project, removingFiles: true)

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: ".claude/skills/demo").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "folder projektu zostaje na dysku")
    }

    // MARK: Adoption from a project

    /// Both halves of "przejmij z projektu" — a skill the library never knew and a change made to
    /// one it did — are one user decision, so they are one action with one message.
    func testAdoptingNewSkillsAndChangesIsOneAction() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("znany"))
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["znany"]))
        let project = try XCTUnwrap(model.projects.first)
        await model.syncEverything(project)

        // One managed skill improved in the project, one written there by hand.
        try "---\nname: znany\ndescription: Demo\n---\npoprawka z projektu\n"
            .write(to: folder.appending(path: ".claude/skills/znany/SKILL.md"), atomically: true, encoding: .utf8)
        let handwritten = folder.appending(path: ".claude/skills/reczny")
        try FileManager.default.createDirectory(at: handwritten, withIntermediateDirectories: true)
        try "---\nname: reczny\ndescription: Demo\n---\n".write(to: handwritten.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let changes = try await model.driftedSkills(project)
        XCTAssertEqual(changes.map(\.skillID), ["znany"])
        let newOnes = try await model.adoptableSkills(project)
        XCTAssertEqual(newOnes.map(\.suggestedID), ["reczny"])

        await model.adoptFromProject(newSkills: newOnes, changes: changes)

        XCTAssertEqual(model.skills.map(\.id).sorted(), ["reczny", "znany"])
        let library = try await XCTUnwrap(model.service).skillMarkdown(skillID: "znany")
        XCTAssertTrue(library.contains("poprawka z projektu"))
        XCTAssertEqual(model.statuses[project.id]?.state, .synced, "projekt oddał zmianę, więc nie ma już rozjazdu")
        XCTAssertEqual(model.operationLog.first?.kind, .success)
    }

    // MARK: Usage

    func testUsageAnswersWhereALibraryItemLands() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("wspolny"))
        for name in ["one", "two"] {
            let folder = try makeProjectFolder(name)
            await model.addProject(Project(name: name, path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["wspolny"]))
        }

        let usage = await model.usage(ofSkill: "wspolny")

        XCTAssertEqual(usage.projects, ["one", "two"])
        XCTAssertEqual(usage.summary, "2 projekty")
    }

    // MARK: Błędy nie mogą wyglądać jak sukces

    /// A failed update used to be swallowed into a green "Zaktualizowano 0 skilli" in the operation
    /// log. An error has to look like an error.
    func testFailedUpdateIsReportedAsAnErrorNotAsZeroUpdates() async throws {
        let model = try await makeModel()
        // An id nothing in the library knows: `updateSkills` throws rather than returning a result.
        model.updateAvailable = ["nie-ma-takiego"]

        await model.updateAllAvailable()

        XCTAssertEqual(model.operationLog.first?.kind, .error, "komunikat: \(model.message)")
        XCTAssertFalse(model.message.contains("Zaktualizowano 0"), "błąd nie może być zapisany jako udana aktualizacja: \(model.message)")
    }

    /// A form reports whether the save went through, so the sheet can stay open with everything the
    /// user typed still in it.
    func testSavingAProjectReportsFailureInsteadOfLosingTheForm() async throws {
        let model = try await makeModel()
        let folder = try makeProjectFolder("app")
        await model.addProject(Project(name: "app", path: folder.path), selection: AttachmentSelection(tools: [.claude]))

        let accepted = await model.addProject(Project(name: "app", path: try makeProjectFolder("inny").path), selection: AttachmentSelection(tools: [.claude]))

        XCTAssertFalse(accepted, "duplikat nazwy musi zwrócić porażkę, żeby arkusz został otwarty")
        XCTAssertEqual(model.projects.count, 1)
        let created = await model.createSkill(NewSkillDraft(id: "nowy", name: "nowy", description: "", content: "treść", tags: []))
        XCTAssertTrue(created, "poprawny zapis nadal zwraca sukces")
    }

    // MARK: Library watcher

    func testCreatingAGroupRootReportsFailureAndThenSuccess() async throws {
        let model = try await makeModel()
        let selection = AttachmentSelection(tools: [.claude])
        let missing = ProjectRoot(name: "grupa", path: root.appending(path: "missing").path)
        let failed = await model.adoptGroupIntoRoot(missing, following: [], keepingOwnSettings: [], selection: selection, treatingExistingAsKnown: true)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.operationLog.first?.kind, .error)
        XCTAssertTrue(model.projectRoots.isEmpty)
        let folder = try makeProjectFolder("grupa")
        let saved = await model.adoptGroupIntoRoot(ProjectRoot(name: "grupa", path: folder.path), following: [], keepingOwnSettings: [], selection: selection, treatingExistingAsKnown: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.projectRoots.count, 1)
    }

    /// The app writes a recovery snapshot before every metadata change and a full backup once a
    /// day, both inside the library. Waking up for those would mean answering our own writes with a
    /// reload, forever.
    func testWatcherIgnoresAgentboxOwnBackupDirectories() {
        let library = URL(fileURLWithPath: "/tmp/library")
        XCTAssertFalse(LibraryWatcher.shouldReload(paths: ["/tmp/library/.agentbox-snapshots/2026-01-01"], root: library))
        XCTAssertFalse(LibraryWatcher.shouldReload(paths: ["/tmp/library/backups/full/x"], root: library))
        XCTAssertTrue(LibraryWatcher.shouldReload(paths: ["/tmp/library/catalog.json"], root: library))
        XCTAssertTrue(LibraryWatcher.shouldReload(paths: ["/tmp/library/skills/demo/SKILL.md"], root: library))
        // A burst that carries one real change among our own noise is still a real change.
        XCTAssertTrue(LibraryWatcher.shouldReload(paths: ["/tmp/library/backups/full/x", "/tmp/library/mcp.json"], root: library))
        // Names that merely start the same way are not the directories themselves.
        XCTAssertTrue(LibraryWatcher.shouldReload(paths: ["/tmp/library/backups-notes.md"], root: library))
    }

    /// While Agentbox is writing, the events are its own and that path reloads by itself when it
    /// finishes. Answering them here would only repeat the work mid-action.
    func testWatcherStaysQuietWhileTheAppIsWriting() async throws {
        let model = try await makeModel()

        model.isWorking = true

        XCTAssertFalse(model.libraryChangedOnDisk(), "w trakcie własnego zapisu zdarzenia są nasze")
    }

    func testAutomaticBackupFailureIsVisibleWithoutReplacingToastAndRetryClearsStatus() async throws {
        let model = try await makeModel()
        let now = Date.now
        model.message = "Trwa praca"
        await model.createFullBackupIfDue(now: now, enabled: true)
        let original = try XCTUnwrap(model.fullBackups.first)
        XCTAssertEqual(model.message, "Trwa praca")
        XCTAssertNil(model.automaticBackupError)
        XCTAssertTrue(model.operationLog.contains { $0.kind == .success && $0.text.contains("Automatyczny pełny backup") })

        let docs = root.appending(path: "library/docs.json")
        try Data("not JSON".utf8).write(to: docs)
        let nextDay = now.addingTimeInterval(90000)
        await model.createFullBackupIfDue(now: nextDay, enabled: true)
        XCTAssertNotNil(model.automaticBackupError)
        XCTAssertEqual(model.fullBackups.first?.name, original.name, "ostatnia udana kopia pozostaje widoczna")
        XCTAssertEqual(model.operationLog.first?.kind, .error)
        XCTAssertEqual(model.message, "Trwa praca", "błąd automatyzacji nie pokazuje toastu")
        let count = model.operationLog.count
        await model.createFullBackupIfDue(now: nextDay.addingTimeInterval(1), enabled: true)
        XCTAssertEqual(model.operationLog.count, count, "brak powtarzania błędu przy każdym aktywowaniu okna")
        try FileManager.default.removeItem(at: docs)
        await model.createFullBackupIfDue(now: nextDay.addingTimeInterval(301), enabled: true)
        XCTAssertNil(model.automaticBackupError)
        XCTAssertTrue(model.operationLog.contains { $0.kind == .error && $0.text.contains("Automatyczny backup") })
    }

    func testFailedReviewedUpdateStaysOpenAndKeepsLocalEdit() async throws {
        let model = try await makeModel()
        await model.addLocal(try makeSkill("demo"))
        _ = try makeSkill("demo", content: "wersja 2")
        await model.update("demo")
        let plan = try XCTUnwrap(model.updateReview)
        _ = await model.saveSkillMarkdown("demo", content: "własna poprawka")
        let accepted = await model.acceptSkillUpdates(plan, selected: ["demo"], synchronizing: false)
        XCTAssertFalse(accepted)
        XCTAssertNotNil(model.updateReview, "podgląd zostaje otwarty po błędzie")
        XCTAssertEqual(model.markdown, "własna poprawka")
        XCTAssertEqual(model.operationLog.first?.kind, .error)
    }

    func testRefreshWaitsForAcceptanceAndBacksUpBeforeUpdatingAndSyncing() async throws {
        let model = try await makeModel()
        let repo = try makeSkill("demo", content: "wersja 1")
        try runGit(["init"], in: repo)
        try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], in: repo)
        _ = await model.addGit(repo.absoluteString, subpath: "")
        let folder = try makeProjectFolder("project")
        _ = await model.addProject(Project(name: "project", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
        let project = try XCTUnwrap(model.projects.first)
        await model.syncEverything(project)
        _ = try makeSkill("demo", content: "wersja 2")
        try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "update"], in: repo)

        await model.refresh()

        let plan = try XCTUnwrap(model.updateReview)
        XCTAssertTrue(model.reviewIncludesSync)
        let file = folder.appending(path: ".claude/skills/demo/SKILL.md")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("wersja 1"))
        let accepted = await model.acceptSkillUpdates(plan, selected: ["demo"], synchronizing: true)
        XCTAssertTrue(accepted, model.message)
        XCTAssertNil(model.updateReview)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("wersja 2"))
        let backup = try XCTUnwrap(model.fullBackups.first)
        let backedUp = root.appending(path: "library/backups/full/\(backup.name)/skills/demo/SKILL.md")
        XCTAssertTrue(try String(contentsOf: backedUp, encoding: .utf8).contains("wersja 1"))
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
