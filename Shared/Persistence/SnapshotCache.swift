import Foundation
import SwiftUI

/// What the widget reads.
///
/// SwiftData is the source of truth, but it lives in the app process. A widget
/// timeline build is a cold start on a tight budget: opening a ModelContainer,
/// running fetches and faulting relationships is slow, and SwiftData in an
/// extension is fragile in ways that are hard to debug when the only symptom
/// is a blank widget.
///
/// So the app derives a flat snapshot after every write and drops it here as
/// one atomic JSON file. The widget reads that and nothing else. It's a few
/// kilobytes, parses in microseconds, and can never be half-written.
///
/// The rule this encodes: the widget never queries: it only reads a value the
/// app has already computed.
enum SnapshotCache {

    private static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("snapshot.json")
    }

    // MARK: - Reading

    /// Never throws and never returns nil. A widget with no data should render
    /// an empty state, not crash or show a placeholder forever.
    static func read() -> Timetable {
        guard
            let url,
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder.bell.decode(Timetable.self, from: data)
        else { return BundledTimetable.load() ?? .empty }

        return snapshot
    }

    // MARK: - Writing

    static func write(_ timetable: Timetable) {
        guard let url else { return }
        guard let data = try? JSONEncoder.bell.encode(timetable) else { return }
        try? data.write(to: url, options: .atomic)
        writePalette(for: timetable)
    }

    // MARK: - Busy times
    //
    // The Free widget needs to know when your other calendars have you busy,
    // and the widget can't read EventKit. So the app writes start and end
    // times only: no titles, places or calendar names, and only the next
    // eight days. That's the least that makes "free" true.

    private static let busyKey = "busy.intervals"

    static func writeBusy(_ intervals: [DateInterval]) {
        let horizon = Date.now.addingTimeInterval(8 * 86_400)
        let flat = intervals.filter { $0.start < horizon }.map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] }
        AppGroup.defaults?.set(flat, forKey: busyKey)
    }

    static func busy() -> [DateInterval] {
        ((AppGroup.defaults?.array(forKey: busyKey) as? [[Double]]) ?? []).compactMap { pair in
            guard pair.count == 2, pair[1] > pair[0] else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: pair[0]), end: Date(timeIntervalSince1970: pair[1]))
        }
    }

    // MARK: - Palette
    //
    // Cached alongside so the widget doesn't recompute the assignment on every
    // timeline entry. Assignment is deterministic, so the cache is an
    // optimisation rather than a source of truth — a cold widget that misses
    // the cache still arrives at the same colours.

    private static let paletteKey = "palette.assignments"

    static func writePalette(for timetable: Timetable) {
        let assignments = Palette.assign(courses: timetable.courses)
        AppGroup.defaults?.set(assignments.mapValues(\.storableComponents), forKey: paletteKey)
    }

    static func palette() -> [String: Color] {
        if let raw = AppGroup.defaults?.dictionary(forKey: paletteKey) as? [String: [Double]],
           !raw.isEmpty {
            return raw.mapValues { Color(storableComponents: $0) }
        }
        return Palette.assign(courses: read().courses)
    }
}

// MARK: - Coding
//
// ISO 8601 rather than the default reference-date doubles, so a snapshot can
// be read by eye when diagnosing a widget that disagrees with the app.

extension JSONEncoder {
    static var bell: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bell: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
