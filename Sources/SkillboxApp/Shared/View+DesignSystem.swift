import SwiftUI
import SkillboxCore

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
