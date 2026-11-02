import SwiftUI

/// Everything any of the eight widgets shows, computed once per timeline entry.
///
/// Pure: built from the snapshot, the palette and a few small preferences, so
/// the widget extension, the app's gallery and the tests all get the same
/// answer from the same inputs. Each widget answers one question and reads
/// only the part of this it needs.
struct WidgetModel {

    enum Quiet: Equatable {
        case noSchedule
        case outOfTerm
        case onBreak(String)
        case noClasses
    }

    var date: Date
    var quiet: Quiet?
    var today: [ScheduleEngine.Occurrence]
    var bell: NextBell?
    var tomorrowFirst: ScheduleEngine.Occurrence?
    var palette: [String: Color]
    /// Free stretches left today, from now.
    var freeAhead: [DateInterval]
    /// Every class and busy block today, for the free track.
    var busyToday: [DateInterval]
    var due: [DeadlinePressure]
    var weekStart: Date
    var week: [[ScheduleEngine.Occurrence]]
    var term: TermProgress?
    /// A class that ended in the last three hours and hasn't been marked.
    var attendancePrompt: ScheduleEngine.Occurrence?

    var finished: [ScheduleEngine.Occurrence] { today.filter { $0.end <= date } }
    var lastEnd: Date? { today.map(\.end).max() }

    func color(for occurrence: ScheduleEngine.Occurrence) -> Color {
        palette[occurrence.event.course] ?? Bell.Surface.scaffold
    }

    /// The longest free stretch still ahead today.
    var bestFree: DateInterval? { freeAhead.max { $0.duration < $1.duration } }

    // MARK: - Building

    static func build(timetable: Timetable,
                      palette: [String: Color],
                      busy: [DateInterval],
                      hidden: Set<String>,
                      leaveBuffer: Int,
                      completedTasks: Set<UUID>,
                      markedAttendance: Set<String>,
                      now: Date,
                      walkSeconds: (String?, String?) -> TimeInterval = Campus.walkingSeconds) -> WidgetModel {
        let engine = ScheduleEngine(timetable: timetable)
        let calendar = engine.calendar
        let visible = { (day: Date) in engine.occurrences(on: day).filter { !hidden.contains($0.event.course) } }
        let today = visible(now)

        let quiet: Quiet? = {
            if timetable.events.isEmpty { return .noSchedule }
            if let holiday = engine.exception(on: now) { return .onBreak(holiday.name) }
            if !engine.isInTerm(now) { return .outOfTerm }
            if today.isEmpty { return .noClasses }
            return nil
        }()

        let busyEvents = busy.enumerated().map {
            ExternalEvent(id: "b\($0.offset)", title: "", start: $0.element.start, end: $0.element.end, calendarTitle: "")
        }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let freeAhead = FreeTime.intervals(engine: engine, busy: busyEvents, from: now, to: endOfDay)
        let busyToday = (today.map { DateInterval(start: $0.start, end: $0.end) }
                         + busy.filter { calendar.isDate($0.start, inSameDayAs: now) })
            .sorted { $0.start < $1.start }

        let horizon = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let open = timetable.tasks.filter { !$0.isDone && !completedTasks.contains($0.id) && $0.due < horizon }
        let due = DeadlinePressure.evaluate(tasks: open, engine: engine, busy: busyEvents, now: now)
            .filter { $0.level != .overdue }
            .sorted { $0.task.due < $1.task.due }

        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -engine.mondayBasedIndex(for: now), to: startOfToday)
            ?? startOfToday
        let dayCount = timetable.showsWeekends ? 7 : 5
        let week = (0 ..< dayCount).map { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart).map(visible) ?? []
        }

        let prompt = today.last { occurrence in
            occurrence.end <= now && now.timeIntervalSince(occurrence.end) < 3 * 3600
                && !markedAttendance.contains(attendanceKey(course: occurrence.event.course, start: occurrence.start))
        }

        return WidgetModel(
            date: now,
            quiet: quiet,
            today: today,
            bell: NextBell.make(engine: engine, hidden: hidden, now: now, bufferMinutes: leaveBuffer,
                                walkSeconds: walkSeconds),
            tomorrowFirst: engine.next(after: endOfDay.addingTimeInterval(-1)).keeping { !hidden.contains($0.event.course) },
            palette: palette,
            freeAhead: freeAhead,
            busyToday: busyToday,
            due: Array(due.prefix(3)),
            weekStart: weekStart,
            week: week,
            term: TermProgress.make(timetable: timetable, engine: engine, now: now),
            attendancePrompt: prompt)
    }

    /// The same identity `AttendanceRecord` uses.
    static func attendanceKey(course: String, start: Date) -> String {
        "\(course)|\(start.timeIntervalSince1970)"
    }

    // MARK: - Timeline

    /// Every moment any widget's contents change, and nothing else: class
    /// starts and ends, each leave-by, task deadlines, when an attendance
    /// prompt expires, and midnight. No fixed-interval polling; countdowns
    /// tick on their own through timer text.
    static func refreshDates(timetable: Timetable, hidden: Set<String>, leaveBuffer: Int, from now: Date,
                             walkSeconds: (String?, String?) -> TimeInterval = Campus.walkingSeconds) -> [Date] {
        let engine = ScheduleEngine(timetable: timetable)
        var points = Set(engine.refreshPoints(from: now, days: 2))

        for offset in 0 ... 2 {
            guard let day = engine.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let classes = engine.occurrences(on: day).filter { !hidden.contains($0.event.course) }
            for (index, occurrence) in classes.enumerated() {
                let origin = index > 0 ? classes[index - 1].event.building : "HOME"
                let walk = walkSeconds(origin, occurrence.event.building)
                if walk > 0 {
                    points.insert(occurrence.start.addingTimeInterval(-walk - TimeInterval(leaveBuffer * 60)))
                }
                points.insert(occurrence.end.addingTimeInterval(3 * 3600))
            }
        }
        for task in timetable.tasks where !task.isDone { points.insert(task.due) }

        return points.filter { $0 > now }.sorted().prefix(60).map { $0 }
    }
}
