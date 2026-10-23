import SwiftUI
import SkillboxCore

/// Pinned action row for a sheet: a divider and a bar that stay put while the form above scrolls.
///
/// Long editors used to keep `Anuluj`/`Zapisz` at the bottom of the scrolled content, so on a
/// display shorter than the sheet the buttons ended up under the Dock with no way to reach them.
struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack { Spacer(); content }
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.section - 4)
                .background(.bar)
        }
    }
}
