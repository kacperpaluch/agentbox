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
            // SIGKILL reaches only the direct child; a grandchild holding the pipe leaks one
            // blocked reader thread until it exits, but the actor stays usable.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw SkillboxError.commandFailed("przekroczono limit \(Int(timeout)) s: \(redacted(([executable] + arguments).joined(separator: " ")))")
        }
        process.waitUntilExit()
        let output = String(decoding: buffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw SkillboxError.commandFailed(redacted(output)) }
        return output
    }

    /// The text with any password or token embedded in a URL masked.
    ///
    /// Git echoes the remote it failed on, and a remote can carry credentials in its userinfo
    /// (`https://user:token@host/repo`). That text becomes the error message, which lands in the
    /// operation history and in anything the user copies out of it, so it is masked here — once,
    /// at the only place that turns command output into an error — rather than at each call site.
    /// The username survives, because that is the half that makes the message useful.
    ///
    /// `git@github.com:user/repo` carries no secret and has no `://`, so it is left alone.
    static func redacted(_ text: String) -> String {
        let pattern = "([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@\\s]+)@"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        // Applied back to front so each replacement leaves the offsets of the earlier ones intact.
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let scheme = Range(match.range(at: 1), in: result),
                  let userinfo = Range(match.range(at: 2), in: result) else { continue }
            let user = String(result[userinfo])
            let masked = user.contains(":") ? user.prefix(while: { $0 != ":" }) + ":***" : "***"
            result.replaceSubrange(whole, with: result[scheme] + masked + "@")
        }
        return result
    }
}
