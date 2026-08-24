import Foundation

extension SkillboxService {
    public func librarySnapshots() async throws -> [LibrarySnapshot] { try await store.snapshots() }

    @discardableResult
    public func restoreLibrarySnapshot(named name: String) async throws -> [String] {
        try await store.restoreSnapshot(named: name)
    }

    public func fullBackups() async throws -> [FullBackupInfo] { try await store.fullBackups() }
    @discardableResult public func createFullBackup(applicationVersion: String) async throws -> FullBackupInfo { try await store.createFullBackup(applicationVersion: applicationVersion) }
    public func restoreFullBackup(named name: String) async throws { try await store.restoreFullBackup(named: name) }
    public func deleteFullBackup(named name: String) async throws { try await store.deleteFullBackup(named: name) }
}
