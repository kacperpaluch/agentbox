import SwiftUI
import SkillboxCore

/// The spinner shown over the whole window while something long runs. With countable work it
/// becomes a real bar with "3/30" and the name of the project being written, because "kręci się od
/// minuty" and "kręci się, zostało 27 projektów" are very different things to look at.
struct WorkingOverlay: View {
    let progress: SyncProgress?
    var body: some View {
        // The backdrop covers the whole window and takes every click. The panel alone left the rest
        // of the window live, so a second action could start while the first was still writing —
        // two transactions on the same project interleaving on the service actor, and the first one
        // to finish clearing `isWorking` for both.
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            if let progress, progress.total > 1 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 260)
                HStack {
                    Text(progress.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(width: 260)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
