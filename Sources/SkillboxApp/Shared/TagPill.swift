import SwiftUI
import SkillboxCore

/// A tag pill in one neutral style everywhere. Tags used to get a color hashed from their name —
/// seven hues fighting for attention with every status badge and icon tint on screen. A tag is
/// metadata, not a status, so it now reads quietly like the rest of a row's second line; the
/// reader's eye is free to land on the handful of colors that actually mean something (an update
/// pending, a sync error, a destructive action).
struct TagPill: View {
    let tag: String
    var body: some View {
        Text("#\(tag)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.row - 1)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
