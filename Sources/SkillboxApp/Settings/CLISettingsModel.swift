import SwiftUI
import SkillboxCore

@MainActor @Observable final class CLISettingsModel {
    var status = ""
    var installed = false
    private let destination = URL(fileURLWithPath: "/usr/local/bin/agentbox")

    init() { refresh() }

    func refresh() {
        guard let bundledCLI else { status = "Ta kompilacja aplikacji nie zawiera CLI."; installed = false; return }
        guard let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else {
            if FileManager.default.fileExists(atPath: destination.path) { status = "Ścieżka /usr/local/bin/agentbox jest zajęta przez inny plik. Agentbox go nie nadpisze." }
            else { status = "CLI nie jest zainstalowane w /usr/local/bin." }
            installed = false; return
        }
        installed = URL(fileURLWithPath: linked).standardizedFileURL == bundledCLI.standardizedFileURL
        status = installed ? "CLI jest zainstalowane: /usr/local/bin/agentbox" : "Ścieżka /usr/local/bin/agentbox prowadzi do innego pliku. Agentbox go nie nadpisze."
    }

    func install() {
        guard let bundledCLI else { status = "Ta kompilacja aplikacji nie zawiera CLI."; return }
        guard !Bundle.main.bundleURL.path.hasPrefix("/Volumes/") else { status = "Najpierw przenieś Agentbox do folderu Aplikacje i uruchom go ponownie."; return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            refresh()
            if !installed { status = "Ścieżka /usr/local/bin/agentbox jest zajęta. Usuń istniejący plik ręcznie, jeśli chcesz go zastąpić." }
            return
        }
        do {
            if fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
                try fm.createSymbolicLink(at: destination, withDestinationURL: bundledCLI)
            } else {
                let escaped = bundledCLI.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let source = "do shell script \"/bin/mkdir -p /usr/local/bin && /bin/ln -s \" & quoted form of \"\(escaped)\" & \" /usr/local/bin/agentbox\" with administrator privileges"
                var scriptError: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&scriptError)
                if let scriptError { throw NSError(domain: "AgentboxCLIInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: scriptError[NSAppleScript.errorMessage] as? String ?? "Nie udało się zainstalować CLI."]) }
            }
            refresh()
        } catch { status = "Nie udało się zainstalować CLI: \(error.localizedDescription)"; installed = false }
    }

    private var bundledCLI: URL? {
        let value = Bundle.main.bundleURL.appending(path: "Contents/Helpers/agentbox")
        return FileManager.default.isExecutableFile(atPath: value.path) ? value : nil
    }
}
