import Foundation

/// What Bell's calendar should contain, and how to get it there from what it
/// does contain.
///
/// Kept apart from EventKit on purpose. Two-way sync is where calendar apps
/// lose people's data: an event vanishes from the server and the app reads
/// that as an instruction. Every decision of that kind is made here, in a
/// pure function with tests, and the EventKit layer only carries it out.
enum CalendarPlan {

    /// One class as it should appear in a calendar.
    struct Planned: Hashable {
        var key: String
        var title: String
        var location: String
        var start: Date
        var end: Date
        var notes: String
    }

    /// How far ahead to write. Four weeks covers "what's on next week" in
    /// any calendar app, while keeping a sync to about eighty writes rather
    /// than a whole term's worth on every schedule change.
    static let horizonDays = 28

    /// The marker that identifies Bell's own events. Written to the event's
    /// URL and repeated as the last line of its notes, because some calendar
    /// servers drop the URL field on a round trip; without a surviving key,
    /// Bell would no longer recognise its own events and would create
    /// duplicates on every sync.
    static let notesMarker = "bell:"

    static func notes(instructor: String?, key: String) -> String {
        var lines: [String] = []
        if let instructor { lines.append(instructor) }
        lines.append("Added by Bell. Changes made here are replaced on the next sync; "
                     + "delete a single class to mark it cancelled.")
        lines.append(notesMarker + key)
        return lines.joined(separator: "\n")
    }

    /// The key from either place it's stored, or nil for an event Bell didn't
    /// write. Events without one are never touched.
    static func key(url: URL?, notes: String?) -> String? {
        if let url, url.scheme == "bell", url.host == "occurrence" {
            let key = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            if !key.isEmpty { return key }
        }
        guard let line = notes?.split(separator: "\n").last(where: { $0.hasPrefix(notesMarker) })
        else { return nil }
        let key = String(line.dropFirst(notesMarker.count))
        return key.isEmpty ? nil : key
    }

    static func url(for key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "bell"
        components.host = "occurrence"
        components.path = "/" + key
        return components.url
    }

    /// Every class from the start of `today` to the horizon, minus hidden
    /// courses and single cancellations (the engine already drops those).
    static func desired(engine: ScheduleEngine,
                        from today: Date,
                        days: Int = horizonDays,
                        hidden: Set<String>) -> [Planned] {
        let start = engine.calendar.startOfDay(for: today)
        return engine.occurrences(from: start, forwardDays: days)
            .filter { !hidden.contains($0.event.course) }
            .map { occurrence in
                Planned(key: occurrence.key,
                        title: occurrence.event.course,
                        location: occurrence.event.room,
                        start: occurrence.start,
                        end: occurrence.end,
                        notes: notes(instructor: occurrence.event.instructor, key: occurrence.key))
            }
    }
}

// MARK: - Reconciling

enum CalendarReconciler {

    /// An event already in the target calendar, inside the sync window.
    struct Existing: Hashable {
        var identifier: String
        /// Nil when Bell didn't write it.
        var key: String?
        var title: String
        var location: String
        var start: Date
        var end: Date
    }

    struct Result: Equatable {
        var create: [CalendarPlan.Planned] = []
        /// (existing identifier, what it should become)
        var update: [Update] = []
        var delete: [String] = []
        /// Keys the user deleted from the calendar, read as "this class is
        /// cancelled". The caller records them; they are not recreated.
        var cancelled: [String] = []
        /// True when so many events vanished at once that it can't have been
        /// the user deleting classes one by one (an account removed, a
        /// calendar reset). Nothing is read as cancelled; everything missing
        /// is recreated instead.
        var suspectedReset = false
        /// Keys Bell believes exist in the calendar once this is applied.
        var ledger: Set<String> = []

        struct Update: Equatable {
            var identifier: String
            var planned: CalendarPlan.Planned
        }

        var isEmpty: Bool { create.isEmpty && update.isEmpty && delete.isEmpty }
    }

    /// Above this many missing events in one sync, assume a reset rather
    /// than deliberate deletions. Three is a bad week of cancellations;
    /// more than that at once is something happening to the calendar.
    static let deliberateDeletionLimit = 3

    /// - Parameters:
    ///   - ledger: keys Bell saw in the calendar after the last sync. An
    ///     event only counts as deleted by the user if Bell knows it existed;
    ///     missing because it was never written is just "create".
    static func reconcile(desired: [CalendarPlan.Planned],
                          existing: [Existing],
                          ledger: Set<String>) -> Result {
        var result = Result()
        let wanted = Dictionary(desired.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // Bell's own events present now, first one per key. Later duplicates
        // (a sync interrupted between write and commit, a server echo) go.
        var present: [String: Existing] = [:]
        for event in existing {
            guard let key = event.key else { continue }   // not ours: never touched
            if present[key] == nil {
                present[key] = event
            } else {
                result.delete.append(event.identifier)
            }
        }

        for (key, event) in present {
            if let planned = wanted[key] {
                if event.title != planned.title || event.location != planned.location
                    || event.start != planned.start || event.end != planned.end {
                    result.update.append(.init(identifier: event.identifier, planned: planned))
                }
            } else {
                // A class that no longer exists (schedule changed, course
                // hidden). Bell made it, so Bell removes it.
                result.delete.append(event.identifier)
            }
        }

        let missing = desired.filter { present[$0.key] == nil }
        let vanished = missing.filter { ledger.contains($0.key) }

        if vanished.count > deliberateDeletionLimit {
            result.suspectedReset = true
            result.create = missing
        } else {
            result.cancelled = vanished.map(\.key)
            result.create = missing.filter { !ledger.contains($0.key) }
        }

        result.ledger = Set(present.keys).intersection(wanted.keys)
            .union(result.create.map(\.key))

        result.update.sort { $0.planned.start < $1.planned.start }
        result.create.sort { $0.start < $1.start }
        result.delete.sort()
        return result
    }
}
