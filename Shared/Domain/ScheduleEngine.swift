import Foundation

/// Turns the weekly grid into concrete dated occurrences and answers the
/// questions the widget actually asks: what's on now, what's next, how long
/// until I have to leave, and when does the day end.
struct ScheduleEngine {
    var timetable: Timetable
    var calendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2 // Monday, matching dayNum 0
        return c
    }()

    // MARK: - Occurrences

    /// A class pinned to a real date.
    struct Occurrence: Hashable, Identifiable {
        var event: ClassEvent
        var start: Date
        var end: Date

        var id: String { "\(event.id)-\(start.timeIntervalSince1970)" }

        /// Identity of one meeting across rebuilds and across processes:
        /// course plus start instant, in whole seconds so it survives a
        /// round trip through a calendar server's text encoding.
        var key: String { "\(event.course)|\(Int(start.timeIntervalSince1970))" }

        func status(at now: Date) -> Status {
            if now < start { .upcoming }
            else if now < end { .inProgress }
            else { .finished }
        }

        enum Status { case upcoming, inProgress, finished }

        /// 0…1 through the class. Clamped.
        func progress(at now: Date) -> Double {
            let span = end.timeIntervalSince(start)
            guard span > 0 else { return 1 }
            return min(1, max(0, now.timeIntervalSince(start) / span))
        }
    }

    func occurrences(on day: Date) -> [Occurrence] {
        let all = scheduledOccurrences(on: day)
        guard !timetable.cancelled.isEmpty else { return all }
        return all.filter { !timetable.cancelled.contains($0.key) }
    }

    /// Meetings on a day that were cancelled one by one. Shown as ghosts in
    /// the day view so a cancellation can be seen and undone.
    func cancelledOccurrences(on day: Date) -> [Occurrence] {
        guard !timetable.cancelled.isEmpty else { return [] }
        return scheduledOccurrences(on: day).filter { timetable.cancelled.contains($0.key) }
    }

    /// The weekly pattern applied to a date, before single cancellations.
    private func scheduledOccurrences(on day: Date) -> [Occurrence] {
        guard isInTerm(day), exception(on: day) == nil else { return [] }

        let dayIndex = mondayBasedIndex(for: day)
        let weekIndex = rotationWeek(for: day)

        return timetable.events
            .filter { $0.dayIndex == dayIndex && $0.weekIndex == weekIndex }
            .map { Occurrence(event: $0, start: $0.start(on: day, calendar: calendar),
                              end: $0.end(on: day, calendar: calendar)) }
            .sorted { $0.start < $1.start }
    }

    func occurrences(from day: Date, forwardDays count: Int) -> [Occurrence] {
        (0 ..< count).flatMap { offset -> [Occurrence] in
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else { return [] }
            return occurrences(on: date)
        }
    }

    // MARK: - Questions the widget asks

    func current(at now: Date = .now) -> Occurrence? {
        occurrences(on: now).first { $0.status(at: now) == .inProgress }
    }

    /// The next class, searching forward across days. Skips breaks and term gaps.
    func next(after now: Date = .now, searchLimitDays: Int = 21) -> Occurrence? {
        for offset in 0 ..< searchLimitDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            if let hit = occurrences(on: date).first(where: { $0.start > now }) { return hit }
        }
        return nil
    }

    func remainingToday(at now: Date = .now) -> [Occurrence] {
        occurrences(on: now).filter { $0.end > now }
    }

    /// Free stretches between classes today, long enough to be worth naming.
    func gaps(on day: Date, minimumMinutes: Int = 30) -> [(start: Date, end: Date)] {
        let today = occurrences(on: day)
        guard today.count > 1 else { return [] }

        return zip(today, today.dropFirst()).compactMap { first, second in
            let span = second.start.timeIntervalSince(first.end)
            guard span >= Double(minimumMinutes * 60) else { return nil }
            return (first.end, second.start)
        }
    }

    /// When you need to walk out of the room you're in to make the next class.
    /// Returns nil when there's no walk to worry about.
    func leaveTime(for occurrence: Occurrence, comingFrom previous: Occurrence?) -> Date? {
        let origin = previous?.event.building
        let walk = Campus.walkingSeconds(from: origin, to: occurrence.event.building)
        guard walk > 0 else { return nil }
        return occurrence.start.addingTimeInterval(-walk)
    }

    /// True when the gap between two back-to-back classes is tighter than the walk.
    func isTightTransition(from first: Occurrence, to second: Occurrence) -> Bool {
        let available = second.start.timeIntervalSince(first.end)
        let needed = Campus.walkingSeconds(from: first.event.building, to: second.event.building)
        return needed > 0 && available < needed
    }

    func tightTransitionsThisWeek(from day: Date) -> [(from: Occurrence, to: Occurrence)] {
        (0 ..< 7).flatMap { offset -> [(Occurrence, Occurrence)] in
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else { return [] }
            let today = occurrences(on: date)
            return zip(today, today.dropFirst()).filter(isTightTransition).map { ($0, $1) }
        }
    }

    // MARK: - One course

    /// The most recent meetings of a course that have started, newest first.
    /// "Started" rather than "finished" so the class you're sitting in can be
    /// marked attended without waiting for it to end.
    func pastOccurrences(ofCourse course: String,
                         before now: Date,
                         limit: Int,
                         searchDays: Int = 140) -> [Occurrence] {
        var found: [Occurrence] = []
        for offset in 0 ..< searchDays {
            guard found.count < limit,
                  let date = calendar.date(byAdding: .day, value: -offset, to: now) else { break }
            let hits = occurrences(on: date)
                .filter { $0.event.course == course && $0.start <= now }
                .reversed()
            found.append(contentsOf: hits)
            // Stop once before term start; every earlier day is empty anyway.
            if let start = timetable.termStart, date < calendar.startOfDay(for: start) { break }
        }
        return Array(found.prefix(limit))
    }

    func upcomingOccurrences(ofCourse course: String,
                             after now: Date,
                             limit: Int,
                             searchDays: Int = 28) -> [Occurrence] {
        var found: [Occurrence] = []
        for offset in 0 ..< searchDays {
            guard found.count < limit,
                  let date = calendar.date(byAdding: .day, value: offset, to: now) else { break }
            found.append(contentsOf: occurrences(on: date)
                .filter { $0.event.course == course && $0.start > now })
        }
        return Array(found.prefix(limit))
    }

    // MARK: - Calendar reasoning

    func isInTerm(_ date: Date) -> Bool {
        if let start = timetable.termStart, date < calendar.startOfDay(for: start) { return false }
        // By day, like the start: a term "ending 12 Dec" includes that whole
        // day, not just its first instant.
        if let end = timetable.termEnd,
           calendar.startOfDay(for: date) > calendar.startOfDay(for: end) { return false }
        return true
    }

    func exception(on date: Date) -> ScheduleException? {
        timetable.exceptions.first { $0.contains(date, calendar: calendar) }
    }

    /// Monday = 0 … Sunday = 6, matching the export's `dayNum`.
    func mondayBasedIndex(for date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    func rotationWeek(for date: Date) -> Int {
        guard timetable.weekCount > 1 else { return 0 }
        let anchor = calendar.startOfDay(for: timetable.rotationAnchor)
        let weeks = calendar.dateComponents([.weekOfYear], from: anchor, to: date).weekOfYear ?? 0
        return ((weeks % timetable.weekCount) + timetable.weekCount) % timetable.weekCount
    }

    // MARK: - Timeline planning

    /// Every moment the widget's contents change: class starts, class ends,
    /// leave-now thresholds, and midnight. WidgetKit gets exactly these and
    /// nothing else, so the widget never shows a stale minute.
    func refreshPoints(from now: Date, days: Int = 3) -> [Date] {
        var points: Set<Date> = [now]

        for offset in 0 ... days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            points.insert(calendar.startOfDay(for: date))

            let today = occurrences(on: date)
            for (index, occurrence) in today.enumerated() {
                points.insert(occurrence.start)
                points.insert(occurrence.end)
                let previous = index > 0 ? today[index - 1] : nil
                if let leave = leaveTime(for: occurrence, comingFrom: previous) {
                    points.insert(leave)
                }
            }
        }

        return points.filter { $0 >= now }.sorted()
    }
}
