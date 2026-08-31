import XCTest
@testable import SkillboxCore

final class ClaudePluginTests: AgentboxTestCase {
    private func makeService() throws -> (SkillboxService, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (try SkillboxService(root: root.appending(path: "data")), root)
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: Inheritance

    func testPluginSelectionForAnInheritingProjectIsRefusedInsteadOfChangingItsSiblings() async throws {
        let (service, root) = try makeService()
        let folder = root.appending(path: "group")
        for name in ["a", "b"] { try makeFolder(folder.appending(path: name)) }
        _ = try await service.addProjectRoot(
            ProjectRoot(name: "group", path: folder.path, tools: [.claude]),
            folders: [folder.appending(path: "a").path, folder.appending(path: "b").path],
            selection: AttachmentSelection(tools: [.claude])
        )
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        let projects = try await service.listProjects()
        let a = try XCTUnwrap(projects.first { $0.name == "a" })
        let b = try XCTUnwrap(projects.first { $0.name == "b" })

        do {
            try await service.setClaudePluginSelection(projectID: a.id, ids: [definition.id])
            XCTFail("a project following its folder must not rewrite the folder's shared selection")
        } catch {}

        let selectedForB = try await service.selectedClaudePluginIDs(projectID: b.id)
        XCTAssertTrue(selectedForB.isEmpty)
    }

    func testAProjectWithItsOwnSettingsKeepsItsPluginSelectionToItself() async throws {
        let (service, root) = try makeService()
        let first = root.appending(path: "first"), second = root.appending(path: "second")
        try makeFolder(first); try makeFolder(second)
        let one = try await service.addProject(name: "first", path: first.path, tools: [.claude])
        let two = try await service.addProject(name: "second", path: second.path, tools: [.claude])
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)

        try await service.setClaudePluginSelection(projectID: one.id, ids: [definition.id])

        let selectedForOne = try await service.selectedClaudePluginIDs(projectID: one.id)
        let selectedForTwo = try await service.selectedClaudePluginIDs(projectID: two.id)
        XCTAssertEqual(selectedForOne, [definition.id])
        XCTAssertTrue(selectedForTwo.isEmpty)
    }

    // MARK: Removal

