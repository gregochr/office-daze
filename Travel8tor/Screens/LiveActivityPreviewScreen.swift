#if DEBUG
import SwiftData
import SwiftUI

/// `-screen activity` — screen 5d's panel, drawn by the app.
///
/// The same `LockScreenPanel` the widget extension renders, compiled into both
/// targets. It exists because the lock screen is unreachable from the command
/// line: `simctl` has no lock verb, so a Live Activity's lock-screen
/// presentation cannot be screenshotted, only its Dynamic Island one. This is
/// how the layout gets looked at. Debug builds only.
struct LiveActivityPreviewScreen: View {
    @Query private var bookings: [Booking]

    private var desk: (Booking, DeskDetail)? {
        guard let booking = bookings.first(where: { $0.kind == .desk }),
              let detail = booking.detail?.deskDetail else { return nil }
        return (booking, detail)
    }

    var body: some View {
        ScreenScaffold(backTitle: "RETURN") {
            if let (booking, detail) = desk {
                VStack(alignment: .leading, spacing: 14) {
                    SectionKicker(text: "LIVE ACTIVITY ▪ 5D")
                    LockScreenPanel(
                        attributes: .init(
                            placeName: detail.placeName, day: booking.anchorDay.description
                        ),
                        state: .init(
                            deskID: detail.deskID,
                            floor: detail.floor,
                            zone: detail.zone,
                            heldUntil: booking.endsAt.map {
                                TimeDisplay.inline($0, in: booking.endZone ?? booking.startZone)
                            },
                            dayNumber: 3,
                            target: 7
                        )
                    )

                    SectionKicker(text: "WITH FIELDS UNREAD")
                        .padding(.top, 8)
                    // The never-guess rule as the panel sees it: a floor and a
                    // finish time the capture could not read are absent, not
                    // filled in.
                    LockScreenPanel(
                        attributes: .init(
                            placeName: detail.placeName, day: booking.anchorDay.description
                        ),
                        state: .init(
                            deskID: detail.deskID,
                            floor: nil, zone: nil, heldUntil: nil,
                            dayNumber: 3, target: 7
                        )
                    )
                }
            }
        }
    }
}
#endif
