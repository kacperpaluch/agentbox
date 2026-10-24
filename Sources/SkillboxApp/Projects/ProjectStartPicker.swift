import SwiftUI

/// "Zacznij od" in the forms that create projects; the template itself is edited in Ustawienia.
struct ProjectStartPicker: View {
    @Binding var start: ProjectStart
    var body: some View {
        Picker("Zacznij od", selection: $start) { ForEach(ProjectStart.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented)
            .help("Domyślne ustawienia zmienisz w Ustawienia → Domyślne dla nowych projektów.")
    }
}
