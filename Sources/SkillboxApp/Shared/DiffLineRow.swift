import SwiftUI
import SkillboxCore

struct DiffLineRow: View {
    let line: DiffLine
    var body: some View {
        Text(prefix + line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var prefix: String {
        switch line.kind {
        case .added: return "+ "
        case .removed: return "− "
        case .same: return "  "
        case .gap: return ""
        }
    }
    private var tint: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .orange
        case .same: return .secondary
        case .gap: return .secondary
        }
    }
}
