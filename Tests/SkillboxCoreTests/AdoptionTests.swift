import XCTest
@testable import SkillboxCore

/// Taking back a change made where the work actually happens: inside a project, with the client
/// open, where noticing that a skill needs a fix is the whole point.
final class AdoptionTests: AgentboxTestCase {
    private func makeLibrary() throws -> (SkillboxService, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (try SkillboxService(root: root.appending(path: "data")), root)
    }

    private func addSkill(_ service: SkillboxService, root: URL, id: String, body: String = "wersja 1") async throws {
        let source = root.appending(path: "source/\(id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: \(id)\ndescription: Demo\n---\n\(body)\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: source.path)
    }

    private func addProject(_ service: SkillboxService, root: URL, name: String, skills: [String]) async throws -> Project {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await service.addProject(Project(name: name, path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: skills))
    }

    private func projectCopy(_ root: URL, project: String, skill: String) -> URL {
        root.appending(path: "\(project)/.claude/skills/\(skill)/SKILL.md")
    }

    func testChangeMadeInAProjectIsOfferedBackToTheLibrary() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let project = try await addProject(service, root: root, name: "app", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        var drift = try await service.driftedSkills()
        XCTAssertTrue(drift.isEmpty, "zaraz po synchronizacji nic się nie rozjechało")

        // The user improves the skill where they work: inside the project.
        try "---\nname: notes\ndescription: Demo\n---\npoprawka z projektu\n".write(to: projectCopy(root, project: "app", skill: "notes"), atomically: true, encoding: .utf8)

        let drifted = try await service.driftedSkills()
        XCTAssertEqual(drifted.map(\.skillID), ["notes"])
        XCTAssertEqual(drifted.first?.projectName, "app")
        XCTAssertEqual(drifted.first?.isGitBacked, false)

        _ = try await service.adoptSkillChanges(drifted)

        let library = try await service.skillMarkdown(skillID: "notes")
        XCTAssertTrue(library.contains("poprawka z projektu"))
        drift = try await service.driftedSkills()
        XCTAssertTrue(drift.isEmpty, "po przejęciu nie ma już czego przejmować")
    }

    /// Adoption is a library edit, so the project it came from is settled and every *other* project
    /// holding that skill has something to pick up.
    func testAdoptionSettlesTheSourceProjectAndMarksTheOthersOutdated() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let source = try await addProject(service, root: root, name: "source", skills: ["notes"])
        let other = try await addProject(service, root: root, name: "other", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: source.id)
        _ = try await service.syncProjectTransaction(projectID: other.id)
        try "---\nname: notes\ndescription: Demo\n---\npoprawka\n".write(to: projectCopy(root, project: "source", skill: "notes"), atomically: true, encoding: .utf8)

        _ = try await service.adoptSkillChanges(try await service.driftedSkills(projectID: source.id))

        let statuses = try await service.projectStatuses()
        XCTAssertEqual(statuses.first { $0.projectID == source.id }?.state, .synced, "projekt, który oddał zmianę, jest w zgodzie z biblioteką")
        XCTAssertNotEqual(statuses.first { $0.projectID == other.id }?.state, .synced, "pozostałe projekty mają co pobrać")

        _ = try await service.syncProjectTransaction(projectID: other.id)
        let copied = try String(contentsOf: projectCopy(root, project: "other", skill: "notes"), encoding: .utf8)
        XCTAssertTrue(copied.contains("poprawka"))
    }

    /// The library moving on is an ordinary pending update, not something the project has to give
    /// back — otherwise adopting would quietly revert the edit just made in the app.
    func testASkillEditedInTheAppIsNotReportedAsComingFromTheProject() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let project = try await addProject(service, root: root, name: "app", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try await Task.sleep(for: .milliseconds(1100))

        try await service.saveSkillMarkdown(skillID: "notes", content: "---\nname: notes\ndescription: Demo\n---\nz aplikacji\n")

        let afterAppEdit = try await service.driftedSkills()
        XCTAssertTrue(afterAppEdit.isEmpty, "zmiana w bibliotece to zwykła nieaktualność projektu")
        guard case .pending = try await service.projectStatuses()[0].state else { return XCTFail("oczekiwano statusu do synchronizacji") }
    }

