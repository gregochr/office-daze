import SwiftUI

/// Press and hold a row to be shown what can be done to it.
///
/// This replaces a hand-built swipe, and the reasons are the swipe's own. It
/// had to be discovered before it could be used, and nothing on the row said
/// it was there. Its buttons sat behind a drag whose length grew with how many
/// there were. And on a screen that is a ScrollView of cards rather than a
/// `List`, every horizontal drag had to be told apart from the vertical one
/// the scroll needs, which is a judgement made on twelve points of travel and
/// got wrong often enough to be felt.
///
/// A press names every action, needs no aim, and is what the rest of iOS uses
/// for this exact job. The tap still views; the press still acts. That much of
/// the old split survives, and it is the half that was working.
///
/// `.contextMenu` rather than anything hand-built: the lift, the blur behind
/// it, the haptic, the dismissal, and the VoiceOver actions rotor all arrive
/// with it, and every one of them is worse when written here.
struct RowMenu<Content: View>: View {

    /// Absent on a row with nothing to edit: an attendance record is a day and
    /// an office and nothing else, and an Edit leading to a screen that can
    /// only add another one would be a menu item that lies.
    var edit: (() -> Void)?
    let delete: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            // The lift is given the card's own corner radius. Left alone it
            // takes a hard-edged rectangle the full width of the card, which
            // reads as a torn-out strip rather than a raised row.
            .contentShape(
                .contextMenuPreview,
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            )
            .contextMenu {
                if let edit {
                    Button("Edit", systemImage: "pencil", action: edit)
                }
                // Destructive last and on its own, where every iOS menu puts
                // it: the item you must not hit by accident is the one furthest
                // from where the thumb lands.
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
    }
}
