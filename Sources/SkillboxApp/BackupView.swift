import SwiftUI
import AppKit
import Combine
import SkillboxCore
import Sparkle

/// Backup and recovery together, because "how do I protect and get back my data" is one question
/// with four mechanisms behind it (Git, snapshots, restore-from-remote, full local copy) — it was
/// never two separate sections in the author's head, so it no longer is one in the sidebar either.
struct BackupView: View {
    @ObservedObject var model: AppModel
    @State private var remote = ""
    @State private var fullBackupToRestore: FullBackupInfo?
    @State private var fullBackupToDelete: FullBackupInfo?
    @State private var snapshotToRestore: LibrarySnapshot?
    @State private var restoreRemote = ""
    @State private var showRestoreConfirmation = false
    @AppStorage("AgentboxAutoBackup") private var autoBackup = true
    @AppStorage("AgentboxAutoPush") private var autoPush = false
    private let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .medium; return value }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.page + 2) {
                Label("Backup i odzyskiwanie", systemImage: "externaldrive.badge.timemachine").font(.largeTitle.bold())
                Text("Do Git trafiają skille, tagi i konfiguracja MCP bez sekretów. Lokalne ścieżki projektów pozostają tylko na tym Macu.").foregroundStyle(.secondary)

                GroupBox("Automatyzacja") {
                    VStack(alignment: .leading, spacing: Space.section - 2) {
                        Toggle("Automatycznie twórz lokalne commity", isOn: $autoBackup)
                        Toggle("Automatycznie wysyłaj do origin", isOn: $autoPush).disabled(!autoBackup)
                        Text("Zmiany skilli, tagów i serwerów są łączone przez 5 sekund w jeden commit. Pierwszy backup i konfigurację origin wykonaj ręcznie.").rowMetadata()
                    }.padding(Space.row)
                }
                TextField("Git remote, np. git@github.com:user/agentbox-backup.git", text: $remote).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Wykonaj backup teraz") { Task { await model.backup(remote: remote) } }.buttonStyle(.borderedProminent)
                    Button("Odśwież status") { Task { await model.loadBackupStatus() } }.buttonStyle(.bordered)
                    Spacer()
                }
                GroupBox("Status") { Text(model.backupStatus.isEmpty ? "Kliknij „Odśwież status”." : model.backupStatus).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(Space.row) }

                Divider()

                snapshotsSection

                Divider()

                VStack(alignment: .leading, spacing: Space.section - 2) {
                    Label("Odtworzenie biblioteki ze zdalnego repozytorium", systemImage: "arrow.down.circle").font(.title2.bold())
                    Text("Pobiera skille, katalog i konfigurację MCP z repozytorium backupu — na przykład przy konfiguracji nowego Maca. Projekty, lokalne ścieżki i sekrety na tym Macu pozostają bez zmian. Przed zapisem powstaje pełny backup lokalny.").foregroundStyle(.secondary)
                    TextField("Adres repozytorium do odtworzenia", text: $restoreRemote).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Odtwórz bibliotekę") { showRestoreConfirmation = true }.buttonStyle(.bordered).disabled(restoreRemote.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                        Spacer()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: Space.section - 2) {
                    Label("Pełny backup lokalny", systemImage: "externaldrive.fill.badge.plus").font(.title2.bold())
                    Label("Zawiera również projekty, lokalne ścieżki, wszystkie skille, MCP, sekrety i klucze AI. Pliki są czytelne i niezaszyfrowane — nie udostępniaj folderu backups.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    HStack {
                        Button("Utwórz pełny backup") { Task { await model.createFullBackup() } }.buttonStyle(.borderedProminent)
                        Button("Odśwież listę") { Task { await model.loadFullBackups() } }.buttonStyle(.bordered)
                        Spacer()
                        Text("\(model.rootPath)/backups/full").rowMetadata().textSelection(.enabled)
                    }
                    GroupBox("Dostępne pełne backupy") {
                        VStack(spacing: Space.row) {
                            if model.fullBackups.isEmpty { Text("Brak pełnych backupów.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                            ForEach(model.fullBackups) { backup in
                                HStack {
                                    Image(systemName: "archivebox.fill").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(formatter.string(from: backup.createdAt)).rowTitle()
                                        Text("Agentbox \(backup.applicationVersion) · \(backup.name)").rowMetadata()
                                    }
                                    Spacer()
                                    Button("Przywróć") { fullBackupToRestore = backup }.buttonStyle(.bordered)
                                    Button("Usuń", role: .destructive) { fullBackupToDelete = backup }.buttonStyle(.bordered)
                                }
                            }
                        }.padding(Space.row)
                    }
                }
            }
            .padding(Space.page + 12)
        }
        .navigationTitle("Backup")
        .task { await model.loadBackupStatus(); await model.loadFullBackups(); await model.loadRecovery() }
        .confirmationDialog("Przywrócić pełny backup?", isPresented: Binding(get: { fullBackupToRestore != nil }, set: { if !$0 { fullBackupToRestore = nil } })) { Button("Przywróć wszystkie dane", role: .destructive) { if let backup = fullBackupToRestore { Task { await model.restoreFullBackup(backup) } }; fullBackupToRestore = nil }; Button("Anuluj", role: .cancel) { fullBackupToRestore = nil } } message: { Text("Aktualna biblioteka, projekty, skille, MCP i sekrety zostaną zastąpione. Agentbox najpierw zachowa pełną kopię aktualnego stanu w backups/restore-rollbacks.") }
        .confirmationDialog("Usunąć pełny backup?", isPresented: Binding(get: { fullBackupToDelete != nil }, set: { if !$0 { fullBackupToDelete = nil } })) { Button("Usuń backup", role: .destructive) { if let backup = fullBackupToDelete { Task { await model.deleteFullBackup(backup) } }; fullBackupToDelete = nil }; Button("Anuluj", role: .cancel) { fullBackupToDelete = nil } } message: { Text("Ta kopia zawierająca również sekrety zostanie trwale usunięta z lokalnego folderu backups/full.") }
        .confirmationDialog("Odtworzyć bibliotekę z repozytorium?", isPresented: $showRestoreConfirmation) {
            Button("Odtwórz bibliotekę", role: .destructive) { Task { await model.restoreLibraryFromRemote(restoreRemote.trimmingCharacters(in: .whitespaces)) } }
            Button("Anuluj", role: .cancel) { }
        } message: { Text("Katalog skilli, catalog.json i mcp.json zostaną zastąpione zawartością repozytorium. Projekty, lokalne ścieżki i sekrety pozostaną bez zmian, a aktualny stan zostanie zapisany jako pełny backup lokalny.") }
        .confirmationDialog("Przywrócić snapshot biblioteki?", isPresented: Binding(get: { snapshotToRestore != nil }, set: { if !$0 { snapshotToRestore = nil } })) {
            Button("Przywróć bibliotekę", role: .destructive) { if let snapshotToRestore { Task { await model.restoreLibrary(snapshotToRestore) } }; snapshotToRestore = nil }
            Button("Anuluj", role: .cancel) { snapshotToRestore = nil }
        } message: { Text("Aktualny stan zostanie zachowany jako nowy snapshot. Sekrety i katalog skills nie zostaną zmienione.") }
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: Space.section - 2) {
            HStack {
                Label("Snapshoty biblioteki", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()
                Button("Odśwież") { Task { await model.loadRecovery() } }.buttonStyle(.bordered)
            }
            Text("Agentbox zachowuje automatycznie 10 ostatnich stanów katalogu, tagów i MCP — przed każdą ryzykowną operacją. Pliki w folderach projektów odtwarza ponowna synchronizacja, a czyści „Usuń i posprzątaj pliki” w Projektach.").foregroundStyle(.secondary)
            if model.librarySnapshots.isEmpty {
                Text("Brak snapshotów biblioteki.").rowMetadata()
            } else {
                VStack(spacing: Space.row) {
                    ForEach(model.librarySnapshots) { snapshot in
                        HStack {
                            Image(systemName: "externaldrive").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatter.string(from: snapshot.date)).rowTitle()
                                Text(snapshot.files.joined(separator: " · ")).rowMetadata()
                            }
                            Spacer()
                            Button("Przywróć") { snapshotToRestore = snapshot }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
}
@MainActor final class UpdateSettingsModel: ObservableObject {
    @Published var canCheckForUpdates: Bool
    @Published var automaticallyChecks: Bool
    @Published var automaticallyDownloads: Bool
    private let updater: SPUUpdater
    private var cancellables = Set<AnyCancellable>()

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyDownloads = $0 }.store(in: &cancellables)
    }

    func setAutomaticallyChecks(_ value: Bool) { updater.automaticallyChecksForUpdates = value }
    func setAutomaticallyDownloads(_ value: Bool) { updater.automaticallyDownloadsUpdates = value }
    func check() { updater.checkForUpdates() }
}
struct CheckForUpdatesView: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { Button("Sprawdź aktualizacje…") { model.check() }.disabled(!model.canCheckForUpdates) }
}
struct UpdateSettingsCard: View {
    @StateObject private var model: UpdateSettingsModel
    init(updater: SPUUpdater) { _model = StateObject(wrappedValue: UpdateSettingsModel(updater: updater)) }
    var body: some View { GroupBox("Aktualizacje Agentbox") { VStack(alignment: .leading, spacing: 10) {
        Toggle("Automatycznie sprawdzaj aktualizacje", isOn: Binding(
            get: { model.automaticallyChecks },
            set: { value in model.setAutomaticallyChecks(value) }
        ))
        Toggle("Automatycznie pobieraj i instaluj", isOn: Binding(
            get: { model.automaticallyDownloads },
            set: { value in model.setAutomaticallyDownloads(value) }
        )).disabled(!model.automaticallyChecks)
        HStack { Text(AppVersion.display).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Sprawdź teraz") { model.check() }.disabled(!model.canCheckForUpdates) }
        Text("Aktualizacje są pobierane z GitHub Releases i weryfikowane podpisem EdDSA przed instalacją.").font(.caption).foregroundStyle(.secondary)
    }.padding(8) } }
}
@MainActor final class CLISettingsModel: ObservableObject {
    @Published var status = ""
    @Published var installed = false
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
struct CLISettingsCard: View {
    @StateObject private var model = CLISettingsModel()
    var body: some View { GroupBox("Wiersz poleceń (CLI)") { VStack(alignment: .leading, spacing: 10) {
        Text(model.status).font(.caption).foregroundStyle(model.installed ? .green : .secondary).textSelection(.enabled)
        HStack { Text("Po instalacji użyj np. `agentbox project list` w nowym oknie Terminala.").font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.installed ? "Zainstalowano" : "Zainstaluj CLI") { model.install() }.disabled(model.installed) }
    }.padding(8) }.onAppear { model.refresh() } }
}
