import Foundation
import SkillboxCore

@main
struct AgentboxCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            let root = ProcessInfo.processInfo.environment["SKILLBOX_HOME"].map { URL(fileURLWithPath: $0) } ?? AgentboxRootPreference.load()
            let service = try SkillboxService(root: root)
            for line in try await AgentboxCommand.run(args, service: service) { print(line) }
        } catch {
            FileHandle.standardError.write(Data("Błąd: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
