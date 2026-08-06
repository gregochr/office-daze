import SwiftData
import SwiftUI

@main
struct OfficeDazeApp: App {
    /// `try!` is deliberate and temporary. If the store cannot open there is no
    /// app, and a placeholder failure screen is a later stage's problem.
    private let container: ModelContainer

    init() {
        container = try! Store.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            StageTwoView()
        }
        .modelContainer(container)
    }
}

/// Stage 2 shows the gauge on its own, in the four states from the design, so
/// it can be judged before it is embedded in anything. Xcode previews cover the
/// same ground; this exists so the dial can also be looked at on a real screen
/// at real size. Home replaces it in stage 3.
private struct StageTwoView: View {
    private let states: [(String, Double, Int)] = [
        ("Behind", 1, 7), ("Close", 6, 7), ("Met", 7, 7), ("Over \u{00B7} +2", 9, 7),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.cardGap) {
                    ForEach(states, id: \.0) { title, attended, target in
                        VStack(spacing: 2) {
                            Text(title)
                                .font(.system(size: 13))
                                .foregroundStyle(
                                    attended >= Double(target) ? Palette.met : Palette.secondary
                                )
                            AttendanceGauge(attended: attended, target: target)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Palette.card)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    }
                }
                .padding(Metrics.screenPadding)
            }
            .background(Palette.ground)
            .navigationTitle("Gauge")
        }
    }
}
