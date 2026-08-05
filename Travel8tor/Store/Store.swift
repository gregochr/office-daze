import Foundation
import SwiftData

@MainActor
enum Store {

    /// The app's container. On-disk, local only — no accounts, no server, no
    /// sync, which is also what makes the offline requirement fall out for
    /// free rather than needing a cache layer.
    static func makeContainer(seedIfEmpty: Bool = true) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(Travel8torSchema.all),
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
            for: Schema(Travel8torSchema.all),
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
        let existing = try context.fetchCount(FetchDescriptor<Booking>())
        guard existing == 0 else {
            // Already populated by a build that predates the flag. Record it so
            // a later wipe is not undone.
            hasSeeded = true
            return
        }
        try SeedData.populate(context)
        hasSeeded = true
    }

    /// Deletes everything: bookings, trips, leave, attendance, buildings, the
    /// arrival ledger and the retained capture originals.
    ///
    /// Two things it deliberately cannot undo, because the app does not hold
    /// the rights to. Calendar events already written stay in the calendar —
    /// write-only access cannot delete them. And an `AttendanceDay` is the only
    /// record that a day was ever worked on prem; there is no other copy.
    static func wipe(_ context: ModelContext) throws {
        for model in Travel8torSchema.all {
            try context.delete(model: model)
        }
        try context.save()
        // So the sample month does not come back on the next launch.
        hasSeeded = true
    }
}
