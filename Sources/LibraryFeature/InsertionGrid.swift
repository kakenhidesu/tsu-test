// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// A fixed-column grid that can hold one slot open. While a book is being dragged over a position,
/// every later cell moves forward by one slot, so the reader sees where the book will land instead of
/// guessing from a highlight.
struct InsertionGridLayout: Layout {
    let columns: Int
    let spacing: CGFloat
    let insertionIndex: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 0
        let cell = cellWidth(in: width)
        let height = rowHeight(subviews, cellWidth: cell)
        let rows = rowCount(subviews.count)
        guard rows > 0 else { return CGSize(width: width, height: 0) }
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let cell = cellWidth(in: bounds.width)
        let height = rowHeight(subviews, cellWidth: cell)
        for index in subviews.indices {
            let slot = slotIndex(for: index)
            let row = slot / columns
            let column = slot % columns
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (cell + spacing),
                    y: bounds.minY + CGFloat(row) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: cell, height: height)
            )
        }
    }

    private func slotIndex(for index: Int) -> Int {
        guard let insertionIndex, index >= insertionIndex else { return index }
        return index + 1
    }

    private func rowCount(_ subviewCount: Int) -> Int {
        let slots = subviewCount + (insertionIndex == nil ? 0 : 1)
        return slots == 0 ? 0 : (slots + columns - 1) / columns
    }

    private func cellWidth(in width: CGFloat) -> CGFloat {
        max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
    }

    /// Every cell gets the tallest measured height so a long title cannot make one row disagree with
    /// the slot geometry the drop position was computed from.
    private func rowHeight(_ subviews: Subviews, cellWidth: CGFloat) -> CGFloat {
        subviews.reduce(into: CGFloat(0)) { tallest, subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
            tallest = max(tallest, size.height)
        }
    }
}
