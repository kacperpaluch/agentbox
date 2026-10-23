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
        var lines = text.replacing("\r\n", with: "\n").components(separatedBy: "\n")
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
