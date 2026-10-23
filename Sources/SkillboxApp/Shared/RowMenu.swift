import SwiftUI
import SkillboxCore

/// Secondary actions for a list row, collapsed into one "⋯" menu instead of a row of equally-weighted
/// buttons. The row keeps at most one prominent primary action beside this.
struct RowMenu<MenuContent: View>: View {
    @ViewBuilder var content: MenuContent
    var body: some View {
        // A title VoiceOver can read; the row only shows the icon.
        Menu("Więcej akcji", systemImage: "ellipsis.circle") { content }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .frame(width: 28)
    }
}
