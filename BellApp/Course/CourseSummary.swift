import Foundation

/// Everything the course page shows, worked out ahead of drawing it.
///
/// Built from value types the store and engine already hand out, so the page
/// is a pure function of the schedule and the attendance log, and the
/// arithmetic (rates, streaks, what counts as upcoming) has tests rather than
/// living in view bodies.
struct CourseSummary {

    struct Mark: Identifiable, Hashable {
        var occurrence: ScheduleEngine.Occurrence
        /// nil when nobody has said either way. Distinct from `.missed`: an
        /// unrecorded class is unknown, not absent, and the page draws it
        /// that way.
        var state: AttendanceState?
        var wasAutomatic: Bool

        var id: String { occurrence.id }
    }

    var course: String
    /// Newest first.
    var history: [Mark]
    var upcoming: [ScheduleEngine.Occurrence]
    var work: [TaskEvent]
    /// Distinct weekly meetings, Monday first, for the "every week" summary.
    var weeklyPattern: [ClassEvent]

    // MARK: - Derived

    /// Attended over recorded. nil when nothing has been recorded, which the
    /// page shows as "no record yet" rather than as 0%.
    var attendanceRate: Double? {
        let recorded = history.filter { $0.state != nil && $0.state != .unknown && $0.state != .excused }
        guard !recorded.isEmpty else { return nil }
        return Double(recorded.filter { $0.state == .attended }.count) / Double(recorded.count)
    }

    /// Consecutive attended meetings counting back from the latest recorded
    /// one. Unrecorded meetings are skipped over rather than breaking the
    /// streak, because forgetting to tap isn't the same as not going.
    var streak: Int {
        var count = 0
        for mark in history {
            switch mark.state {
            case .attended?: count += 1
            case nil, .unknown?, .excused?: continue
            case .missed?: return count
            }
        }
        return count
    }

    var weeklyMinutes: Int {
        weeklyPattern.reduce(0) { $0 + $1.duration / 60 }
    }

    // MARK: - Building

    static func build(course: String,
                      engine: ScheduleEngine,
                      attendance: [AttendanceEntry],
                      now: Date,
                      historyLimit: Int = 24) -> CourseSummary {
        let past = engine.pastOccurrences(ofCourse: course, before: now, limit: historyLimit)

        // Keyed on the exact start instant, the same identity
        // `AttendanceRecord.key` uses, so a record always finds its meeting.
        var byStart: [TimeInterval: AttendanceEntry] = [:]
        for entry in attendance { byStart[entry.date.timeIntervalSince1970] = entry }

        let history = past.map { occurrence in
            let entry = byStart[occurrence.start.timeIntervalSince1970]
            return Mark(occurrence: occurrence,
                        state: entry?.state,
                        wasAutomatic: entry?.wasAutomatic ?? false)
        }

        let work = engine.timetable.tasks
            .filter { $0.course.map { sameFamily($0, course) } ?? false }
            .filter { !$0.isDone && $0.due >= Calendar.current.startOfDay(for: now) }
            .sorted { $0.due < $1.due }

        let pattern = engine.timetable.events
            .filter { $0.course == course }
            .sorted { ($0.weekIndex, $0.dayIndex, $0.startSecond) < ($1.weekIndex, $1.dayIndex, $1.startSecond) }

        return CourseSummary(
            course: course,
            history: history,
            upcoming: engine.upcomingOccurrences(ofCourse: course, after: now, limit: 3),
            work: work,
            weeklyPattern: pattern)
    }

    /// Work filed against "ECE 30864" belongs on the lab's page too: the
    /// registrar splits them, the student doesn't.
    private static func sameFamily(_ a: String, _ b: String) -> Bool {
        family(a) == family(b)
    }

    private static func family(_ code: String) -> String {
        ClassEvent(course: code, room: "", dayIndex: 0, startSecond: 0, endSecond: 0, weekIndex: 0)
            .courseFamily
    }
}
