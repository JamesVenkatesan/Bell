import Foundation

// The arithmetic behind Phase 5. Every number the brief, the chat or the
// weekly review states comes from here, computed and tested, and the
// language model is only ever asked to phrase it. A model asked "how much
// free time do I have before Friday" will produce a confident number; this
// file produces the right one.

// MARK: - Free time

enum FreeTime {

    /// Hours a person is plausibly awake and able to work. Free time at 3am
    /// isn't free time, and counting it made every deadline look easy.
    struct WakingHours: Equatable {
        var start: Int = 8
        var end: Int = 22
    }

    /// Stretches with nothing scheduled, inside waking hours, each at least
    /// `minimumMinutes` long. Shorter fragments are walking time, not time
    /// to get anything done.
    static func intervals(engine: ScheduleEngine,
                          busy: [ExternalEvent] = [],
                          from start: Date,
                          to end: Date,
                          waking: WakingHours = .init(),
                          minimumMinutes: Int = 30) -> [DateInterval] {
        guard end > start else { return [] }
        let calendar = engine.calendar
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: start)

        func append(_ a: Date, _ b: Date) {
            if b.timeIntervalSince(a) >= Double(minimumMinutes * 60) {
                result.append(DateInterval(start: a, end: b))
            }
        }

        while day < end {
            guard let wakeStart = calendar.date(bySettingHour: waking.start, minute: 0, second: 0, of: day),
                  let wakeEnd = calendar.date(bySettingHour: waking.end, minute: 0, second: 0, of: day),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }

            let windowStart = max(start, wakeStart)
            let windowEnd = min(end, wakeEnd)
            if windowEnd > windowStart {
                let blocks = (engine.occurrences(on: day).map { ($0.start, $0.end) }
                              + busy.filter(\.occupiesTime).map { ($0.start, $0.end) })
                    .filter { $0.1 > windowStart && $0.0 < windowEnd }
                    .sorted { $0.0 < $1.0 }

                var cursor = windowStart
                for (blockStart, blockEnd) in blocks {
                    if blockStart > cursor { append(cursor, blockStart) }
                    cursor = max(cursor, blockEnd)
                }
                if windowEnd > cursor { append(cursor, windowEnd) }
            }
            day = next
        }
        return result
    }

    static func hours(_ intervals: [DateInterval]) -> Double {
        intervals.reduce(0) { $0 + $1.duration } / 3600
    }
}

// MARK: - Deadline pressure

/// How much work is due against how much free time is left to do it.
///
/// The free time is measured; the effort is an estimate, and the UI says
/// which is which. Effort defaults are deliberately rough and per kind,
/// because asking for an estimate on every task is friction nobody keeps up.
struct DeadlinePressure: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case comfortable, tight, critical, overdue
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var task: TaskEvent
    var freeHours: Double
    var effortHours: Double
    var level: Level

    var id: UUID { task.id }

    static func effortHours(for kind: TaskEvent.Kind) -> Double {
        switch kind {
        case .exam: 6
        case .project: 8
        case .assignment: 3
        case .quiz: 2
        case .other: 1
        case .meeting: 0
        }
    }

    /// Open work, most pressing first. Meetings are excluded: an interview
    /// needs you there, not hours of preparation the app can count.
    static func evaluate(tasks: [TaskEvent],
                         engine: ScheduleEngine,
                         busy: [ExternalEvent] = [],
                         now: Date) -> [DeadlinePressure] {
        tasks
            .filter { !$0.isDone && $0.kind != .meeting }
            .map { task in
                let effort = effortHours(for: task.kind)
                guard task.due > now else {
                    return DeadlinePressure(task: task, freeHours: 0, effortHours: effort, level: .overdue)
                }
                let free = FreeTime.hours(FreeTime.intervals(engine: engine, busy: busy, from: now, to: task.due))
                return DeadlinePressure(task: task, freeHours: free, effortHours: effort,
                                        level: level(effort: effort, free: free))
            }
            .sorted { ($0.level, $1.task.due) > ($1.level, $0.task.due) }
    }

    /// Needing a third of your free time is fine. Needing three quarters of
    /// it means everything else has to give.
    static func level(effort: Double, free: Double) -> Level {
        guard effort > 0 else { return .comfortable }
        guard free > 0 else { return .critical }
        let ratio = effort / free
        if ratio <= 0.35 { return .comfortable }
        if ratio <= 0.75 { return .tight }
        return .critical
    }
}

