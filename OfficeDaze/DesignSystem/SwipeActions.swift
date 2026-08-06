import SwiftUI

/// The standard swipe: drag a row left to reveal what can be done to it, and
/// snap open or closed.
///
/// Hand-built because the list is hand-built. `.swipeActions` only exists
/// inside a `List`, and this screen is a ScrollView of cards for the reasons at
/// the top of `Cards.swift` — adopting a `List` to get one gesture would cost
/// the gauge card and the office grid, which is a bad trade for a swipe.
///
/// Edit lives here rather than on the tap because tapping a row and swiping it
/// were two ways of starting the same job, and a row that both opens something
/// and hides something behind it teaches neither. The tap now views, and the
/// swipe acts.
struct SwipeActions<Content: View>: View {

    /// One button's width. What the row rests open by is this times however
    /// many buttons there are.
    private static var buttonWidth: CGFloat { 88 }

    let id: UUID
    /// Which row is open, if any. Held by the parent so opening one closes the
    /// last — the behaviour a `List` gives for free.
    @Binding var open: UUID?
    /// Absent on a row with nothing to edit: an attendance record is a day and
    /// an office and nothing else, and a button leading to a screen that can
    /// only add another one would be a button that lies.
    var edit: (() -> Void)?
    let delete: () -> Void
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0

    private var isOpen: Bool { open == id }

    private var revealed: CGFloat {
        Self.buttonWidth * (edit == nil ? 1 : 2)
    }

    /// Never positive: dragging right on a closed row does nothing, so the row
    /// cannot be pulled away from its own leading edge.
    private var offset: CGFloat {
        min(0, (isOpen ? -revealed : 0) + drag)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            buttons
            content
                // Opaque, or the buttons show through the row in front of them.
                .background(Palette.card)
                .overlay { if isOpen { closer } }
                .offset(x: offset)
                .simultaneousGesture(swipe)
        }
        .clipped()
        // For anyone who cannot swipe. The gesture is the affordance, not the
        // only way in.
        .accessibilityAction(named: "Delete", delete)
        .accessibilityActions {
            if let edit {
                Button("Edit", action: edit)
            }
        }
    }

    /// Delete outermost, against the trailing edge, because that is where the
    /// swipe is already heading and where every other iOS list puts it.
    private var buttons: some View {
        HStack(spacing: 0) {
            if let edit {
                button("Edit", tint: Palette.tint) {
                    open = nil
                    edit()
                }
            }
            button("Delete", tint: Palette.behind, role: .destructive) {
                open = nil
                delete()
            }
        }
    }

    private func button(
        _ title: String, tint: Color, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.buttonWidth)
                .frame(maxHeight: .infinity)
                .background(tint)
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
    ///
    /// No swipe-through-to-delete any more. With two buttons the row has to
    /// travel twice as far to open, so a threshold beyond that sat most of the
    /// way across the screen — a destructive gesture that is both hard to reach
    /// and easy to reach by accident on the one row you dragged too hard. The
    /// button is one tap away and asks to be aimed at.
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
                    open = travelled > revealed / 2 ? id : nil
                }
            }
    }
}
