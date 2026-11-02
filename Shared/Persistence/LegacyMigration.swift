import Foundation

/// Moves the old storage into the database, once.
///
/// Before Phase 0 there were two sources: a JSON blob in the App Group written
/// by the app, and `Events.xml` compiled into the bundle as a fallback for
/// devices without a working App Group. Both are now seeds rather than
/// storage — read at most once, then never again.
///
/// The marker lives in App Group defaults rather than in the database, so a
/// database that fails to open and gets recreated doesn't silently re-run the
/// migration and overwrite edits the user made since.
enum LegacyMigration {

    private static let completionKey = "migration.swiftdata.v1"

    static var hasRun: Bool {
        AppGroup.defaults?.bool(forKey: completionKey) ?? false
    }

    @MainActor
    static func runIfNeeded(into store: BellStore) {
        guard !hasRun else { return }

        // Anything already in the database wins. This is the case where a user
        // imported a schedule, the migration marker got lost, and re-seeding
        // from the bundle would quietly discard real data.
        if !store.timetable.events.isEmpty {
            markComplete()
            return
        }

        guard let seed = legacySnapshot() ?? BundledTimetable.load(), !seed.events.isEmpty else {
            // Nothing to migrate. A fresh install lands here and goes straight
            // to onboarding, which is correct.
            markComplete()
            return
        }

        store.replaceSchedule(with: seed,
                              source: .manual,
                              summary: "Imported existing schedule")
        markComplete()
    }

    /// The pre-Phase-0 JSON blob, if it's still sitting in the container.
    private static func legacySnapshot() -> Timetable? {
        guard
            let url = AppGroup.containerURL?.appendingPathComponent("timetable.json"),
            let data = try? Data(contentsOf: url),
            let timetable = try? JSONDecoder.bell.decode(Timetable.self, from: data),
            !timetable.events.isEmpty
        else { return nil }

        return timetable
    }

    private static func markComplete() {
        AppGroup.defaults?.set(true, forKey: completionKey)
    }

    /// Debug affordance: forget the marker so the next launch re-seeds. Not
    /// wired to any UI, and deliberately so — it discards real data.
    static func resetForTesting() {
        AppGroup.defaults?.removeObject(forKey: completionKey)
    }
}
