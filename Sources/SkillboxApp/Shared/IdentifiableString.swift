import SwiftUI
import SkillboxCore

/// Wraps a `String` so it can back a `.sheet(item:)` — used to present the bulk JSON editor
/// pre-filled with a freshly generated export instead of an always-empty `.sheet(isPresented:)`.
struct IdentifiableString: Identifiable { let value: String; var id: String { value } }
