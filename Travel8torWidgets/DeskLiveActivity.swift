import ActivityKit
import SwiftUI
import WidgetKit

/// The widget extension's entry point. A `WidgetBundle` rather than a bare
/// `@main` widget because this bundle will hold the home-screen widget too if
/// one is ever wanted; a bundle with one member costs nothing.
@main
struct Travel8torWidgets: WidgetBundle {
    var body: some Widget {
        DeskLiveActivity()
    }
}

/// Screen 5d. Alerts once on arrival — the notification does that — then
/// persists silently on the lock screen and in the Dynamic Island until the
/// booking ends.
///
/// The extension only draws. It never reads the store, never writes attendance,
/// and has no code path that could: everything it renders arrives in the
/// `ContentState` the app hands to ActivityKit.
struct DeskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeskActivityAttributes.self) { context in
            LockScreenPanel(attributes: context.attributes, state: context.state)
                // Without these the system draws its own light chrome around
                // the panel and the hard-rectangle look goes with it.
                .activityBackgroundTint(Palette.ground)
                .activitySystemActionForegroundColor(Palette.desk)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandBlock(label: "DESK", value: context.state.deskID.uppercased(), size: 20)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let level = context.state.level {
                        islandBlock(label: "LEVEL", value: level, size: 20, trailing: true)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.placeName.uppercased())
                            .t8(.islandFooter)
                            .foregroundStyle(Palette.bone.opacity(0.45))
                        Spacer(minLength: 8)
                        Text(context.state.dayCount)
                            .t8(.islandFooterBold)
                            .foregroundStyle(Palette.desk)
                    }
                }
            } compactLeading: {
                Rectangle().fill(Palette.desk).frame(width: 7, height: 7)
            } compactTrailing: {
                Text(context.state.deskID.uppercased())
                    .t8(.islandCompact)
                    .foregroundStyle(Palette.desk)
            } minimal: {
                Rectangle().fill(Palette.desk).frame(width: 7, height: 7)
            }
            .keylineTint(Palette.desk)
        }
    }

    private func islandBlock(
        label: String, value: String, size: CGFloat, trailing: Bool = false
    ) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            Text(label)
                .t8(.activityLabel)
                .foregroundStyle(Palette.bone.opacity(0.4))
            Text(value)
                .font(.custom(T8Fonts.bold, size: size))
                .foregroundStyle(Palette.bone)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}
