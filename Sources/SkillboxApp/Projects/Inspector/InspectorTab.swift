/// The three questions the inspector answers about a project: what it gets, what is chosen for it,
/// and which Claude plugins Claude Code reports as installed in it.
enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Przegląd", attachments = "Wybór", plugins = "Pluginy"
    var id: String { rawValue }
}
