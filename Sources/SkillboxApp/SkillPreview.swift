import SwiftUI

/// SKILL.md the way a reader sees it: the front matter as fields, the body as formatted text instead
/// of raw source in a monospaced font. Editing still works on the raw file.
struct SkillMarkdown: Equatable {
    struct Field: Equatable { var key: String; var value: String }
    enum Block: Equatable { case heading(level: Int, text: String), paragraph(String), code(String) }
    var fields: [Field] = []
    var blocks: [Block] = []

    func field(_ key: String) -> String? { fields.first { $0.key == key }?.value }

    static func parse(_ text: String) -> SkillMarkdown {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result = SkillMarkdown()
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                // An indented line continues the value above it (a folded YAML block).
                if line.first == " " || line.first == "\t", !result.fields.isEmpty {
                    let part = line.trimmingCharacters(in: .whitespaces)
                    result.fields[result.fields.count - 1].value += (result.fields[result.fields.count - 1].value.isEmpty ? "" : " ") + part
                } else if let colon = line.firstIndex(of: ":") {
                    var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if [">", "|", ">-", "|-"].contains(value) { value = "" }
                    result.fields.append(Field(key: line[..<colon].trimmingCharacters(in: .whitespaces), value: value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
                }
            }
            lines = Array(lines[(end + 1)...])
        }
        var paragraph: [String] = [], code: [String]? = nil
        func flush() { if !paragraph.isEmpty { result.blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = code { result.blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
            } else if code != nil {
                code?.append(line)
            } else if let hashes = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flush()
                result.blocks.append(.heading(level: line.distance(from: hashes.lowerBound, to: hashes.upperBound) - 1, text: String(line[hashes.upperBound...])))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        // An unclosed fence still shows what was written.
        if let open = code { result.blocks.append(.code(open.joined(separator: "\n"))) }
        return result
    }
}

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
                    ForEach(others, id: \.key) { field in Text("\(field.key): ").bold() + Text(field.value) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if document.field("description") != nil || !others.isEmpty { Divider() }
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
