import Foundation

/// An exam coming up, and how loudly to say so.
struct ExamWarning: Equatable {
    var task: TaskEvent
    /// Calendar days from today: 0 is today, 1 tomorrow.
    var daysOut: Int

    static let horizonDays = 7

    /// The soonest open exam today or in the next seven days. A timed exam
    /// stays "today" until two hours after it starts, which covers sitting
    /// it; an all-day one stays for the whole day.
    static func nearest(in tasks: [TaskEvent], now: Date, calendar: Calendar = .current) -> ExamWarning? {
        let today = calendar.startOfDay(for: now)
        return tasks
            .filter { $0.kind == .exam && !$0.isDone }
            .filter { $0.allDay ? calendar.startOfDay(for: $0.due) >= today : $0.due.addingTimeInterval(2 * 3600) > now }
            .compactMap { task -> ExamWarning? in
                let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: task.due)).day ?? 0
                return days <= horizonDays ? ExamWarning(task: task, daysOut: days) : nil
            }
            .min { $0.task.due < $1.task.due }
    }
}

/// What Bell Max shows at a moment of the day.
///
/// One hero, one list, one footer line. The hero is the single thing that
/// matters now, chosen in a fixed order: an exam today or tomorrow, then the
/// next bell, then (once classes are over) the next deadline, then a plain
/// statement of a quiet day. The list is the rest of today in time order,
/// classes, deadlines and an exam merged rather than stacked in sections,
/// because "what's next, and then what" is one question, not three. The
/// footer carries one more thing at most: an exam a few days out, or stale
/// Notion data.
///
/// Pure, so the choices are tested rather than eyeballed.
struct MaxLayout: Equatable {

    enum Hero: Equatable {
        /// Today or tomorrow: nothing else on the widget matters as much.
        case exam(ExamWarning)
        case bell(NextBell)
        /// Classes are over; the earliest open deadline today.
        case due(TaskEvent)
        case quiet(Quiet)
    }

    enum Quiet: Equatable {
        /// Classes happened and are over, with nothing due.
        case done(at: Date)
        /// A class-free day: weekend, or a day with no meetings.
        case noClasses
        /// A break, out of term, or no schedule at all.
        case away(String)
    }

    struct Row: Equatable, Identifiable {
        enum Item: Equatable {
            case meeting(ScheduleEngine.Occurrence)
            case deadline(TaskEvent)
            case exam(TaskEvent)
        }
        var item: Item
        var time: Date
        /// A class that has ended. Dimmed, never removed: it fills spare
        /// room above what's still ahead, the way the day actually went.
        var isPast: Bool
        /// A deadline whose time has gone and isn't done.
        var isMissed: Bool
        /// Not today: labelled with its weekday. Only in "coming up".
        var isLater = false

        var id: String {
            switch item {
            case .meeting(let o): o.id
            case .deadline(let t), .exam(let t): t.id.uuidString
            }
        }
    }

    enum Footer: Equatable {
        case exam(ExamWarning)
        case stale(Date)
    }

    var hero: Hero
    var rows: [Row]
    /// Items still ahead today that didn't fit.
    var more: Int
    var footer: Footer?
    /// Set when the list isn't today: a quiet day shows what's coming up
    /// over the next few days instead of nothing.
    var listTitle: String?

    /// Rows that fit under the hero at a size that's comfortable to read.
    static let rowLimit = 4

    static func make(_ m: WidgetModel) -> MaxLayout {
        let hero = Self.hero(m)

        // Everything today, in time order, minus whatever the hero shows.
        var items: [Row] = m.today.map {
            Row(item: .meeting($0), time: $0.start, isPast: $0.end <= m.date, isMissed: false)
        }
        items += m.dueToday.map { task in
            Row(item: task.kind == .exam ? .exam(task) : .deadline(task),
                time: task.due, isPast: false, isMissed: !task.allDay && task.due < m.date)
        }
        if let exam = m.exam, exam.daysOut == 0 {
            items.append(Row(item: .exam(exam.task), time: exam.task.due, isPast: false, isMissed: false))
        }
        items.removeAll { row in
            switch (hero, row.item) {
            case (.bell(let bell), .meeting(let o)): o.id == bell.occurrence.id
            case (.due(let task), .deadline(let t)): t.id == task.id
            case (.exam(let exam), .exam(let t)): t.id == exam.task.id
            default: false
            }
        }
        // All-day deadlines have no time of their own; they sort as the
        // end of the day, after everything timed.
        items.sort { a, b in sortKey(a, m) < sortKey(b, m) }

        let ahead = items.filter { !$0.isPast }
        let past = items.filter(\.isPast)
        let shownAhead = Array(ahead.prefix(rowLimit))
        let room = rowLimit - shownAhead.count
        var rows = (room > 0 ? Array(past.suffix(room)) : []) + shownAhead
        var listTitle: String?

        // A quiet day with nothing left today: the list looks ahead
        // instead, to the next class and the week's deadlines. Something
        // true and useful, rather than an empty widget.
        if case .quiet = hero, ahead.isEmpty {
            var later: [Row] = m.due.map {
                Row(item: $0.task.kind == .exam ? .exam($0.task) : .deadline($0.task),
                    time: $0.task.due, isPast: false, isMissed: false, isLater: true)
            }
            if let next = m.tomorrowFirst {
                later.append(Row(item: .meeting(next), time: next.start, isPast: false, isMissed: false, isLater: true))
            }
            later.sort { $0.time < $1.time }
            if !later.isEmpty {
                rows = Array(later.prefix(rowLimit))
                listTitle = "Coming up"
            }
        }

        var footer: Footer?
        if let exam = m.exam, exam.daysOut > 1 {
            footer = .exam(exam)
        } else if m.notionIsStale, let synced = m.notionSyncedAt {
            footer = .stale(synced)
        }
        return MaxLayout(hero: hero, rows: rows, more: ahead.count - shownAhead.count, footer: footer,
                         listTitle: listTitle)
    }

    private static func sortKey(_ row: Row, _ m: WidgetModel) -> Date {
        if case .deadline(let task) = row.item, task.allDay {
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: m.date) ?? row.time
        }
        return row.time
    }

    private static func hero(_ m: WidgetModel) -> Hero {
        if let exam = m.exam, exam.daysOut <= 1 { return .exam(exam) }
        if let bell = m.bell { return .bell(bell) }
        // The next deadline still ahead, or failing that the earliest one
        // missed: either way, today's unfinished work.
        if let next = m.dueToday.first(where: { $0.allDay || $0.due >= m.date }) ?? m.dueToday.first {
            return .due(next)
        }
        switch m.quiet {
        case .onBreak(let name)?: return .quiet(.away(name))
        case .outOfTerm?: return .quiet(.away("Out of term"))
        case .noSchedule?: return .quiet(.away("No schedule yet"))
        case .noClasses?: return .quiet(.noClasses)
        case nil: return .quiet(m.lastEnd.map { .done(at: $0) } ?? .noClasses)
        }
    }
}
