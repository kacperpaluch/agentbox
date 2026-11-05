import SwiftUI
import SkillboxCore

/// The question the user asked for: a new subfolder in a watched parent folder is offered as a
/// project instead of being noticed only when something is missing from it.
struct DetectedFoldersBanner: View {
    let model: AppModel
    let review: () -> Void
    /// Called with the projects just added, so they go through the usual synchronization preview.
    let synchronize: ([Project]) -> Void

    var body: some View {
        HStack(spacing: Space.section - 2) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.detectedFolders.count == 1 ? "Nowy podfolder w obserwowanym folderze" : "Nowe podfoldery w obserwowanych folderach: \(model.detectedFolders.count)").font(.callout.weight(.medium))
                Text(model.detectedFolders.prefix(3).map(\.name).joined(separator: ", ") + (model.detectedFolders.count > 3 ? "…" : "")).rowMetadata().lineLimit(1)
            }
            Spacer()
            Button("Przejrzyj…", action: review).buttonStyle(.borderedProminent)
            Button("Dodaj i synchronizuj…") { let folders = model.detectedFolders; Task { if let added = await model.addDetected(folders), !added.isEmpty { synchronize(added) } } }.buttonStyle(.bordered).disabled(model.isWorking)
        }
        .padding(.horizontal, Space.page).padding(.vertical, Space.row + 2)
        .background(.quaternary.opacity(0.4))
    }
}
