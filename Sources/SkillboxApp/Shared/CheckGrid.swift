import SwiftUI

/// Adaptive columns like `LazyVGrid(columns: [.adaptive(minimum:)])`, but laid out eagerly. A lazy
/// grid inside a `ScrollView` only estimates rows it has not drawn yet, so the content height changes
/// while scrolling and the list jumps back under the cursor. Checkbox lists run to dozens, not
/// thousands, so measuring every row is cheap.
struct CheckGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 8

    private struct Metrics { var columnWidth: CGFloat; var columns: Int; var rowHeights: [CGFloat] }

    private func metrics(_ width: CGFloat?, _ subviews: Subviews) -> Metrics {
        let width = width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
        let columns = max(1, Int((width + spacing) / (minimum + spacing)))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let rowHeights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(proposal).height }.max() ?? 0
        }
        return Metrics(columnWidth: columnWidth, columns: columns, rowHeights: rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = metrics(proposal.width, subviews)
        let height = m.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, m.rowHeights.count - 1))
        return CGSize(width: m.columnWidth * CGFloat(m.columns) + spacing * CGFloat(m.columns - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in m.rowHeights.enumerated() {
            for column in 0..<m.columns {
                let index = row * m.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (m.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: m.columnWidth, height: nil))
            }
            y += height + spacing
        }
    }
}
