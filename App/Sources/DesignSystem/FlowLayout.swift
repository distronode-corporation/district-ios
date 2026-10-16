import SwiftUI

/// Views laid out left to right, wrapping onto a new line when the next one would not fit,
/// as words wrap in a paragraph.
///
/// ⚠️ FOR A SHORT ROW OF CHIPS WHOSE LABELS CHANGE WITH THE LANGUAGE (the Desk's status
/// filters). A sideways scroller hid the last one at the column's edge in French
/// (« Réglé 1 », 3.0.1 visual QA); wrapping keeps every chip whole at any column width.
///
/// ⚠️ A VIEW WIDER THAN THE LINE GETS A LINE OF ITS OWN, offered the line's width, so its
/// text wraps inside it rather than running past the edge.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let frames = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> FlowArrangement {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            width: width,
            spacing: spacing,
            lineSpacing: lineSpacing
        ) { index, offered in
            subviews[index].sizeThatFits(ProposedViewSize(width: offered, height: nil))
        }
    }

    /// Where each view goes, given its ideal size and the width offered (nil: one line).
    ///
    /// `refit` measures a view again at a narrower width, for one wider than the line.
    static func arrange(
        sizes: [CGSize],
        width: CGFloat?,
        spacing: CGFloat,
        lineSpacing: CGFloat,
        refit: (Int, CGFloat) -> CGSize = { _, offered in CGSize(width: offered, height: 0) }
    ) -> FlowArrangement {
        var frames: [CGRect] = []
        var cursor: CGFloat = 0
        var lineTop: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (index, ideal) in sizes.enumerated() {
            var size = ideal
            if let width, size.width > width {
                let fitted = refit(index, width)
                size = CGSize(width: width, height: max(fitted.height, ideal.height))
            }
            if let width, cursor > 0, cursor + size.width > width {
                lineTop += lineHeight + lineSpacing
                cursor = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: cursor, y: lineTop), size: size))
            widest = max(widest, cursor + size.width)
            cursor += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        let height = frames.isEmpty ? 0 : lineTop + lineHeight
        return FlowArrangement(frames: frames, size: CGSize(width: width ?? widest, height: height))
    }
}

/// ``FlowLayout``'s answer: each view's frame, and the size of the whole.
struct FlowArrangement: Equatable {
    let frames: [CGRect]
    let size: CGSize
}
