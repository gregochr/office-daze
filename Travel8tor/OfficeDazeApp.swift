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

    init() {
        let container = try! Store.makeContainer()
        self.container = container
        _capture = State(initialValue: CaptureCoordinator(context: container.mainContext))
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
