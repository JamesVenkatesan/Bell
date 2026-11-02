import Foundation

/// The week just gone and the one coming, counted.
///
/// Looks back at what actually happened (classes held, which ones you made,
/// what got done and what slipped) and forward at what's waiting. Counting
/// happens here; the screen and the Sunday notification only present it.
struct WeeklyReview: Equatable {
    var weekStart: Date
    var classesHeld: Int
    var attended: Int
    var missed: Int
    var unrecorded: Int
    var minutesInClass: Int
    var cancelled: Int
    var tasksDone: [TaskEvent]
    var tasksSlipped: [TaskEvent]
    var busiestDay: (day: Date, minutes: Int)?

    var nextWeekClasses: Int
    var nextWeekFirst: ScheduleEngine.Occurrence?
    var dueNextWeek: [TaskEvent]

    static func == (a: WeeklyReview, b: WeeklyReview) -> Bool {
        a.weekStart == b.weekStart && a.classesHeld == b.classesHeld && a.attended == b.attended
            && a.missed == b.missed && a.unrecorded == b.unrecorded && a.minutesInClass == b.minutesInClass
            && a.cancelled == b.cancelled && a.tasksDone == b.tasksDone && a.tasksSlipped == b.tasksSlipped
            && a.busiestDay?.day == b.busiestDay?.day && a.busiestDay?.minutes == b.busiestDay?.minutes
            && a.nextWeekClasses == b.nextWeekClasses && a.nextWeekFirst == b.nextWeekFirst
            && a.dueNextWeek == b.dueNextWeek
    }

    /// The Monday that starts the week containing `date`.
    static func monday(of date: Date, engine: ScheduleEngine) -> Date {
        let day = engine.calendar.startOfDay(for: date)
        return engine.calendar.date(byAdding: .day, value: -engine.mondayBasedIndex(for: day), to: day) ?? day
    }

    /// - Parameter weekStart: the Monday of the week being reviewed.
    static func build(weekStart: Date,
                      engine: ScheduleEngine,
                      attendance: [(course: String, entry: AttendanceEntry)],
                      hidden: Set<String> = []) -> WeeklyReview {
        let calendar = engine.calendar
        let days = (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        guard let nextStart = calendar.date(byAdding: .day, value: 7, to: weekStart),
              let nextEnd = calendar.date(byAdding: .day, value: 14, to: weekStart) else {
            return WeeklyReview(weekStart: weekStart, classesHeld: 0, attended: 0, missed: 0, unrecorded: 0,
                                minutesInClass: 0, cancelled: 0, tasksDone: [], tasksSlipped: [],
                                busiestDay: nil, nextWeekClasses: 0, nextWeekFirst: nil, dueNextWeek: [])
        }

        let held = days.flatMap { engine.occurrences(on: $0) }.filter { !hidden.contains($0.event.course) }

        // The same identity AttendanceRecord.key uses: course and exact start.
        var states: [String: AttendanceState] = [:]
        for (course, entry) in attendance {
            states["\(course)|\(entry.date.timeIntervalSince1970)"] = entry.state
        }
        var attended = 0, missed = 0, unrecorded = 0
        for occurrence in held {
            switch states["\(occurrence.event.course)|\(occurrence.start.timeIntervalSince1970)"] {
            case .attended?: attended += 1
            case .missed?: missed += 1
            // Excused counts as neither: it was decided, not skipped.
            case .excused?: break
            case .unknown?, nil: unrecorded += 1
            }
        }

        let byDay = days.map { day in
            (day, engine.occurrences(on: day).filter { !hidden.contains($0.event.course) }
                .reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) })
        }
        let busiest = byDay.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? (day: $0.0, minutes: $0.1) : nil }

        let thisWeek = engine.timetable.tasks.filter { $0.due >= weekStart && $0.due < nextStart }
        let next = (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: nextStart) }
            .flatMap { engine.occurrences(on: $0) }.filter { !hidden.contains($0.event.course) }

        return WeeklyReview(
            weekStart: weekStart,
            classesHeld: held.count,
            attended: attended,
            missed: missed,
            unrecorded: unrecorded,
            minutesInClass: byDay.reduce(0) { $0 + $1.1 },
            cancelled: days.flatMap { engine.cancelledOccurrences(on: $0) }.count,
            tasksDone: thisWeek.filter(\.isDone).sorted { $0.due < $1.due },
            tasksSlipped: thisWeek.filter { !$0.isDone }.sorted { $0.due < $1.due },
            busiestDay: busiest,
            nextWeekClasses: next.count,
            nextWeekFirst: next.first,
            dueNextWeek: engine.timetable.tasks
                .filter { !$0.isDone && $0.due >= nextStart && $0.due < nextEnd }
                .sorted { $0.due < $1.due })
    }

    // MARK: - Prose

    /// Plain sentences, same rules as the brief. Missed classes are stated,
    /// not scolded: the review is for planning, and a lecture loses readers.
    var summary: String {
        var sentences: [String] = []
        let hours = Double(minutesInClass) / 60
        let hoursText = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)

        if classesHeld == 0 {
            sentences.append("No classes this week.")
        } else {
            var line = "\(classesHeld) class\(classesHeld == 1 ? "" : "es") this week, \(hoursText) hours in all"
            if attended + missed > 0 {
                line += missed == 0
                    ? ", and you made every one you marked"
                    : ", and you marked \(missed) as missed"
            }
            sentences.append(line + ".")
        }
        if let busiest = busiestDay, classesHeld > 0 {
            sentences.append("\(busiest.day.formatted(.dateTime.weekday(.wide))) was the longest day.")
        }
        if !tasksDone.isEmpty {
            sentences.append("\(tasksDone.count) thing\(tasksDone.count == 1 ? "" : "s") done.")
        }
        if let slipped = tasksSlipped.first {
            sentences.append(tasksSlipped.count == 1
                             ? "\(slipped.title) is still open."
                             : "\(tasksSlipped.count) things are still open, starting with \(slipped.title).")
        }
        if let first = nextWeekFirst {
            sentences.append("Next week has \(nextWeekClasses) classes, starting \(first.start.formatted(.dateTime.weekday(.wide))) "
                             + "with \(first.event.course) at \(BriefWriter.clock(first.start)).")
        }
        if let due = dueNextWeek.first {
            sentences.append(dueNextWeek.count == 1
                             ? "\(due.title) is due \(due.due.formatted(.dateTime.weekday(.wide)))."
                             : "\(dueNextWeek.count) things are due, the first on \(due.due.formatted(.dateTime.weekday(.wide))).")
        }
        return sentences.joined(separator: " ")
    }
}
