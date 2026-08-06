import SwiftData
import SwiftUI

@main
struct OfficeDazeApp: App {
    /// `try!` is deliberate and temporary. If the store cannot open there is no
    /// app, and a placeholder failure screen is a later stage's problem.
    private let container: ModelContainer

    /// One coordinator for the app's lifetime. iOS launches the app *with* the
    /// shared file, so a capture starts before any screen exists and outlives
    /// the sheet that shows it.
    @State private var capture: CaptureCoordinator

    /// Created at launch, not by a screen. iOS relaunches the app in the
    /// background when a monitored region is crossed, and the queued event is
    /// only delivered if a CLLocationManager already exists with its delegate
    /// set — a manager created lazily by a view that never appears would drop
    /// the arrival silently.
    @State private var arrival: ArrivalMonitor

    init() {
        let container = try! Store.makeContainer()
        self.container = container
        _capture = State(initialValue: CaptureCoordinator(context: container.mainContext))
        let ledger = ArrivalLedger(context: container.mainContext)
        _arrival = State(initialValue: ArrivalMonitor(
            ledger: ledger, context: container.mainContext
        ))
    }

    var body: some Scene {
        WindowGroup {
            root
                .environment(capture)
                // iOS copies the shared file into our inbox and launches us
                // here. This is the whole share-sheet path, in place of an
                // extension.
                .onOpenURL { url in
                    Task { await capture.receive(url: url) }
                }
                .environment(arrival)
                .task {
                    // Registration only — the permission prompt belongs to the
                    // moment the user asks for the alert, not to launch.
                    arrival.registerNotificationHandling()
                    arrival.refreshRegions()
                    #if DEBUG
                    let office = ProcessInfo.processInfo.argument(after: "-arrival")
                    if !office.isEmpty { arrival.simulateEntry(officeNamed: office) }
                    #endif
                }
                .sheet(isPresented: .init(
                    get: { capture.isActive },
                    set: { if !$0 { capture.abort() } }
                )) {
                    CaptureSheet(coordinator: capture)
                }
        }
        .modelContainer(container)
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        DebugRouter()
        #else
        NavigationStack { HomeScreen() }
        #endif
    }
}
