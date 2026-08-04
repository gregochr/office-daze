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

    static func seedIfNeeded(_ context: ModelContext) throws {
        let existing = try context.fetchCount(FetchDescriptor<Booking>())
        guard existing == 0 else { return }
        try SeedData.populate(context)
    }
}
