import SwiftUI

/// The standard swipe: drag a row left to reveal Delete, snap open or closed,
/// or carry the swipe past a wider threshold to delete outright.
///
/// Hand-built because the list is hand-built. `.swipeActions` only exists
/// inside a `List`, and this screen is a ScrollView of cards for the reasons at
/// the top of `Cards.swift` — adopting a `List` to get one gesture would cost
/// the gauge card and the office grid, which is a bad trade for a swipe.
struct SwipeToDelete<Content: View>: View {

    /// How far the row rests open, and how far a swipe has to carry to delete
    /// without stopping there. The second is deliberately more than twice the
    /// first: a full swipe is a decision, not an overshoot.
    private static var revealed: CGFloat { 88 }
    private static var throughSwipe: CGFloat { 200 }

    let id: UUID
    /// Which row is open, if any. Held by the parent so opening one closes the
    /// last — the behaviour a `List` gives for free.
    @Binding var open: UUID?
    let delete: () -> Void
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0

    private var isOpen: Bool { open == id }

    /// Never positive: dragging right on a closed row does nothing, so the row
    /// cannot be pulled away from its own leading edge.
    private var offset: CGFloat {
        min(0, (isOpen ? -Self.revealed : 0) + drag)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            button
            content
                // Opaque, or the red shows through the row it is behind.
                .background(Palette.card)
                .overlay { if isOpen { closer } }
                .offset(x: offset)
                .simultaneousGesture(swipe)
        }
        .clipped()
        // For anyone who cannot swipe. The gesture is the affordance, not the
        // only way in.
        .accessibilityAction(named: "Delete", delete)
    }

    private var button: some View {
        Button(role: .destructive) {
            open = nil
            delete()
        } label: {
            Text("Delete")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.revealed)
                .frame(maxHeight: .infinity)
                .background(Palette.behind)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// While a row is open, tapping it closes it rather than opening the
    /// booking — as a `List` does. Without this the first tap after a swipe
    /// navigates, which is never what was meant.
    private var closer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { open = nil } }
    }

    /// Simultaneous rather than high-priority: the ScrollView has to keep the
    /// vertical axis, and the row underneath has to keep its tap. The
    /// horizontal test is what stops a scroll being read as a swipe.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                drag = value.translation.width
            }
            .onEnded { _ in
                let travelled = -offset
                withAnimation(.snappy(duration: 0.25)) {
                    drag = 0
                    if travelled > Self.throughSwipe {
                        open = nil
                        delete()
                    } else if travelled > Self.revealed / 2 {
                        open = id
                    } else {
                        open = nil
                    }
                }
            }
    }
}
