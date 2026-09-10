import XCTest
@testable import SkillboxCore

/// Base class for the Agentbox core suites. Holds only the helpers shared across themes —
/// each suite file below stays free of setup so a test can be read where it sits.
class AgentboxTestCase: XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("oczekiwano błędu", file: file, line: line) } catch {}
    }
    /// Git's own answer, so a test can check the effect rather than the code that produced it.
    @discardableResult
    func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