    func testTwoProjectsChangingTheSameSkillDifferentlyMustBeResolvedByHand() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let first = try await addProject(service, root: root, name: "first", skills: ["notes"])
        let second = try await addProject(service, root: root, name: "second", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: first.id)
        _ = try await service.syncProjectTransaction(projectID: second.id)
        try "---\nname: notes\ndescription: Demo\n---\nz pierwszego\n".write(to: projectCopy(root, project: "first", skill: "notes"), atomically: true, encoding: .utf8)
        try "---\nname: notes\ndescription: Demo\n---\nz drugiego\n".write(to: projectCopy(root, project: "second", skill: "notes"), atomically: true, encoding: .utf8)

        let drifted = try await service.driftedSkills()
        XCTAssertEqual(drifted.count, 2)
        await XCTAssertThrowsErrorAsync(try await service.adoptSkillChanges(drifted))
        let untouched = try await service.skillMarkdown(skillID: "notes")
        XCTAssertFalse(untouched.contains("z pierwszego"), "odrzucona partia nie zmienia biblioteki")

        // Choosing one project is a complete answer.
        _ = try await service.adoptSkillChanges(drifted.filter { $0.projectName == "second" })
        let chosen = try await service.skillMarkdown(skillID: "notes")
        XCTAssertTrue(chosen.contains("z drugiego"))
    }

    /// Identical edits in two projects are not a conflict — there is only one answer to take.
    func testTheSameChangeInTwoProjectsIsAdoptedWithoutComplaint() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let first = try await addProject(service, root: root, name: "first", skills: ["notes"])
        let second = try await addProject(service, root: root, name: "second", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: first.id)
        _ = try await service.syncProjectTransaction(projectID: second.id)
        for name in ["first", "second"] {
            try "---\nname: notes\ndescription: Demo\n---\nta sama poprawka\n".write(to: projectCopy(root, project: name, skill: "notes"), atomically: true, encoding: .utf8)
        }

        _ = try await service.adoptSkillChanges(try await service.driftedSkills())

        let merged = try await service.skillMarkdown(skillID: "notes")
        XCTAssertTrue(merged.contains("ta sama poprawka"))
        let remaining = try await service.driftedSkills()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// `update` replaces a Git skill wholesale, so anything adopted into it would disappear at the
    /// next update. Refusing is the same answer the in-app editor gives.
    func testGitBackedSkillIsReportedButNotAdopted() async throws {
        let (service, root) = try makeLibrary()
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: repo-skill\ndescription: Demo\n---\nz repo\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        let imported = try await service.listSkills()
        let id = try XCTUnwrap(imported.first).id
        let project = try await addProject(service, root: root, name: "app", skills: [id])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "---\nname: repo-skill\ndescription: Demo\n---\nlokalna poprawka\n".write(to: projectCopy(root, project: "app", skill: id), atomically: true, encoding: .utf8)

        let drifted = try await service.driftedSkills()
        XCTAssertEqual(drifted.first?.isGitBacked, true, "użytkownik musi zobaczyć, dlaczego nie da się tego przejąć")
        await XCTAssertThrowsErrorAsync(try await service.adoptSkillChanges(drifted))
    }

    /// A skill edited straight in the library folder keeps its `updatedAt`. It used to look like a
    /// change made in the project, and adopting it put the old project copy over the new library.
    func testLibraryEditedInAnEditorIsNotOfferedAsAProjectChange() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let project = try await addProject(service, root: root, name: "app", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "---\nname: notes\ndescription: Demo\n---\nedycja w bibliotece\n".write(to: root.appending(path: "data/skills/notes/SKILL.md"), atomically: true, encoding: .utf8)

        let drift = try await service.driftedSkills()
        XCTAssertTrue(drift.isEmpty, "zmiana w bibliotece to zwykła aktualizacja projektu, nie zmiana do przejęcia")
    }

    func testAdoptionRefusesWhenTheLibraryChangedAfterTheListWasMade() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let project = try await addProject(service, root: root, name: "app", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        try "---\nname: notes\ndescription: Demo\n---\nz projektu\n".write(to: projectCopy(root, project: "app", skill: "notes"), atomically: true, encoding: .utf8)
        let drifted = try await service.driftedSkills()
        XCTAssertEqual(drifted.count, 1)

        try await service.saveSkillMarkdown(skillID: "notes", content: "---\nname: notes\ndescription: Demo\n---\nnowsza w bibliotece\n")
        await XCTAssertThrowsErrorAsync(try await service.adoptSkillChanges(drifted))
        let library = try await service.skillMarkdown(skillID: "notes")
        XCTAssertTrue(library.contains("nowsza w bibliotece"), "nowsza wersja biblioteki zostaje")
    }

    /// The second skill fails to install, then — separately — the catalog save fails. Both times the
    /// library must come back byte for byte, metadata included.
    func testFailedAdoptionPutsEveryDirectoryAndTheCatalogBack() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "alpha")
        try await addSkill(service, root: root, id: "beta")
        let project = try await addProject(service, root: root, name: "app", skills: ["alpha", "beta"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        for id in ["alpha", "beta"] {
            try "---\nname: \(id)\ndescription: Demo\n---\nz projektu\n".write(to: projectCopy(root, project: "app", skill: id), atomically: true, encoding: .utf8)
        }
        let drifted = try await service.driftedSkills()
        XCTAssertEqual(drifted.count, 2)
        let skills = root.appending(path: "data/skills")
        let before = try ["alpha", "beta"].map { try SkillTree.read(skills.appending(path: $0)) }
        let catalogBefore = try Data(contentsOf: root.appending(path: "data/catalog.json"))
        defer { SkillboxService.injectedFailure = nil }

        for step in ["install:beta", "commit"] {
            SkillboxService.injectedFailure = { if $0 == step { throw SkillboxError.commandFailed("wymuszony błąd") } }
            await XCTAssertThrowsErrorAsync(try await service.adoptSkillChanges(drifted))
            XCTAssertEqual(try ["alpha", "beta"].map { try SkillTree.read(skills.appending(path: $0)) }, before, "\(step): katalogi wracają")
            XCTAssertEqual(try Data(contentsOf: root.appending(path: "data/catalog.json")), catalogBefore, "\(step): katalog metadanych bez zmian")
        }
    }

    func testFailedGitReimportAndLocalImportLeaveTheLibraryAsItWas() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "alpha")
        let skills = root.appending(path: "data/skills")
        let catalogBefore = try Data(contentsOf: root.appending(path: "data/catalog.json"))
        defer { SkillboxService.injectedFailure = nil }
        SkillboxService.injectedFailure = { if $0 == "commit" { throw SkillboxError.commandFailed("wymuszony błąd") } }
        let source = root.appending(path: "source/gamma")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: gamma\ndescription: Demo\n---\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        await XCTAssertThrowsErrorAsync(try await service.addLocal(path: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skills.appending(path: "gamma").path), "nieudany import nie zostawia katalogu")
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "data/catalog.json")), catalogBefore)
    }

    func testDamagedSkillManifestIsAnErrorNotAnEmptyManifest() async throws {
        let (service, root) = try makeLibrary()
        try await addSkill(service, root: root, id: "notes")
        let project = try await addProject(service, root: root, name: "app", skills: ["notes"])
        _ = try await service.syncProjectTransaction(projectID: project.id)
        let manifest = root.appending(path: "app/.claude/skills/.skillbox.json")
        for broken in ["{ nie json", "[\"notes\", \"notes\"]", "{\"version\": 99, \"skills\": {}}"] {
            try broken.write(to: manifest, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SkillboxService.skillManifest(at: manifest.deletingLastPathComponent()), broken)
            await XCTAssertThrowsErrorAsync(try await service.syncProjectTransaction(projectID: project.id))
            XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), broken, "uszkodzony manifest nie zostaje nadpisany")
        }
    }
}
