import Foundation
import SkillboxCore

@main
struct AgentboxCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Answered before the library is opened, so it works even when the library cannot be.
        if args == ["--version"] || args == ["version"] {
            print(AgentboxVersion.describe(executable: Bundle.main.executableURL))
            return
        }
        do {
            let root = try ProcessInfo.processInfo.environment["SKILLBOX_HOME"].map { URL(fileURLWithPath: $0) } ?? AgentboxRootPreference.load()
            let service = try SkillboxService(root: root)
            for line in try await AgentboxCommand.run(args, service: service) { print(line) }
        } catch let usage as AgentboxCommand.UsageError {
            FileHandle.standardError.write(Data("\(usage.localizedDescription)\n".utf8))
            exit(2)
        } catch let partial as AgentboxCommand.PartialFailure {
            for line in partial.lines { print(line) }
            FileHandle.standardError.write(Data("Błąd: \(partial.localizedDescription)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("Błąd: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
