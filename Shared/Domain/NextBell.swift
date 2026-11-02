import Foundation

/// The next bell: the next moment the day changes for you.
///
/// One of three things. In a class, the bell is its end. Between classes, it's
/// the moment you have to leave for the next one, if there's a walk; then, once
/// you're on your way, the class starting. It drives the hero slab, the Bell
/// widget, the Leave lock-screen widget and the Live Activity, so it's decided
/// here, once, in a pure function.
struct NextBell: Equatable {
    enum Kind: Equatable { case starts, ends, leave }

    var kind: Kind
    /// When it rings.
    var at: Date
    /// When the stretch it ends began. The slab drains across from...at.
    var from: Date
    var occurrence: ScheduleEngine.Occurrence
    var walkMinutes: Int?

    /// 1 at `from`, 0 when it rings. What the slab's fill shows.
    func remainingFraction(at now: Date) -> Double {
        let span = at.timeIntervalSince(from)
        guard span > 0 else { return 0 }
        return min(1, max(0, at.timeIntervalSince(now) / span))
    }

    /// "until ECE 30200 starts", "left in ECE 30200", "to leave for ECE 30200".
    var caption: String {
        switch kind {
        case .starts: "until \(occurrence.event.course) starts"
        case .ends: "left in \(occurrence.event.course)"
        case .leave: "until you leave for \(occurrence.event.course)"
        }
    }

    /// The longest a drain can run before a class. Waiting since 7am for a
    /// 3pm class would make the slab barely move all afternoon.
    static let maximumLead: TimeInterval = 3 * 3600

    static func make(engine: ScheduleEngine,
                     hidden: Set<String> = [],
                     now: Date,
                     bufferMinutes: Int,
                     walkSeconds: (String?, String?) -> TimeInterval) -> NextBell? {
        let today = engine.occurrences(on: now).filter { !hidden.contains($0.event.course) }

        if let current = today.first(where: { $0.start <= now && now < $0.end }) {
            return NextBell(kind: .ends, at: current.end, from: current.start, occurrence: current, walkMinutes: nil)
        }
        guard let next = today.first(where: { $0.start > now }) else { return nil }

        let previous = today.last { $0.end <= now }
        let origin = previous?.event.building ?? "HOME"
        let walk = walkSeconds(origin, next.event.building)
        let earliest = max(previous?.end ?? .distantPast, next.start.addingTimeInterval(-maximumLead))

        if walk > 0 {
            let leave = next.start.addingTimeInterval(-walk - TimeInterval(bufferMinutes * 60))
            if leave > now {
                return NextBell(kind: .leave, at: leave, from: min(earliest, leave), occurrence: next,
                                walkMinutes: Int((walk / 60).rounded()))
            }
            return NextBell(kind: .starts, at: next.start, from: max(earliest, min(leave, now)),
                            occurrence: next, walkMinutes: Int((walk / 60).rounded()))
        }
        return NextBell(kind: .starts, at: next.start, from: min(earliest, now), occurrence: next, walkMinutes: nil)
    }
}

/// How the countdown is written: whole minutes under an hour ("14", "min"),
/// hours and minutes above ("1:45", "hr"). Minutes round up, so "0" never
/// shows while there's still time: the last minute reads "1".
enum BellNumber {
    static func format(_ seconds: TimeInterval) -> (value: String, unit: String) {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return ("\(minutes)", "min") }
        return (String(format: "%d:%02d", minutes / 60, minutes % 60), "hr")
    }

    /// Spoken form, because "1:45" read aloud is a time, not a duration.
    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let h = minutes / 60, m = minutes % 60
        return "\(h) hour\(h == 1 ? "" : "s")" + (m > 0 ? " \(m) minute\(m == 1 ? "" : "s")" : "")
    }
}

/// Where the term is: week number and how far through.
struct TermProgress: Equatable {
    var week: Int
    var weeks: Int
    var fraction: Double
    var onBreak: String?

    static func make(timetable: Timetable, engine: ScheduleEngine, now: Date) -> TermProgress? {
        guard let start = timetable.termStart, let end = timetable.termEnd, end > start,
              now >= engine.calendar.startOfDay(for: start), now <= end.addingTimeInterval(86_400)
        else { return nil }
        let total = end.timeIntervalSince(start)
        let days = engine.calendar.dateComponents([.day], from: engine.calendar.startOfDay(for: start),
                                                  to: engine.calendar.startOfDay(for: now)).day ?? 0
        return TermProgress(week: days / 7 + 1,
                            weeks: Int((total / (7 * 86_400)).rounded(.up)),
                            fraction: min(1, max(0, now.timeIntervalSince(start) / total)),
                            onBreak: engine.exception(on: now)?.name)
    }
}
