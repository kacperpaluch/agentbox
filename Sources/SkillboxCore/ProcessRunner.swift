import Foundation

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = cwd
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SkillboxError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
