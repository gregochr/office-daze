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
            #if DEBUG
            DebugRouter()
            #else
            NavigationStack { HomeScreen() }
            #endif
        }
        .modelContainer(container)
    }
}
