import SwiftData
import SwiftUI

@main
struct Travel8torApp: App {
    /// `try!` is deliberate and temporary. If the store cannot open there is no
    /// app, and a placeholder failure screen is stage 6's problem.
    private let container: ModelContainer

    /// One coordinator for the app's lifetime: a capture starts when a file
    /// arrives and finishes when the user commits or aborts, which outlives any
    /// single view.
    @State private var capture: CaptureCoordinator

    /// Created at launch, not by a screen. iOS relaunches the app in the
    /// background when a monitored region is crossed, and the queued event is
    /// only delivered if a CLLocationManager already exists with its delegate
    /// set — a manager created lazily by a view that never appears would drop
    /// the arrival silently.
    private let ledger: ArrivalLedger
    private let arrival: ArrivalMonitor

    init() {
        let container = try! Store.makeContainer()
        self.container = container
        _capture = State(initialValue: CaptureCoordinator(context: container.mainContext))
        let ledger = ArrivalLedger(context: container.mainContext)
        self.ledger = ledger
        arrival = ArrivalMonitor(ledger: ledger)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(capture)
                // iOS copies the shared file into our inbox and launches us
                // here. This is the whole share-sheet path, in place of an
                // extension.
                .onOpenURL { url in
                    Task { await capture.receive(url: url) }
                }
                .task {
                    // Registration only — the permission prompt belongs to the
                    // moment the arrival trigger is switched on, not to launch.
                    arrival.registerNotificationHandling()
                    arrival.refreshRegions()
                }
        }
        .modelContainer(container)
    }
}
