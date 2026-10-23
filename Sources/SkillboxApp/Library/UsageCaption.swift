import SwiftUI
import SkillboxCore

/// "Używany przez …" under a library row, read in the background so the list never waits for it.
/// `key` changes whenever an answer could: the item, or any selection in the library.
struct UsageCaption: View {
    let key: AnyHashable
    let load: () async -> UsageReport
    @State private var report: UsageReport?
    var body: some View {
        Group {
            if let summary = report?.summary { Text("Używany przez: \(summary)") }
            else if report != nil { Text("Nieprzypisany do żadnego projektu").foregroundStyle(.tertiary) }
            else { Text(" ") }
        }
        .rowMetadata().lineLimit(1)
        .task(id: key) { report = await load() }
    }
}
