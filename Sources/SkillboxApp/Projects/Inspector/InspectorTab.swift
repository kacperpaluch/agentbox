/// The two questions the inspector answers about a project: what it gets, and what is chosen for it.
/// Installed Claude plugins are part of the first answer; installing one by hand is a rare action
/// in the inspector's "⋯" menu, not a tab that is empty for almost every project.
enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Przegląd", attachments = "Wybór"
    var id: String { rawValue }
}
