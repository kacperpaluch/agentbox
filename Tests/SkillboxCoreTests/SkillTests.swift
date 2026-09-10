import XCTest
@testable import SkillboxCore

final class SkillTests: AgentboxTestCase {
    func testGitHubTreeURLIsNormalizedToRepositoryBranchAndSubpath() {
        let value = SkillboxService.normalizeGitInput(url: "https://github.com/anthropics/skills/tree/main/skills/docx", subpath: nil, branch: nil)
        XCTAssertEqual(value.url, "https://github.com/anthropics/skills.git")
        XCTAssertEqual(value.branch, "main")
        XCTAssertEqual(value.subpath, "skills/docx")
    }
    func testGitImportSkipsConflictingCandidateButSavesTheRestOfTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        for name in ["conflict", "seo-a", "seo-b"] {
            let folder = repo.appending(path: "skills/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        // A local, unrelated skill already occupies the id one of the repo's candidates wants.
        let local = root.appending(path: "local/conflict")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "---\nname: conflict\ndescription: Local\n---\n".write(to: local.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await service.addLocal(path: local.path)

        let result = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(result.imported.map(\.id).sorted(), ["seo-a", "seo-b"])
        XCTAssertEqual(result.skipped.map(\.id), ["conflict"])
        let afterSkills = try await service.listSkills()
        XCTAssertEqual(afterSkills.map(\.id).sorted(), ["conflict", "seo-a", "seo-b"])
        // The pre-existing local skill was left alone, not overwritten by the repo's copy.
        XCTAssertEqual(afterSkills.first { $0.id == "conflict" }?.source.kind, .local)
    }
    func testReimportingRepositoryWithDifferentlyFormattedURLIsStillRecognizedAsTheSameSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        // Named with a trailing ".git" so the two ways of referring to it below — with and without
        // that suffix — are both real, clonable paths, mirroring GitHub's "Copy" URL (with `.git`)
        // versus the address-bar URL (without it) for the same repository.
        let repo = root.appending(path: "demo.git")
        let alias = root.appending(path: "demo")
        let folder = repo.appending(path: "skills/one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: one\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))

        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        // Re-adding via the alias without ".git" must update in place, not throw a duplicate — it
        // is the same repository, just typed differently.
        let result = try await service.addGitCollection(url: alias.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(result.imported.map(\.id), ["one"])
        XCTAssertTrue(result.skipped.isEmpty)
        let ids = try await service.listSkills().map(\.id)
        XCTAssertEqual(ids, ["one"])
    }
    func testImportsSkillFromGitRepositoryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "root-skill")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: root-skill\ndescription: Demo\n---\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString).imported
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].id, "root-skill")
        XCTAssertNil(imported[0].source.subpath)
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        let skillsAfterReimport = try await service.listSkills()
        XCTAssertEqual(skillsAfterReimport.map(\.id), ["root-skill"])
    }
    func testGitSkillCannotBeEditedInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo-skill")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "z repozytorium".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        await XCTAssertThrowsErrorAsync(try await service.saveSkillMarkdown(skillID: "repo-skill", content: "podmiana"))
        let unchanged = try await service.skillMarkdown(skillID: "repo-skill")
        XCTAssertEqual(unchanged, "z repozytorium")
    }

    /// Forty skills coming from eight repositories used to mean forty clones and forty catalog
    /// saves, because every caller looped over `update(skillID:)` — and ten recovery snapshots is
    /// all the library keeps, so one "update everything" wiped the whole history.
    func testUpdatingSeveralSkillsFromOneRepositoryTakesOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let repo = root.appending(path: "repo")
        for name in ["one", "two"] {
            let folder = repo.appending(path: "skills/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Demo\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        let imported = try await service.addGitCollection(url: repo.absoluteURL.absoluteString, subpath: "skills")
        XCTAssertEqual(imported.imported.count, 2)
        for name in ["one", "two"] {
            try "---\nname: \(name)\ndescription: Nowa treść\n---\n".write(to: repo.appending(path: "skills/\(name)/SKILL.md"), atomically: true, encoding: .utf8)
        }
        try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "second"], in: repo)
        let snapshotsBefore = try await service.librarySnapshots().count

        let result = try await service.updateSkills(ids: ["one", "two"])

        XCTAssertEqual(result.updated.map(\.id), ["one", "two"])
        XCTAssertTrue(result.failed.isEmpty)
        let snapshotsAfter = try await service.librarySnapshots().count
        XCTAssertEqual(snapshotsAfter, snapshotsBefore + 1, "obie aktualizacje muszą być jednym zapisem katalogu")
        for name in ["one", "two"] {
            let text = try await service.skillMarkdown(skillID: name)
            XCTAssertTrue(text.contains("Nowa treść"))
        }
    }

    /// A repository nobody can reach must fail only its own skills — the GUI already promised that
    /// "one temporary problem does not stop the rest", and now one call has to keep the promise.
    func testUnreachableRepositoryFailsOnlyItsOwnSkills() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let local = root.appending(path: "local/keeper")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "---\nname: keeper\ndescription: Demo\n---\n".write(to: local.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let repo = root.appending(path: "gone")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: gone\ndescription: Demo\n---\n".write(to: repo.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try runGit(["init"], in: repo); try runGit(["add", "."], in: repo)
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"], in: repo)
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: local.path)
        _ = try await service.addGitCollection(url: repo.absoluteURL.absoluteString)
        try FileManager.default.removeItem(at: repo)

        let result = try await service.updateSkills(ids: ["keeper", "gone"])

        XCTAssertEqual(result.updated.map(\.id), ["keeper"])
        XCTAssertEqual(result.failed.map(\.id), ["gone"])
    }

}
