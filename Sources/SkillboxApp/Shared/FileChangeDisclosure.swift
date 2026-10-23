import SwiftUI
import SkillboxCore

/// What a synchronization will actually do to one managed file: the difference against what is on
/// disk right now, with the whole resulting content one step further in.
///
/// The counts above this say *how many* entries change; a repository owner deciding whether to let
/// Agentbox write into their project needs to see *what* changes — especially in files like
/// `.mcp.json` and `AGENTS.md`, which are merged with content they wrote themselves.
struct FileChangeDisclosure: View {
    let file: String
    let content: String
    /// The file is not Agentbox's and cannot be read as text, so synchronization will not touch it.
    /// Without this the preview announced a deletion that no longer happens — the fix stopped the
    /// write but left the window saying the opposite.
    var leaveAsIs = false
    let emptyMeansRemoval: String
    @State private var diff: [DiffLine] = []
    @State private var computed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup("Co się zmieni w pliku") {
                Group {
                    if leaveAsIs { Text("Plik nie jest zarządzany przez Agentbox i nie da się go odczytać jako tekst. Zostanie bez zmian.").font(.caption).foregroundStyle(.secondary) }
                    else if content.isEmpty { Text(emptyMeansRemoval).font(.caption).foregroundStyle(.orange) }
                    else if !computed { Text("Liczenie różnicy…").font(.caption).foregroundStyle(.secondary) }
                    else if diff.isEmpty { Text("Plik ma już dokładnie taką treść — nic nie zostanie zapisane.").font(.caption).foregroundStyle(.secondary) }
                    else { VStack(alignment: .leading, spacing: 1) { ForEach(diff) { DiffLineRow(line: $0) } } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            if !content.isEmpty, !leaveAsIs {
                DisclosureGroup("Cała treść po zapisie") {
                    Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
        }
        .task { diff = leaveAsIs ? [] : TextDiff.lines(file: file, content: content); computed = true }
    }
}
