import XCTest
@testable import SkillboxCore

/// Tag renaming, content search, snapshot retention, the CLI version and status checking — each
/// checked through its effect on the library, a project or the command's output.
final class LibraryToolsTests: AgentboxTestCase {
    private let fm = FileManager.default

    private func temp() throws -> URL {
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skill(_ id: String, in root: URL, body: String = "treść") throws -> URL {
        let url = root.appending(path: "source/\(id)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(id)\ndescription: Demo\n---\n\(body)\n".write(to: url.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Tags

    /// The rename reaches the entries *and* the places attaching by the tag, so a project that picks
    /// skills by it keeps them — nothing is about to be removed from it at the next sync.
    func testRenamingATagKeepsProjectsAttachedThroughIt() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        try await service.setTags(skillID: "demo", tags: ["web"])
        let server = MCPServer(name: "api", transport: .stdio, command: "npx", tags: ["web"])
        try await service.saveMCPServer(server)
        let doc = try await service.createDoc(id: "zasady", name: "Zasady", tags: ["web"], content: "tekst")
        let folder = root.appending(path: "project")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await service.addProject(Project(name: "p", path: folder.path), selection: AttachmentSelection(tools: [.claude], skillTags: ["web"], serverTags: ["web"], docTags: ["web"]))
        _ = try await service.syncProjectTransaction(projectID: project.id)

        let changed = try await service.renameTag("web", to: "Frontend")

        XCTAssertEqual(changed.name, "frontend")
        XCTAssertEqual([changed.skills, changed.servers, changed.docs], [1, 1, 1])
        XCTAssertGreaterThanOrEqual(changed.places, 1)
        let preview = try await service.previewProjectSync(projectID: project.id)
        XCTAssertTrue(preview.skills.allSatisfy { $0.removed.isEmpty }, "skill zostaje w projekcie: \(preview.skills.map(\.removed))")
        XCTAssertTrue(preview.mcp.allSatisfy { $0.removed.isEmpty }, "serwer zostaje w projekcie")
        XCTAssertTrue(preview.docs.allSatisfy { $0.removed.isEmpty }, "dokument zostaje w projekcie")
        let names = try await service.tagSummaries().map(\.name)
        XCTAssertEqual(names, ["frontend"])
        let docs = try await service.docsConfiguration().docs
        XCTAssertEqual(docs.first { $0.id == doc.id }?.tags, ["frontend"])
    }

    func testRenamingToAnExistingTagMergesTheTwo() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        try await service.setTags(skillID: "demo", tags: ["seo", "marketing"])

        try await service.renameTag("seo", to: "marketing")

        let skills = try await service.listSkills()
        XCTAssertEqual(skills.first?.tags, ["marketing"], "jeden tag zamiast dwóch takich samych")
    }

    func testTagRenameRefusesNonsense() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        try await service.setTags(skillID: "demo", tags: ["web"])

        await XCTAssertThrowsErrorAsync(try await service.renameTag("web", to: " "))
        await XCTAssertThrowsErrorAsync(try await service.renameTag("web", to: "a,b"))
        await XCTAssertThrowsErrorAsync(try await service.renameTag("web", to: "WEB"))
        await XCTAssertThrowsErrorAsync(try await service.renameTag("nie-ma", to: "inny"))
        let skills = try await service.listSkills()
        XCTAssertEqual(skills.first?.tags, ["web"], "odrzucona zmiana niczego nie zapisuje")
    }

    func testTagsCommandListsAndRenames() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        try await service.setTags(skillID: "demo", tags: ["web"])

        let listed = try await AgentboxCommand.run(["tags"], service: service)
        XCTAssertTrue(listed.first?.hasPrefix("web\tskille: 1") == true, "\(listed)")
        _ = try await AgentboxCommand.run(["tags", "rename", "web", "frontend"], service: service)
        let skills = try await service.listSkills()
        XCTAssertEqual(skills.first?.tags, ["frontend"])
    }

    // MARK: Search

