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

    /// Whether the first launch's seed has ever been laid down.
    ///
    /// A flag rather than "is the store empty", because those stop being the
    /// same question the moment the store can be wiped: an emptied store is
    /// empty on purpose, and re-seeding it would put the seed straight back on
    /// the next launch.
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

    /// Whether this build is running in the simulator, which decides which of
    /// the two seeds a first launch lays down. See `SeedData.populate`.
    ///
    /// The simulator rather than `DEBUG`. A debug build is also what goes onto
    /// a phone plugged into this Mac — without a paid account, the only way to
    /// put the app on someone else's phone — and that phone should start with
    /// the offices, not with a month of bookings nobody made.
    nonisolated static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func seedIfNeeded(
        _ context: ModelContext,
        defaults: UserDefaults = .standard,
        forSimulator: Bool = Store.isSimulator
    ) throws {
        guard !hasSeeded(in: defaults) else { return }
        guard try context.fetchCount(FetchDescriptor<Office>()) == 0 else {
            markSeeded(in: defaults)
            return
        }
        try SeedData.populate(context, forSimulator: forSimulator)
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
    /// Everything the app holds is a row in the schema now. There was once a
    /// secret outside it — the API key for a remote reader, in the Keychain —
    /// and `.everything` reached for that too. The reading happens on the
    /// phone, so there is no longer anything a `context.delete(model:)` cannot
    /// reach.
    static func wipe(
        _ context: ModelContext,
        scope: Scope = .everything,
        defaults: UserDefaults = .standard
    ) throws {
        for model in scope.models {
            try context.delete(model: model)
        }
        try context.save()
        // So the seed does not come back on the next launch. Set for either
        // scope, so the offices someone chose to keep are never seeded over.
        markSeeded(in: defaults)
    }
}
