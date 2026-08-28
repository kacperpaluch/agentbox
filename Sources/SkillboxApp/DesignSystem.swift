import SwiftUI
import AppKit
import Combine
import SkillboxCore

// MARK: - Spacing

/// One shared scale instead of every view inventing its own numbers (7, 9, 10, 2, 6…). Four sizes
/// cover everything the app needs: `tight` inside a control, `row` between a row's own lines,
/// `section` between unrelated groups, `page` around a view's edges.
enum Space {
    static let tight: CGFloat = 4
    static let row: CGFloat = 8
    static let section: CGFloat = 12
    static let page: CGFloat = 16
}

// MARK: - Typography roles

/// Every list row in the app follows the same two-line shape: a title line that answers "what is
/// this", and a metadata line — always secondary, always smaller — that answers "what should I know
/// about it". Reaching for these instead of ad hoc `.font()` calls is what keeps a name from
/// competing with its own byte count for the reader's attention.
extension View {
    /// The one thing a row is about: a skill's name, a project's name, a server's name.
    func rowTitle() -> some View { self.font(.body.weight(.medium)) }
    /// Supporting facts about a row — path, counts, timestamps. Always quieter than the title.
    func rowMetadata() -> some View { self.font(.caption).foregroundStyle(.secondary) }
    /// A group or section label, e.g. a folder header in a grouped list.
    func sectionLabel() -> some View { self.font(.subheadline.weight(.semibold)) }
}

// MARK: - Shared toolbar

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

// MARK: - Tags and small badges

/// A tag pill in one neutral style everywhere. Tags used to get a color hashed from their name —
/// seven hues fighting for attention with every status badge and icon tint on screen. A tag is
/// metadata, not a status, so it now reads quietly like the rest of a row's second line; the
/// reader's eye is free to land on the handful of colors that actually mean something (an update
/// pending, a sync error, a destructive action).
struct TagPill: View {
    let tag: String
    var body: some View {
        Text("#\(tag)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.row - 1)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: Space.tight) {
            ForEach(tags.prefix(4), id: \.self) { TagPill(tag: $0) }
            if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

/// A small inline label for a fact about a row (a transport type, a tool name, an item count).
/// Neutral by default — pass `tint` only for the rare case that's actually a status, not a fact.
struct MetaBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.row - 1)
            .padding(.vertical, 2)
            .background((tint == .secondary ? Color.secondary : tint).opacity(0.12), in: Capsule())
    }
}

// MARK: - Row action menu

/// Secondary actions for a list row, collapsed into one "⋯" menu instead of a row of equally-weighted
/// buttons. The row keeps at most one prominent primary action beside this.
struct RowMenu<MenuContent: View>: View {
    @ViewBuilder var content: MenuContent
    var body: some View {
        Menu { content } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
    }
}

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

/// Sizing every sheet in the app shares.
///
/// A hard `height:` is what put `Zapisz` under the Dock: the editors were tall enough to work on an
/// external display and too tall on a laptop, and a sheet does not shrink itself to fit. The height
/// asked for here is treated as an ideal and capped to what the active screen actually shows, so the
/// same sheet is roomy on a big monitor and merely scrollable on a small one — without a second set
/// of numbers to keep in sync.
extension View {
    func sheetFrame(width: CGFloat, height: CGFloat) -> some View {
        // `visibleFrame` already excludes the menu bar and the Dock; the margin keeps the sheet clear
        // of the window's title bar and its own shadow.
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        return frame(width: width, height: min(height, max(360, available)))
    }
}
