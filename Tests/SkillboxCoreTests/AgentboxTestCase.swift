import XCTest
@testable import SkillboxCore

/// Base class for the Agentbox core suites. Holds only the helpers shared across themes —
/// each suite file below stays free of setup so a test can be read where it sits.
class AgentboxTestCase: XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("oczekiwano błędu", file: file, line: line) } catch {}
    }
    func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
