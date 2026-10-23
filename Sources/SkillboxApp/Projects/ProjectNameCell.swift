import SwiftUI
import SkillboxCore

/// First column: a group's folder with its counts and path, or a project's name with its path.
struct ProjectNameCell: View {
    let row: ProjectTableRow
    let pending: Int
    let problems: Int

    var body: some View {
        if let project = row.project {
            HStack(spacing: Space.row) {
                Text(project.name).rowTitle()
                Text(project.path).rowMetadata().lineLimit(1).truncationMode(.middle).help(project.path)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.tight + 2) {
                    Label(row.group.name, systemImage: row.group.root == nil ? "folder" : "folder.badge.gearshape").sectionLabel()
                    Text("\(row.group.projects.count)").rowMetadata()
                    if let root = row.group.root, root.watchesNewFolders {
                        Image(systemName: "eye").foregroundStyle(.secondary)
                            .accessibilityLabel("Obserwowany").help("Agentbox pyta o nowe podfoldery w tym folderze")
                    }
                }
                Text(row.group.path).rowMetadata().lineLimit(1).truncationMode(.middle).help(row.group.path)
            }
            .padding(.vertical, 2)
        }
    }
}
