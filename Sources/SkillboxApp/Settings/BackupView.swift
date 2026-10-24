import SwiftUI
import SkillboxCore

/// Local backup and recovery live together: full backups protect the whole library, while
/// snapshots provide short-term recovery of its metadata.
struct BackupView: View {
    let model: AppModel
    var embedded = false
    @State private var fullBackupToRestore: FullBackupInfo?
    @State private var fullBackupToDelete: FullBackupInfo?
    @State private var snapshotToRestore: LibrarySnapshot?
    @AppStorage("AgentboxAutoBackup") private var autoBackup = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.page + 2) {
                if !embedded {
                    Label("Backup i odzyskiwanie", systemImage: "externaldrive.badge.timemachine").font(.largeTitle.bold())
                    Text("Pełne kopie lokalne chronią bibliotekę, projekty i wszystkie wartości MCP.").foregroundStyle(.secondary)
                }

                GroupBox("Automatyzacja") {
                    VStack(alignment: .leading, spacing: Space.section - 2) {
                        Toggle("Automatycznie twórz pełny backup lokalny raz dziennie", isOn: $autoBackup)
                        Text("Kopie są przechowywane lokalnie w folderze biblioteki. Zawierają także projekty oraz wartości MCP.").rowMetadata()
                        if let latest = model.fullBackups.first {
                            Text("Ostatni pełny backup: \(latest.createdAt, format: .relative(presentation: .named)) (\(latest.createdAt, format: .dateTime))").rowMetadata()
                        } else { Text("Ostatni pełny backup: jeszcze żaden.").rowMetadata() }
                        if let error = model.automaticBackupError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        Text("Pełny workflow: Narzędzia → Odśwież bibliotekę i zsynchronizuj projekty.").rowMetadata()
                    }.padding(Space.row).frame(maxWidth: .infinity, alignment: .leading)
                }
                snapshotsSection

                Divider()

                VStack(alignment: .leading, spacing: Space.section - 2) {
                    Label("Pełny backup lokalny", systemImage: "externaldrive.fill.badge.plus").font(.title2.bold())
                    Text("Cała biblioteka, projekty i wartości MCP. Powstaje raz dziennie; zostaje 14 ostatnich kopii.").foregroundStyle(.secondary)
                    Label("Pliki są czytelne i niezaszyfrowane — nie udostępniaj folderu backups.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    HStack {
                        Button("Utwórz teraz") { Task { await model.createFullBackup() } }.buttonStyle(.borderedProminent)
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
                                        Text(backup.createdAt, format: .dateTime).rowTitle()
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
            .frame(maxWidth: 760, alignment: .leading)
            .padding(Space.page + 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(embedded ? "Ustawienia" : "Backup")
        .task { await model.loadFullBackups(); await model.loadRecovery() }
        .confirmationDialog("Przywrócić pełny backup?", item: $fullBackupToRestore) { backup in Button("Przywróć wszystkie dane", role: .destructive) { Task { await model.restoreFullBackup(backup) } }; Button("Anuluj", role: .cancel) {} } message: { _ in Text("Aktualna biblioteka, projekty, skille, MCP i sekrety zostaną zastąpione. Agentbox najpierw zachowa pełną kopię aktualnego stanu w backups/restore-rollbacks.") }
        .confirmationDialog("Usunąć pełny backup?", item: $fullBackupToDelete) { backup in Button("Usuń backup", role: .destructive) { Task { await model.deleteFullBackup(backup) } }; Button("Anuluj", role: .cancel) {} } message: { _ in Text("Ta kopia zawierająca również sekrety zostanie trwale usunięta z lokalnego folderu backups/full.") }
        .confirmationDialog("Przywrócić snapshot biblioteki?", item: $snapshotToRestore) { snapshotToRestore in
            Button("Przywróć bibliotekę", role: .destructive) { Task { await model.restoreLibrary(snapshotToRestore) } }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in Text("Obecny stan zostanie zachowany jako nowy snapshot. Wrócą metadane biblioteki, w tym mcp.json z wartościami MCP (np. tokenami) z tamtej chwili. Katalog skills i klucz OpenAI zostają bez zmian.") }
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: Space.section - 2) {
            HStack {
                Label("Snapshoty biblioteki", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()
                Button("Odśwież") { Task { await model.loadRecovery() } }.buttonStyle(.bordered)
            }
            Text("10 ostatnich stanów katalogu, tagów i MCP, zapisywanych przed każdą ryzykowną operacją. Pliki projektów odtwarza synchronizacja.").foregroundStyle(.secondary)
            if model.librarySnapshots.isEmpty {
                Text("Brak snapshotów biblioteki.").rowMetadata()
            } else {
                VStack(spacing: Space.row) {
                    ForEach(model.librarySnapshots) { snapshot in
                        HStack {
                            Image(systemName: "externaldrive").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                // When first: ten snapshots minutes apart are told apart by "5 minut temu", not by a timestamp.
                                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                                    Text(snapshot.date, format: .relative(presentation: .named)).rowTitle()
                                    Text(snapshot.date, format: .dateTime).rowMetadata()
                                }
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
