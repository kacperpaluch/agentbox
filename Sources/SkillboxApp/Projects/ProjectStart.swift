/// Where a new project's choice starts. The defaults are a template copied once, never a link, so
/// picking them here is the only moment they matter.
enum ProjectStart: String, CaseIterable, Identifiable {
    case defaults = "Domyślne ustawienia", empty = "Pusty wybór"
    var id: String { rawValue }
}
