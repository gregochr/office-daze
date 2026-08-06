import Foundation
import SwiftData

@MainActor
enum Store {

    /// The app's container. On-disk, local only — no accounts, no server, no
    /// sync, which is also what makes the offline requirement fall out for free
    /// rather than needing a cache layer.
    static func makeContainer(seedIfEmpty: Bool = true) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(OfficeDazeSchema.all),
            configurations: ModelConfiguration(isStoredInMemoryOnly: false)
        )
        if seedIfEmpty {
            try seedIfNeeded(container.mainContext)
        }
        return container
    }

    /// A throwaway in-memory container. Used by tests and SwiftUI previews.
    static func makeInMemoryContainer(seeded: Bool = false) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(OfficeDazeSchema.all),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        if seeded {
            try SeedData.populate(container.mainContext)
        }
        return container
    }

    /// Whether the sample month has ever been laid down.
    ///
    /// A flag rather than "is the store empty", because those stop being the
    /// same question the moment the store can be wiped: an emptied store is
    /// empty on purpose, and re-seeding it would put the sample bookings
    /// straight back on the next launch.
    private static let seededKey = "store.seeded"

    static var hasSeeded: Bool {
        get { UserDefaults.standard.bool(forKey: seededKey) }
        set { UserDefaults.standard.set(newValue, forKey: seededKey) }
    }

    static func seedIfNeeded(_ context: ModelContext) throws {
        guard !hasSeeded else { return }
        guard try context.fetchCount(FetchDescriptor<Office>()) == 0 else {
            hasSeeded = true
            return
        }
        try SeedData.populate(context)
        hasSeeded = true
    }

    /// Deletes everything: offices, bookings, leave, attendance, the arrival
    /// ledger and the retained capture originals.
    ///
    /// One thing it cannot undo: an `AttendanceDay` is the only record that a
    /// day was ever worked on prem, and there is no other copy.
    static func wipe(_ context: ModelContext) throws {
        for model in OfficeDazeSchema.all {
            try context.delete(model: model)
        }
        try context.save()
        // So the sample month does not come back on the next launch.
        hasSeeded = true
    }
}
