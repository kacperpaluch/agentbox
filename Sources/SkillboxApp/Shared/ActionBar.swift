import SwiftUI
import SkillboxCore

/// Shared section header. Every list section puts its actions here, at the top, in the same order:
/// the primary action first and prominent, secondary actions bordered beside it.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.row) { content }.padding(.horizontal, Space.section).padding(.vertical, Space.row + 2)
            Divider()
        }
    }
}
