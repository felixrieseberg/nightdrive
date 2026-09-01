import SwiftUI

/// Lays out subviews left to right, wrapping onto further rows once the
/// content outgrows the proposed width.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  /// When true, `sizeThatFits` reports the proposed width rather than the
  /// widest row, so the layout stretches to fill its container.
  var fillsProposedWidth = false

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGSize {
    let rows = arrange(subviews: subviews, in: proposal.width ?? .infinity)
    let contentWidth = rows.map { $0.frames.last?.maxX ?? 0 }.max() ?? 0
    let width = fillsProposedWidth ? (proposal.width ?? contentWidth) : contentWidth
    let height = rows.last.map { $0.offset + $0.height } ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for row in arrange(subviews: subviews, in: bounds.width) {
      for (index, frame) in zip(row.indices, row.frames) {
        subviews[index].place(
          at: CGPoint(
            x: bounds.minX + frame.minX,
            y: bounds.minY + row.offset + (row.height - frame.height) / 2),
          proposal: ProposedViewSize(frame.size))
      }
    }
  }

  private struct Row {
    var indices: [Int] = []
    var frames: [CGRect] = []
    var offset: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    var x: CGFloat = 0
    var y: CGFloat = 0
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        rows.append(row)
        y += row.height + spacing
        row = Row(offset: y)
        x = 0
      }
      row.indices.append(index)
      row.frames.append(CGRect(x: x, y: 0, width: size.width, height: size.height))
      row.height = max(row.height, size.height)
      x += size.width + spacing
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
