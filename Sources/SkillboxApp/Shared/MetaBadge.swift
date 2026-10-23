import SwiftUI
import SkillboxCore

/// A small inline label for a fact about a row (a transport type, a tool name, an item count).
/// Neutral by default — pass `tint` only for the rare case that's actually a status, not a fact.
struct MetaBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.row - 1)
            .padding(.vertical, 2)
            .background((tint == .secondary ? Color.secondary : tint).opacity(0.12), in: Capsule())
    }
}
