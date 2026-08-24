import Foundation

/// Thread-safe flag shared with the timeout watchdog.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum ProcessRunner {
    /// Non-interactive environment. Git and SSH must fail fast instead of waiting for
    /// credentials that a GUI application can never provide; a blocked process would
    /// otherwise hold the SkillboxService actor forever.
    static func nonInteractiveEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        let ssh = environment["GIT_SSH_COMMAND"] ?? "ssh"
        environment["GIT_SSH_COMMAND"] = ssh + " -o BatchMode=yes"
        return environment
    }

    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = cwd
        process.environment = nonInteractiveEnvironment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem { if process.isRunning { timedOut.set(); process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.isSet {
            throw SkillboxError.commandFailed("przekroczono limit \(Int(timeout)) s: \(([executable] + arguments).joined(separator: " "))")
        }
        guard process.terminationStatus == 0 else { throw SkillboxError.commandFailed(output) }
        return output
    }
}
