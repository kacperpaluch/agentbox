import XCTest
@testable import SkillboxCore

/// A skill written straight into the library's `skills/` folder — by an assistant, an editor or
/// Finder — has no catalog entry, and until 0.31.0 that made it invisible to Agentbox.
final class UnregisteredSkillTests: AgentboxTestCase {
    private func makeLibrary() throws -> (SkillboxService, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let service = try SkillboxService(root: root.appending(path: "data"))
        return (service, root.appending(path: "data/skills"))
    }

    private func skillIDs(_ service: SkillboxService) async -> [String] { (try? await service.listSkills().map(\.id)) ?? ["błąd odczytu"] }
    private func unregisteredIDs(_ service: SkillboxService) async -> [String] { (try? await service.unregisteredSkills().map(\.id)) ?? ["błąd odczytu"] }

    @discardableResult
    private func writeSkill(_ folder: String, in skills: URL, name: String? = nil) throws -> URL {
        let directory = skills.appending(path: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let front = name.map { "---\nname: \($0)\ndescription: Demo\n---\n" } ?? ""
        try (front + "Treść\n").write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    func testAFolderWrittenIntoTheLibraryIsListedAndCanBeRegistered() async throws {
        let (service, skills) = try makeLibrary()
        try writeSkill("raport", in: skills, name: "raport")
        try FileManager.default.createDirectory(at: skills.appending(path: "w-trakcie"), withIntermediateDirectories: true)

        let found = try await service.unregisteredSkills()
        XCTAssertEqual(found.map(\.id), ["raport"], "folder bez SKILL.md nie jest jeszcze skillem")
        XCTAssertNil(found[0].problem)

        try await service.registerUnregisteredSkills(["raport"])
        let current1 = await skillIDs(service)
        XCTAssertEqual(current1, ["raport"])
        let current2 = await unregisteredIDs(service)
        XCTAssertTrue(current2.isEmpty)
        XCTAssertEqual(try String(contentsOf: skills.appending(path: "raport/SKILL.md"), encoding: .utf8), "---\nname: raport\ndescription: Demo\n---\nTreść\n")
    }

    func testFoldersThatCannotBeRegisteredAsTheyAreAreReportedWithTheReason() async throws {
        let (service, skills) = try makeLibrary()
        try writeSkill("raport", in: skills, name: "inny-skill")
        try writeSkill("Duże Litery", in: skills)
        let target = try writeSkill("cel", in: skills.deletingLastPathComponent().deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "dowiazanie"), withDestinationURL: target)

        let found = try await service.unregisteredSkills()
        XCTAssertEqual(found.map(\.id), ["Duże Litery", "dowiazanie", "raport"])
        XCTAssertTrue(found.allSatisfy { $0.problem != nil })

        await XCTAssertThrowsErrorAsync(try await service.registerUnregisteredSkills(["raport"]))
        await XCTAssertThrowsErrorAsync(try await service.registerUnregisteredSkills(["nie-ma-takiego"]))
        let current3 = await skillIDs(service)
        XCTAssertTrue(current3.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skills.appending(path: "dowiazanie").path), target.path, "dowiązanie zostaje nietknięte")
    }

    func testOneBadFolderRefusesTheWholeRegistration() async throws {
        let (service, skills) = try makeLibrary()
        try writeSkill("dobry", in: skills, name: "dobry")
        try writeSkill("zly", in: skills, name: "inna-nazwa")

        await XCTAssertThrowsErrorAsync(try await service.registerUnregisteredSkills(["dobry", "zly"]))
        let current4 = await skillIDs(service)
        XCTAssertTrue(current4.isEmpty)
    }

    func testAFailedCatalogSaveLeavesTheFolderAsItWas() async throws {
        let (service, skills) = try makeLibrary()
        let directory = try writeSkill("raport", in: skills, name: "raport")
        try "echo".write(to: directory.appending(path: "run.sh"), atomically: true, encoding: .utf8)
        SkillboxService.injectedFailure = { if $0 == "commit" { throw SkillboxError.commandFailed("wymuszony błąd") } }
        defer { SkillboxService.injectedFailure = nil }

        await XCTAssertThrowsErrorAsync(try await service.registerUnregisteredSkills(["raport"]))
        let current5 = await skillIDs(service)
        XCTAssertTrue(current5.isEmpty)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["SKILL.md", "run.sh"])
        let current6 = await unregisteredIDs(service)
        XCTAssertEqual(current6, ["raport"])
    }

    func testCommandLineListsFirstAndRegistersOnlyWithYes() async throws {
        let (service, skills) = try makeLibrary()
        try writeSkill("raport", in: skills, name: "raport")

        let listed = try await AgentboxCommand.run(["adopt-library"], service: service)
        XCTAssertTrue(listed.contains("  raport"))
        let current7 = await skillIDs(service)
        XCTAssertTrue(current7.isEmpty)

        _ = try await AgentboxCommand.run(["adopt-library", "--yes"], service: service)
        let current8 = await skillIDs(service)
        XCTAssertEqual(current8, ["raport"])
    }

    func testCommandLineReportsAFolderItHadToLeaveOut() async throws {
        let (service, skills) = try makeLibrary()
        try writeSkill("raport", in: skills, name: "raport")
        try writeSkill("zly", in: skills, name: "inna-nazwa")
        do {
            _ = try await AgentboxCommand.run(["adopt-library", "--yes"], service: service)
            XCTFail("oczekiwano PartialFailure")
        } catch let failure as AgentboxCommand.PartialFailure {
            XCTAssertTrue(failure.lines.contains { $0.contains("zly") })
        }
        let current9 = await skillIDs(service)
        XCTAssertEqual(current9, ["raport"])
    }
}
