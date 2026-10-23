import SwiftUI
import SkillboxCore

/// The one place in the app where you say what lands somewhere: which clients, which skills, which
/// MCP servers, which document.
///
/// Every editor uses it — a project, a parent folder, a batch add, a folder being set up from
/// existing projects, and the Mac itself. They used to pass eight separate bindings each and keep
/// eight matching `@State` properties, four times over; a project and a folder could quietly drift
/// apart because adding a field meant remembering four call sites. Now they hold one
/// `AttachmentSelection` and hand it here.
extension EnvironmentValues {
    /// `AppModel.enabledTools`, set once on the window so every editor sheet offers the same clients.
    @Entry var enabledTools: [Tool] = Tool.allCases
}
