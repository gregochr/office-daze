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
    ///
    /// Where the flag is kept is injected, for the same reason `today` is
    /// injected all through the store: it is process-wide state with exactly
    /// one interesting value, and a test that flipped the real flag would be
    /// deciding whether the *app* lays the sample month down on the next launch
    /// of the same simulator. Nothing but the tests ever passes anything but
    /// `.standard`.
    private static let seededKey = "store.seeded"

    static func hasSeeded(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seededKey)
    }

    static func markSeeded(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seededKey)
    }

    static func seedIfNeeded(
        _ context: ModelContext, defaults: UserDefaults = .standard
    ) throws {
        guard !hasSeeded(in: defaults) else { return }
        guard try context.fetchCount(FetchDescriptor<Office>()) == 0 else {
            markSeeded(in: defaults)
            return
        }
        try SeedData.populate(context)
        markSeeded(in: defaults)
    }

    /// Every day the store holds a record for: a desk booked, a day worked, a
    /// day intended, a day off.
    ///
    /// Both month steppers ask this one question, so the gauge and the holiday
    /// calendar cannot disagree about how far back the months go. Bank-holiday
    /// leave rows are left out on the same grounds every other reader leaves
    /// them out: they are derived from the calendar rather than entered, so a
    /// month containing nothing but bank holidays is still an empty month.
    static func recordedDays(in context: ModelContext) throws -> [Day] {
        try context.fetch(FetchDescriptor<DeskBooking>()).map(\.day)
            + context.fetch(FetchDescriptor<AttendanceDay>()).map(\.day)
            + context.fetch(FetchDescriptor<PlannedDay>()).map(\.day)
            + context.fetch(FetchDescriptor<LeaveDay>())
                .filter { $0.kind != .bankHoliday }
                .map(\.day)
    }

    /// How far a wipe reaches.
    ///
    /// The two are worth separating because the offices are the only thing in
    /// the store the user typed in themselves — a name, an address, a postcode
    /// and a perimeter per building. Everything else either arrived from a
    /// screenshot or can be captured again in seconds. Clearing out the sample
    /// month should not cost someone the buildings they set up.
    enum Scope {
        /// Bookings, attendance, leave, the arrival ledger and the retained
        /// capture originals. The offices stay.
        case records
        /// The above and the offices with it.
        case everything

        var models: [any PersistentModel.Type] {
            switch self {
            case .everything: OfficeDazeSchema.all
            case .records: OfficeDazeSchema.all.filter { $0 != Office.self }
            }
        }
    }

    /// One thing neither scope can undo: an `AttendanceDay` is the only record
    /// that a day was ever worked on prem, and there is no other copy.
    ///
    /// `forgetSecret` is the Anthropic API key, which is the one thing the app
    /// holds that no `context.delete(model:)` can reach — it is in the Keychain,
    /// not the schema. It was being left behind by a button that says
    /// "Everything, including 2 offices", which is the one item in the store
    /// where being left behind actually costs something: it is a live, billable
    /// third-party credential, and iOS does not purge a generic-password item
    /// when the app is deleted either, so neither wiping nor uninstalling took
    /// it off the phone. Handing the device on did exactly what the dialog said
    /// it would not.
    ///
    /// Only `.everything` reaches for it. `.records` is the scope that keeps
    /// what the user typed in, and the key is squarely that.
    ///
    /// Injected rather than called inline so a test can assert which scopes
    /// reach for it without reaching into the simulator's real Keychain — the
    /// whole point of the finding is *which* scope forgets it, and that is not
    /// assertable through a side effect on a device.
    static func wipe(
        _ context: ModelContext,
        scope: Scope = .everything,
        defaults: UserDefaults = .standard,
        forgetSecret: () -> Void = { Keychain.apiKey = nil }
    ) throws {
        for model in scope.models {
            try context.delete(model: model)
        }
        try context.save()
        if scope == .everything { forgetSecret() }
        // So the sample month does not come back on the next launch. Set for
        // either scope: re-seeding over the offices someone kept would put the
        // sample bookings back under them.
        markSeeded(in: defaults)
    }
}