// MARK: - Gap suggestions

/// What a free stretch between classes is good for.
///
/// Concrete or nothing. "You have free time" is what the timeline already
/// shows; a suggestion earns its place by naming the task that most needs
/// the hour, or by noticing the gap is the only one at lunchtime.
enum GapAdvisor {

    struct Suggestion: Equatable {
        var gapStart: Date
        var text: String
        var task: TaskEvent?
    }

    static func suggest(gaps: [DateInterval],
                        pressures: [DeadlinePressure],
                        calendar: Calendar = .current) -> [Suggestion] {
        var queue = pressures.filter { $0.level != .overdue && $0.effortHours > 0 }
        var result: [Suggestion] = []

        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            let minutes = gap.duration / 60
            guard minutes >= 30 else { continue }

            // Work first when something is pressing: a lunch suggestion that
            // displaces the only hour for an exam is the wrong advice.
            if minutes >= 45, let index = queue.firstIndex(where: { $0.task.due > gap.end }),
               queue[index].level >= .tight || minutes >= 60 {
                let pressure = queue.remove(at: index)
                result.append(Suggestion(gapStart: gap.start,
                                         text: "Good for \(pressure.task.title)",
                                         task: pressure.task))
                continue
            }

            if overlapsLunch(gap, calendar: calendar), minutes >= 40 {
                result.append(Suggestion(gapStart: gap.start, text: "Time for lunch", task: nil))
            }
        }
        return result
    }

    private static func overlapsLunch(_ gap: DateInterval, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: gap.start)
        guard let from = calendar.date(bySettingHour: 11, minute: 30, second: 0, of: day),
              let to = calendar.date(bySettingHour: 13, minute: 30, second: 0, of: day) else { return false }
        return gap.intersection(with: DateInterval(start: from, end: to)).map { $0.duration >= 30 * 60 } ?? false
    }
}

// MARK: - Wake-up

/// When to get up for the first class of a day.
///
/// first class − walk − head start − morning routine. The walk is the
/// adaptive part: from home when its coordinate is known, from wherever the
/// phone last was otherwise, and a stated guess when neither is available.
struct WakePlan: Equatable {
    enum WalkSource: Equatable { case home, lastLocation, estimate }

    var firstClass: ScheduleEngine.Occurrence
    var walkMinutes: Int
    var walkSource: WalkSource
    var leaveAt: Date
    var wakeAt: Date

    /// Used when Bell has no idea where you'll start from. Says so in the UI.
    static let defaultWalkMinutes = 15

    static func make(day: Date,
                     engine: ScheduleEngine,
                     hidden: Set<String> = [],
                     walkMinutes: Int?,
                     walkSource: WalkSource,
                     routineMinutes: Int,
                     bufferMinutes: Int) -> WakePlan? {
        guard let first = engine.occurrences(on: day).first(where: { !hidden.contains($0.event.course) })
        else { return nil }

        let walk = walkMinutes ?? defaultWalkMinutes
        let source = walkMinutes == nil ? .estimate : walkSource
        let leave = first.start.addingTimeInterval(-Double((walk + bufferMinutes) * 60))
        let wake = roundDown(leave.addingTimeInterval(-Double(routineMinutes * 60)), toMinutes: 5,
                             calendar: engine.calendar)
        return WakePlan(firstClass: first, walkMinutes: walk, walkSource: source,
                        leaveAt: roundDown(leave, toMinutes: 1, calendar: engine.calendar), wakeAt: wake)
    }

    /// Alarms on round minutes: 6:35 reads as deliberate, 6:37 as a bug.
    /// Down, never up: rounding up would cost the user minutes they planned.
    static func roundDown(_ date: Date, toMinutes step: Int, calendar: Calendar) -> Date {
        let minute = calendar.component(.minute, from: date)
        let second = calendar.component(.second, from: date)
        return date.addingTimeInterval(-Double((minute % step) * 60 + second))
    }
}
