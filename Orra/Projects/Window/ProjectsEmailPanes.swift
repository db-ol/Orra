import AppKit
import SwiftUI

// MARK: Compare with Original

extension ProjectsEmailArea {
    /// The email view's bars and panes, top to bottom: Back to Previous Email and the bar of
    /// the comparison, each as wide as the view, then the panes in the room left. The one
    /// scroll of the email view takes all of it. While comparing, Original Email and
    /// Explanation and Draft share it with a line between them: side by side from
    /// `sideBySideWidth`, and one above the other in a narrower view. One layout whose values
    /// change, so the last pane, which holds the draft's editor, keeps its place in every
    /// arrangement, and no view changes when the view's width crosses that line.
    struct Panes: Layout {
        /// Marks a bar, see `bar(_:)`.
        struct IsBar: LayoutValueKey {
            static let defaultValue = false
        }

        /// The room a vertical scroll bar takes beside the content of a pane that scrolls,
        /// see `scrollerWidth()`.
        var scroller: CGFloat = 0

        /// The padding around a pane's content, as around the email view's.
        static let padding: CGFloat = 20
        /// The narrowest content of a pane beside the other: the change box keeps Change
        /// Draft beside its field from 300 points (DraftSection's ChangeBox), the reply
        /// buttons keep one row in English, and a line holds about 45 Latin letters or 23
        /// Chinese characters, which still reads well.
        static let paneContentWidth: CGFloat = 300
        /// The narrowest email view that shows the panes side by side: two panes with that
        /// content and their padding, and the line between them, 681 points. With the
        /// sidebar hidden and the list at its ideal 340 points, the email view is 699 points
        /// wide in the window's first size, 1,040 by 640, so the panes stand side by side
        /// there, and 419 at its smallest, 760 by 420, where they stand one above the other.
        /// Scroll bars that take room change only how the panes share the width, see
        /// `frames(in:panes:scroller:)`.
        static let sideBySideWidth = 2 * (paneContentWidth + 2 * padding) + 1
        /// The lowest the lower pane gets in a view tall enough for it: the draft's editor at
        /// its smallest, 200 points with a padding of 6 above and below, fits in it whole.
        static let lowerPaneMinimumHeight: CGFloat = 212

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var top = bounds.minY
            var panes: [LayoutSubview] = []
            for subview in subviews {
                guard subview[IsBar.self] else {
                    panes.append(subview)
                    continue
                }
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: top), proposal: ProposedViewSize(width: bounds.width, height: height))
                top += height
            }
            let room = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
            for (pane, frame) in zip(panes, Self.frames(in: room, panes: panes.count, scroller: scroller)) {
                pane.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
            }
        }

        /// The room a vertical scroll bar takes from the content of a scroll view now: its
        /// width where scroll bars always show, as with a mouse, and none where they show
        /// only while scrolling, as with a trackpad.
        @MainActor static func scrollerWidth() -> CGFloat {
            NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        }

        /// Whether the panes of the comparison stand side by side in a view this wide.
        static func isSideBySide(width: CGFloat) -> Bool {
            width >= sideBySideWidth
        }

        /// The frames of the panes in the room under the bars: all of it for the one scroll,
        /// or, for the three views of the comparison, Original Email, the line and
        /// Explanation and Draft. Side by side they share the width once Explanation and
        /// Draft, which nearly always scrolls, has the room of its scroll bar, `scroller`.
        /// Where scroll bars take room, as with a mouse, its content keeps 300 points from
        /// `sideBySideWidth` and the bar's width together, which the window's first size
        /// has, and a little less in a narrower view. One above the other they share the
        /// height, unless the lower pane would get less than `lowerPaneMinimumHeight`, which
        /// it then gets, as far as the room allows.
        static func frames(in room: CGRect, panes: Int, scroller: CGFloat = 0) -> [CGRect] {
            guard panes == 3 else { return Array(repeating: room, count: panes) }
            if isSideBySide(width: room.width) {
                let left = ((room.width - 1 - scroller) / 2).rounded(.down)
                return [
                    CGRect(x: room.minX, y: room.minY, width: left, height: room.height),
                    CGRect(x: room.minX + left, y: room.minY, width: 1, height: room.height),
                    CGRect(x: room.minX + left + 1, y: room.minY, width: room.width - left - 1, height: room.height),
                ]
            }
            let height = max(0, room.height - 1)
            let lower = min(height, max((height / 2).rounded(.up), lowerPaneMinimumHeight))
            let upper = height - lower
            return [
                CGRect(x: room.minX, y: room.minY, width: room.width, height: upper),
                CGRect(x: room.minX, y: room.minY + upper, width: room.width, height: 1),
                CGRect(x: room.minX, y: room.minY + upper + 1, width: room.width, height: lower),
            ]
        }
    }

    /// A bar above the panes, as wide as the email view, with a line under it.
    func bar(_ content: some View) -> some View {
        VStack(spacing: 0) {
            content
            Divider()
        }
        .layoutValue(key: Panes.IsBar.self, value: true)
    }

    /// Views in a row where their ideal widths fit, and one under another where they do
    /// not, as ViewThatFits picks between an HStack and a VStack of them, but with each view
    /// once, so the focus of a button among them has one view to go to.
    struct RowOrColumn: Layout {
        var rowSpacing: CGFloat = 10
        var columnSpacing: CGFloat = 8

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            let row = rowWidth(ideal)
            guard let width = proposal.width, row > width else {
                return CGSize(width: row, height: ideal.map(\.height).max() ?? 0)
            }
            // One under another, each as wide as it needs, as a VStack lays them out.
            let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let height = sizes.map(\.height).reduce(0, +) + columnSpacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: min(width, sizes.map(\.width).max() ?? 0), height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            // Half a point of slack, as the width given back may be rounded.
            if rowWidth(ideal) <= bounds.width + 0.5 {
                var x = bounds.minX
                for (subview, size) in zip(subviews, ideal) {
                    subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                    x += size.width + rowSpacing
                }
                return
            }
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                y += size.height + columnSpacing
            }
        }

        private func rowWidth(_ sizes: [CGSize]) -> CGFloat {
            sizes.map(\.width).reduce(0, +) + rowSpacing * CGFloat(max(0, sizes.count - 1))
        }
    }

    /// The two buttons that switch the layout, and Explain, for the focus that follows a
    /// press.
    enum SwitchButton: Hashable {
        case compare, exit
        /// Explain, where Exit Comparison leaves an email without an explanation, which has
        /// no Compare with Original.
        case explain
    }

    /// Where the focus goes once the layout switched after a press: the other button, for
    /// VoiceOver and for the keyboard, each when its focus sat on the button pressed.
    struct FocusMove: Equatable {
        var button: SwitchButton
        var voiceOver: Bool
        var keyboard: Bool
    }

    /// Where the focus goes after a press of a button that switches the layout: to the
    /// other button, for VoiceOver when its cursor sat on the button pressed and for the
    /// keyboard when its focus did. After Exit Comparison for an email without an
    /// explanation, which the window shows when another email was chosen while comparing,
    /// that is Explain, since Compare with Original does not show. Nil after a click with
    /// the mouse, which leaves the focus where it was, such as in the draft.
    static func focusAfterPress(_ pressed: SwitchButton, voiceOver: SwitchButton?, keyboard: SwitchButton?, isExplained: Bool = true) -> FocusMove? {
        let moves = (voiceOver: voiceOver == pressed, keyboard: keyboard == pressed)
        guard moves.voiceOver || moves.keyboard else { return nil }
        let other: SwitchButton = pressed == .compare ? .exit : isExplained ? .compare : .explain
        return FocusMove(button: other, voiceOver: moves.voiceOver, keyboard: moves.keyboard)
    }
}
