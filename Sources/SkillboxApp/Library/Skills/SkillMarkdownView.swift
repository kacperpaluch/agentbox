import SwiftUI

struct SkillMarkdownView: View {
    let document: SkillMarkdown
    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if let description = document.field("description"), !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
            }
            let others = document.fields.filter { !["name", "description"].contains($0.key) }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(others, id: \.key) { field in Text("\(Text("\(field.key):").bold()) \(field.value)") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if document.field("description") != nil || !others.isEmpty { Divider() }
            // Position is the identity on purpose: blocks are read-only text with no state to keep, and the
            // same paragraph can appear twice in one file.
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, Space.tight)
                case .paragraph(let text):
                    Text(inline(text))
                case .code(let text):
                    Text(text).font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.row)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Bold, italics, code and links; anything else stays as written.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
