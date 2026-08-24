import Foundation

extension SkillboxService {
    public func librarySnapshots() async throws -> [LibrarySnapshot] { try await store.snapshots() }

    @discardableResult
    public func restoreLibrarySnapshot(named name: String) async throws -> [String] {
        try await store.restoreSnapshot(named: name)
    }
}
