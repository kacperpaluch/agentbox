import SwiftUI
import AppKit
import SkillboxCore

struct OperationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [OperationLogEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Historia operacji").font(.title2.bold())
                Spacer()
                if !entries.isEmpty { Button("Kopiuj wszystko") { copy(entries.map(\.copyText).joined(separator: "\n")) } }
                Button("Zamknij") { dismiss() }
            }
            Text("Ostatnie 100 operacji, także z poprzednich uruchomień. Komunikaty mogą zawierać ścieżki i fragmenty konfiguracji — sprawdź je, zanim wkleisz je komuś.").font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty {
                ContentUnavailableView("Brak operacji", systemImage: "clock", description: Text("Sukcesy i błędy pojawią się tutaj."))
            } else {
                List(entries) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.kind == .error ? "xmark.octagon.fill" : "checkmark.circle.fill").foregroundStyle(entry.kind == .error ? .red : .green)
                        VStack(alignment: .leading) {
                            Text(entry.text).textSelection(.enabled)
                            Text(entry.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { copy(entry.copyText) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Kopiuj wpis")
                            .accessibilityLabel("Kopiuj wpis")
                    }
                }
            }
        }
        .padding(20).sheetFrame(width: 680, height: 520)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