    func testSkillTextsFollowTheFileOnDisk() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root, body: "obsługa faktur").path)

        let first = try await service.skillSearchTexts()
        XCTAssertTrue(first["demo"]?.text.contains("faktur") == true)

        let file = root.appending(path: "data/skills/demo/SKILL.md")
        try "---\nname: demo\ndescription: Demo\n---\nwysyłka paczek\n".write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: file.path)
        let second = try await service.skillSearchTexts(reusing: first)
        XCTAssertTrue(second["demo"]?.text.contains("paczek") == true, "zmieniony plik jest czytany na nowo")
    }

    // MARK: Snapshots

    /// Ten slots alone let a burst of edits push out yesterday. Now the newest of each of the last
    /// seven days stays too, and older days go.
    func testSnapshotsKeepOnePerDayForAWeek() async throws {
        let root = try temp()
        let library = root.appending(path: "data")
        let service = try SkillboxService(root: library)
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        let snapshots = library.appending(path: ".agentbox-snapshots")
        try? fm.removeItem(at: snapshots)
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        func make(_ name: String, _ date: Date) throws {
            let url = snapshots.appending(path: name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        for index in 0..<12 { try make("dzis-\(index)", Date.now.addingTimeInterval(-Double(index + 1))) }
        for day in 1...9 { try make("dzien-\(day)", calendar.date(byAdding: .day, value: -day, to: today)!.addingTimeInterval(12 * 3600)) }

        try await service.setTags(skillID: "demo", tags: ["nowy"])

        let left = Set(try fm.contentsOfDirectory(atPath: snapshots.path).filter { !$0.hasPrefix(".") })
        XCTAssertEqual(left.filter { $0.hasPrefix("dzien-") }, Set((1...6).map { "dzien-\($0)" }), "zostaje po jednym z każdego z ostatnich 7 dni")
        XCTAssertEqual(left.count, 16, "10 najnowszych i 6 wcześniejszych dni: \(left.sorted())")
    }

    // MARK: Version

    func testVersionComesFromTheAppBundleThroughTheInstalledLink() throws {
        let root = try temp()
        let contents = root.appending(path: "Agentbox.app/Contents")
        try fm.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        let binary = contents.appending(path: "Helpers/agentbox")
        try Data().write(to: binary)
        try fm.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        let link = root.appending(path: "bin/agentbox")
        try fm.createSymbolicLink(at: link, withDestinationURL: binary)

        XCTAssertEqual(AgentboxVersion.describe(executable: link), "agentbox 1.2.3 (45)")
        XCTAssertTrue(AgentboxVersion.describe(executable: root.appending(path: "luzem/agentbox")).contains("deweloperska"))
    }

    // MARK: Statuses

    /// The library copy is read once per run now; a change on either side must still show up, and
    /// only where it happened.
    func testStatusesSeeChangesOnBothSides() async throws {
        let root = try temp()
        let service = try SkillboxService(root: root.appending(path: "data"))
        _ = try await service.addLocal(path: try skill("demo", in: root).path)
        var ids: [UUID] = []
        for name in ["a", "b"] {
            let folder = root.appending(path: name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await service.addProject(Project(name: name, path: folder.path), selection: AttachmentSelection(tools: [.claude], skillIDs: ["demo"]))
            _ = try await service.syncProjectTransaction(projectID: project.id)
            ids.append(project.id)
        }
        func states() async throws -> [UUID: ProjectStatus.State] {
            Dictionary(uniqueKeysWithValues: try await service.projectStatuses().map { ($0.projectID, $0.state) })
        }
        var current = try await states()
        XCTAssertEqual(current[ids[0]], .synced)
        XCTAssertEqual(current[ids[1]], .synced)

        try "edytowane w projekcie\n".write(to: root.appending(path: "b/.claude/skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        current = try await states()
        XCTAssertEqual(current[ids[0]], .synced, "zmiana w jednym projekcie nie dotyczy drugiego")
        guard case .pending = current[ids[1]] else { return XCTFail("edycja kopii w projekcie jest widoczna: \(String(describing: current[ids[1]]))") }

        try "edytowane w bibliotece\n".write(to: root.appending(path: "data/skills/demo/SKILL.md"), atomically: true, encoding: .utf8)
        current = try await states()
        guard case .pending = current[ids[0]] else { return XCTFail("zmiana w bibliotece dotyczy każdego projektu") }
    }
}
