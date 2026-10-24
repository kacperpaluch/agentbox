import SwiftUI
import SkillboxCore

/// A folder row in the inspector: what the group is and the two things a folder is opened for.
struct GroupInspector: View {
    let model: AppModel
    let group: ProjectGroup
    let perform: (ProjectRowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            Label(group.name, systemImage: group.root == nil ? "folder" : "folder.badge.gearshape").font(.title3.bold())
            Text(group.path).rowMetadata().lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Text(summary).font(.callout)
            HStack {
                Button("Synchronizuj grupę…") { perform(.syncGroup(group)) }.disabled(group.projects.isEmpty || model.isWorking)
                if let root = group.root { Button("Ustawienia folderu…") { perform(.rootSettings(root)) } }
                else { Button("Wspólne ustawienia…") { perform(.setUpRoot(group)) } }
            }
            Spacer()
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let count = PolishNoun.project(group.projects.count)
        guard let root = group.root else { return "\(count) bez wspólnych ustawień." }
        return "\(count); ustawień folderu używa \(model.followers(of: root))."
    }
}