    func testRemovingAPluginAlsoDropsItFromTheSelectionSoSyncDoesNotReinstallIt() async throws {
        let (service, root) = try makeService()
        let projectURL = root.appending(path: "project")
        try makeFolder(projectURL)
        let project = try await service.addProject(name: "project", path: projectURL.path, tools: [.claude])
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        try await service.setClaudePluginSelection(projectID: project.id, ids: [definition.id])

        let deselected = try await service.deselectClaudePlugin(
            projectPath: projectURL.path,
            plugin: ClaudePlugin(id: "seo@vendor-seo", scope: .project, enabled: true)
        )

        XCTAssertTrue(deselected)
        let remaining = try await service.selectedClaudePluginIDs(projectID: project.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRemovingAPluginLeavesTheSharedSelectionOfAParentFolderAlone() async throws {
        let (service, root) = try makeService()
        let folder = root.appending(path: "group")
        try makeFolder(folder.appending(path: "a"))
        let created = try await service.addProjectRoot(
            ProjectRoot(name: "group", path: folder.path, tools: [.claude]),
            folders: [folder.appending(path: "a").path],
            selection: AttachmentSelection(tools: [.claude])
        )
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        var selection = try await service.allSelections()[created.id.uuidString] ?? AttachmentSelection()
        selection.claudePluginIDs = [definition.id]
        try await service.setSelection(selection, for: .root(created.id))

        let deselected = try await service.deselectClaudePlugin(
            projectPath: folder.appending(path: "a").path,
            plugin: ClaudePlugin(id: "seo@vendor-seo", scope: .project, enabled: true)
        )

        XCTAssertFalse(deselected)
        let projects = try await service.listProjects()
        let project = try XCTUnwrap(projects.first)
        let stillSelected = try await service.selectedClaudePluginIDs(projectID: project.id)
        XCTAssertEqual(stillSelected, [definition.id])
    }

    func testDeletingALibraryDefinitionClearsEverySelectionPointingAtIt() async throws {
        let (service, root) = try makeService()
        let projectURL = root.appending(path: "project")
        try makeFolder(projectURL)
        let project = try await service.addProject(name: "project", path: projectURL.path, tools: [.claude])
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        try await service.setClaudePluginSelection(projectID: project.id, ids: [definition.id])

        try await service.deleteLibraryClaudePlugin(id: definition.id)

        let library = try await service.libraryClaudePlugins()
        let selected = try await service.selectedClaudePluginIDs(projectID: project.id)
        XCTAssertTrue(library.isEmpty)
        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: Library validation

    func testCorrectingADefinitionKeepsItsIdentitySoSelectionsFollowTheChange() async throws {
        let (service, root) = try makeService()
        let projectURL = root.appending(path: "project")
        try makeFolder(projectURL)
        let project = try await service.addProject(name: "project", path: projectURL.path, tools: [.claude])
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "sao@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        try await service.setClaudePluginSelection(projectID: project.id, ids: [definition.id])

        var corrected = definition
        corrected.plugin = "seo@vendor-seo"
        try await service.updateLibraryClaudePlugin(corrected)

        let identifiers = try await service.libraryClaudePlugins().map(\.plugin)
        let selected = try await service.selectedClaudePluginIDs(projectID: project.id)
        XCTAssertEqual(identifiers, ["seo@vendor-seo"])
        XCTAssertEqual(selected, [definition.id])
    }

    func testALibraryDefinitionNeedsAnIdentifierAndAUniqueName() async throws {
        let (service, _) = try makeService()
        try await service.addLibraryClaudePlugin(ClaudePluginDefinition(name: "SEO", marketplace: "vendor/seo", plugin: "seo@vendor-seo"))

        do {
            try await service.addLibraryClaudePlugin(ClaudePluginDefinition(name: "inne", marketplace: "vendor/seo", plugin: "   "))
            XCTFail("a definition without an identifier cannot be installed by anything")
        } catch {}
        do {
            try await service.addLibraryClaudePlugin(ClaudePluginDefinition(name: "seo", marketplace: "vendor/other", plugin: "other@vendor"))
            XCTFail("two definitions with the same name are indistinguishable in every picker")
        } catch {}

        let library = try await service.libraryClaudePlugins()
        XCTAssertEqual(library.count, 1)
    }

    func testDefinitionValuesAreStoredTrimmed() async throws {
        let (service, _) = try makeService()
        try await service.addLibraryClaudePlugin(ClaudePluginDefinition(name: "  seo  ", marketplace: " vendor/seo ", plugin: " seo@vendor-seo "))
        let library = try await service.libraryClaudePlugins()
        let stored = try XCTUnwrap(library.first)
        XCTAssertEqual(stored.name, "seo")
        XCTAssertEqual(stored.marketplace, "vendor/seo")
        XCTAssertEqual(stored.plugin, "seo@vendor-seo")
    }

    // MARK: Reading Claude's settings

    func testEnabledPluginsAreReadFromEveryShapeExceptAnExplicitNull() {
        XCTAssertEqual(SkillboxService.enabledFlag(true), true)
        XCTAssertEqual(SkillboxService.enabledFlag(false), false)
        XCTAssertEqual(SkillboxService.enabledFlag(["enabled": false] as [String: Any]), false)
        XCTAssertEqual(SkillboxService.enabledFlag(["config": ["key": "value"]] as [String: Any]), true)
        XCTAssertEqual(SkillboxService.enabledFlag("false"), false)
        XCTAssertEqual(SkillboxService.enabledFlag("true"), true)
        XCTAssertEqual(SkillboxService.enabledFlag(42), true)
        XCTAssertNil(SkillboxService.enabledFlag(NSNull()))
    }

    func testAPluginDeclaredAsAnObjectIsStillListedForTheProject() async throws {
        let (service, root) = try makeService()
        let projectURL = root.appending(path: "project")
        try makeFolder(projectURL.appending(path: ".claude"))
        try #"{"enabledPlugins": {"seo@vendor": {"config": {"lang": "pl"}}, "old@vendor": null}}"#
            .write(to: projectURL.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        let plugins = try await service.claudePlugins(projectPath: projectURL.path)

        XCTAssertEqual(plugins, [ClaudePlugin(id: "seo@vendor", scope: .project, enabled: true)])
    }

    // MARK: Preview and status

    func testSelectedPluginMissingFromTheProjectIsReportedAsPendingWork() async throws {
        let (service, root) = try makeService()
        let projectURL = root.appending(path: "project")
        try makeFolder(projectURL)
        let project = try await service.addProject(name: "project", path: projectURL.path, tools: [.claude])
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        try await service.addLibraryClaudePlugin(definition)
        try await service.setClaudePluginSelection(projectID: project.id, ids: [definition.id])

        let pending = try await service.previewProjectSync(projectID: project.id)
        XCTAssertEqual(pending.missingPlugins.map(\.name), ["seo"])
        let pendingStatuses = try await service.projectStatuses()
        let pendingStatus = try XCTUnwrap(pendingStatuses.first)
        guard case .pending = pendingStatus.state else { return XCTFail("a plugin waiting to be installed is pending work") }

        try makeFolder(projectURL.appending(path: ".claude"))
        try #"{"enabledPlugins": {"seo@vendor-seo": true}}"#
            .write(to: projectURL.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        let applied = try await service.previewProjectSync(projectID: project.id)
        XCTAssertTrue(applied.missingPlugins.isEmpty)
        XCTAssertEqual(applied.plugins.map(\.isInstalled), [true])
        let appliedStatuses = try await service.projectStatuses()
        XCTAssertEqual(appliedStatuses.first?.state, .synced)
    }

    func testADefinitionNamingOnlyThePluginMatchesClaudesFullIdentifier() {
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo")
        let installed = [ClaudePlugin(id: "seo@vendor-seo", scope: .project, enabled: true)]

        XCTAssertTrue(SkillboxService.isDeclared(definition, among: installed))
        XCTAssertFalse(SkillboxService.isDeclared(definition, among: [ClaudePlugin(id: "seo@vendor-seo", scope: .local, enabled: true)]))
        XCTAssertFalse(SkillboxService.isDeclared(definition, among: [ClaudePlugin(id: "seonic@vendor-seo", scope: .project, enabled: true)]))
    }

    func testAPluginDeclaredButDisabledCountsAsInstalledSoTheProjectStopsReportingWork() {
        let definition = ClaudePluginDefinition(name: "seo", marketplace: "vendor/seo", plugin: "seo@vendor-seo")
        let installed = [ClaudePlugin(id: "seo@vendor-seo", scope: .project, enabled: false)]

        XCTAssertTrue(SkillboxService.isDeclared(definition, among: installed))
    }

    // MARK: Rollback

    func testAFailedPluginInstallRestoresClaudesSettingsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project.appending(path: ".claude"), withIntermediateDirectories: true)
        let shared = project.appending(path: ".claude/settings.json")
        try #"{"enabledPlugins": {}}"#.write(to: shared, atomically: true, encoding: .utf8)

        let snapshot = SkillboxService.settingsSnapshot(project)
        // What Claude Code would have written before a later plugin in the same run failed.
        try #"{"enabledPlugins": {"seo@vendor": true}}"#.write(to: shared, atomically: true, encoding: .utf8)
        try #"{"enabledPlugins": {"local@vendor": true}}"#.write(to: project.appending(path: ".claude/settings.local.json"), atomically: true, encoding: .utf8)
        SkillboxService.restore(snapshot)

        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), #"{"enabledPlugins": {}}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appending(path: ".claude/settings.local.json").path))
    }
}
