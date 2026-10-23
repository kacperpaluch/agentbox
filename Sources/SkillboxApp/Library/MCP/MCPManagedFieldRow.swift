import SwiftUI
import SkillboxCore

struct MCPManagedFieldRow: View {
    @Binding var field: MCPManagedField
    let onDelete: () -> Void
    var body: some View { HStack { Picker("Miejsce", selection: $field.location) { Text("Zmienna").tag(MCPImportField.Location.environment); Text("Nagłówek").tag(MCPImportField.Location.header) }.labelsHidden().frame(width: 105); TextField("Nazwa", text: $field.key).frame(minWidth: 120); TextField("Wartość lub ${ZMIENNA}", text: $field.value); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } } }
}
