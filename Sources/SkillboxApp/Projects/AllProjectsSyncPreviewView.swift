import SwiftUI
import SkillboxCore

struct AllProjectsSyncPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var plans: [ProjectSyncPlan]?; @State private var error = ""
    @State private var outcomes: [ProjectSyncOutcome] = []
    /// In scope but without a folder: synchronization leaves them out, and this says so.
    @State private var skipped: [Project] = []
    /// A group or a selection; `nil` synchronizes every project.
    var ids: Set<UUID>? = nil
    var title = "Synchronizacja wszystkich projektów"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text("Każdy projekt zapisuje się w całości albo wcale. Błąd zatrzymuje serię, a projekt, który go zgłosił, wraca do stanu sprzed zmiany.").font(.caption).foregroundStyle(.secondary)
            Label("Wynikowe pliki MCP mogą zawierać jawne sekrety, dlatego pozostają wykluczone lokalnie z Git.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            if !skipped.isEmpty {
                Label("Pominięto, bo nie ma folderu: \(skipped.map(\.name).joined(separator: ", ")). Usuniesz je przez Więcej → Usuń projekty bez folderu.", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if plans == nil { ProgressView() }
            else if !outcomes.isEmpty { ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(outcomes) { ProjectSyncOutcomeRow(outcome: $0) } } } }
            else if let plans { ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(plans) { AllProjectsSyncPlanRow(plan: $0) } } } }
            HStack {
                Spacer()
                Button(outcomes.isEmpty ? "Zamknij" : "Gotowe") { dismiss() }
                if outcomes.isEmpty {
                    Button("Synchronizuj \(PolishNoun.project(plans?.count ?? 0))") {
                        Task {
                            // A run that never started is not "everything succeeded": the sheet stays with the reason.
                            guard let result = await model.syncAllProjects(ids: ids) else { error = model.message; return }
                            if result.allSatisfy({ $0.state == .synced || $0.state == .upToDate }) { dismiss() } else { outcomes = result }
                        }
                    }.buttonStyle(.borderedProminent).disabled(!error.isEmpty || plans == nil || model.isWorking)
                }
            }
        }
        .padding(24).sheetFrame(width: 820, height: 700)
        // Okno arkusza zasłania overlay z App.swift, więc postęp musi być rysowany też tutaj.
        .overlay { if model.isWorking { WorkingOverlay(progress: model.progress) } }
        .task { skipped = await model.projectsWithoutFolder(in: ids); do { plans = try await model.previewAllProjectsSync(ids: ids) } catch { self.error = error.localizedDescription; model.reportError(error) } }
    }
}
