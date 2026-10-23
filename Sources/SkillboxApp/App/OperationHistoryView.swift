import SwiftUI
import SkillboxCore

struct OperationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [OperationLogEntry]
    var body: some View { VStack(alignment: .leading, spacing: 14) { HStack { Text("Historia operacji").font(.title2.bold()); Spacer(); Button("Zamknij") { dismiss() } }; if entries.isEmpty { ContentUnavailableView("Brak operacji", systemImage: "clock", description: Text("Sukcesy i błędy z tej sesji pojawią się tutaj.")) } else { List(entries) { entry in HStack(alignment: .top) { Image(systemName: entry.kind == .error ? "xmark.octagon.fill" : entry.kind == .success ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(entry.kind == .error ? .red : entry.kind == .success ? .green : .blue); VStack(alignment: .leading) { Text(entry.text).textSelection(.enabled); Text(entry.date, format: .dateTime).font(.caption).foregroundStyle(.secondary) } } } } }.padding(20).sheetFrame(width: 680, height: 520) }
}
