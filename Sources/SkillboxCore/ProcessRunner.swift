import Foundation

/// Thread-safe container for the output read on the background thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
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
        environment["GIT_SSH_COMMAND"] = ssh + " -o BatchMode=yes -o ConnectTimeout=30"
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
        // The read happens on its own thread so a timeout can abandon it. An orphaned
        // grandchild (git → ssh on a dead connection) keeps the pipe open after its parent
        // dies, and a blocking read here would freeze the service actor until app restart.
        let buffer = OutputBuffer()
        let done = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { buffer.set(handle.readDataToEndOfFile()); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // ponytail: SIGKILL reaches only the direct child; a grandchild holding the pipe
            // leaks one blocked reader thread until it exits, but the actor stays usable.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw SkillboxError.commandFailed("przekroczono limit \(Int(timeout)) s: \(([executable] + arguments).joined(separator: " "))")
        }
        process.waitUntilExit()
        let output = String(decoding: buffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw SkillboxError.commandFailed(output) }
        return output
    }
}
