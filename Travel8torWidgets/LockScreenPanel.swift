import SwiftUI

/// The panel from screen 5d, exactly: amber hairline on a 0.05 fill, the desk
/// id as the hero, the level right-aligned beside it, and a ruled footer
/// carrying the hold time and the day count.
struct LockScreenPanel: View {
    let attributes: DeskActivityAttributes
    let state: DeskActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Rectangle().fill(Palette.desk).frame(width: 7, height: 7)
                Text("ON PREM ▪ \(attributes.placeName.uppercased())")
                    .t8(.activityKicker)
                    .foregroundStyle(Palette.desk)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            // `.lastTextBaseline`, not `.bottom`. The design bottom-aligns two
            // boxes at line-height 1; SwiftUI's Text carries its descender, so
            // aligning frames drops the 22pt figure below the 34pt one. Aligning
            // baselines is what the mock actually looks like.
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DESK")
                        .t8(.activityLabel)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                    Text(state.deskID.uppercased())
                        .font(.custom(T8Fonts.bold, size: 34))
                        .foregroundStyle(Palette.bone)
                }
                Spacer(minLength: 0)
                if let level = state.level {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("LEVEL")
                            .t8(.activityLabel)
                            .foregroundStyle(Palette.bone.opacity(0.4))
                        Text(level)
                            .font(.custom(T8Fonts.bold, size: 22))
                            .foregroundStyle(Palette.bone.opacity(0.75))
                    }
                }
            }

            Rectangle()
                .fill(Palette.desk.opacity(0.25))
                .frame(height: 1)
                .padding(.top, 14)

            HStack {
                // Never a guess: an unread finish time says so rather than
                // inventing a plausible 17:00.
                Text(state.heldUntil.map { "HELD UNTIL \($0)" } ?? "HELD UNTIL ??:??")
                    .t8(.activityFooter)
                    .foregroundStyle(Palette.bone.opacity(0.45))
                Spacer(minLength: 8)
                Text(state.dayCount)
                    .t8(.activityFooterBold)
                    .foregroundStyle(Palette.desk)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 15)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.desk.opacity(0.05))
        .overlay { Rectangle().strokeBorder(Palette.desk.opacity(0.4), lineWidth: 1) }
    }
}

nonisolated extension T8Font {
    static let activityKicker = T8Font(9.5, bold: true, tracking: 0.18)
    static let activityLabel = T8Font(9, tracking: 0.16)
    static let activityFooter = T8Font(10, tracking: 0.08)
    static let activityFooterBold = T8Font(10, bold: true, tracking: 0.12)
    static let islandCompact = T8Font(13, bold: true)
    static let islandFooter = T8Font(9.5, tracking: 0.10)
    static let islandFooterBold = T8Font(9.5, bold: true, tracking: 0.12)
}
