import XCTest
@testable import Bell

// The widgets' model: what each one shows, and when it changes.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

/// Mon: 9:30–10:20 WALC 2088, 13:00–14:00 BHEE 170. Term from 26 Oct.
private func timetable(tasks: [TaskEvent] = [], exceptions: [ScheduleException] = []) -> Timetable {
    var table = Timetable()
    table.events = [
        ClassEvent(course: "ECE 30864", room: "WALC 2088", dayIndex: 0,
                   startSecond: 9 * 3600 + 1800, endSecond: 10 * 3600 + 1200, weekIndex: 0),
        ClassEvent(course: "ECE 30200", room: "BHEE 170", dayIndex: 0,
                   startSecond: 13 * 3600, endSecond: 14 * 3600, weekIndex: 0),
    ]
    table.tasks = tasks
    table.exceptions = exceptions
    table.termStart = date(2026, 10, 26)
    table.termEnd = date(2026, 12, 12)
    return table
}

private func walk(_ a: String?, _ b: String?) -> TimeInterval {
    guard let a, let b, a != b, a != "HOME" else { return 0 }
    return 10 * 60
}

private func model(_ table: Timetable, at now: Date, busy: [DateInterval] = [],
                   completed: Set<UUID> = [], marked: Set<String> = []) -> WidgetModel {
    WidgetModel.build(timetable: table, palette: [:], busy: busy, hidden: [], leaveBuffer: 5,
                      completedTasks: completed, markedAttendance: marked, now: now, walkSeconds: walk)
}

final class WidgetModelTests: XCTestCase {

    // MARK: Empty states say something true

    func testEmptyStates() {
        XCTAssertEqual(model(.empty, at: date(2026, 11, 2, 9)).quiet, .noSchedule)
        XCTAssertEqual(model(timetable(), at: date(2026, 11, 7, 9)).quiet, .noClasses, "Saturday")
        XCTAssertEqual(model(timetable(), at: date(2027, 1, 4, 9)).quiet, .outOfTerm)
        let onBreak = timetable(exceptions: [ScheduleException(name: "Fall break", start: date(2026, 11, 2), end: date(2026, 11, 2))])
        XCTAssertEqual(model(onBreak, at: date(2026, 11, 2, 9)).quiet, .onBreak("Fall break"))
    }

    func testAfterTheLastClassThereIsNoBellButTomorrowIsKnown() {
        let m = model(timetable(), at: date(2026, 11, 2, 15))
        XCTAssertNil(m.quiet, "A class day, just finished")
        XCTAssertNil(m.bell)
        XCTAssertEqual(m.tomorrowFirst?.start, date(2026, 11, 9, 9, 30), "Next Monday: Tuesday to Sunday are clear")
    }

    // MARK: Each widget's answer

    func testBehindMeCountsFinishedClasses() {
        XCTAssertEqual(model(timetable(), at: date(2026, 11, 2, 11)).finished.count, 1)
    }

    func testFreeIsTheLongestStretchAheadAndHonoursOtherCalendars() {
        let m = model(timetable(), at: date(2026, 11, 2, 10, 30))
        XCTAssertEqual(m.bestFree, DateInterval(start: date(2026, 11, 2, 14), end: date(2026, 11, 2, 22)))

        let dentist = DateInterval(start: date(2026, 11, 2, 15), end: date(2026, 11, 2, 21))
        let busy = model(timetable(), at: date(2026, 11, 2, 10, 30), busy: [dentist])
        XCTAssertEqual(busy.bestFree, DateInterval(start: date(2026, 11, 2, 10, 30), end: date(2026, 11, 2, 13)),
                       "With the evening taken, the morning gap is the longest")
    }

    func testDueShowsOpenWorkInDateOrderAndHidesWidgetTicks() {
        let a = TaskEvent(title: "A", due: date(2026, 11, 4), kind: .assignment)
        let b = TaskEvent(title: "B", due: date(2026, 11, 3), kind: .quiz)
        let done = TaskEvent(title: "Done", due: date(2026, 11, 3), kind: .quiz, isDone: true)
        let farAway = TaskEvent(title: "Later", due: date(2026, 12, 1), kind: .exam)
        let m = model(timetable(tasks: [a, b, done, farAway]), at: date(2026, 11, 2, 9), completed: [a.id])
        XCTAssertEqual(m.due.map(\.task.title), ["B"], "Ticked in the widget, already done, or over a week out")
    }

    func testAttendancePromptForTheClassJustFinishedUntilMarked() {
        let at = date(2026, 11, 2, 10, 45)
        let m = model(timetable(), at: at)
        XCTAssertEqual(m.attendancePrompt?.event.course, "ECE 30864")

        let key = WidgetModel.attendanceKey(course: "ECE 30864", start: date(2026, 11, 2, 9, 30))
        XCTAssertNil(model(timetable(), at: at, marked: [key]).attendancePrompt)
        XCTAssertEqual(model(timetable(), at: date(2026, 11, 2, 14, 30)).attendancePrompt?.event.course, "ECE 30200",
                       "The most recent finished class is the one asked about")
        XCTAssertNil(model(timetable(), at: date(2026, 11, 2, 18)).attendancePrompt, "Three hours on, it stops asking")
    }

    func testWeekRunsMondayToFriday() {
        let m = model(timetable(), at: date(2026, 11, 4, 9))
        XCTAssertEqual(m.weekStart, date(2026, 11, 2))
        XCTAssertEqual(m.week.count, 5)
        XCTAssertEqual(m.week[0].count, 2)
    }

    func testTermProgress() {
        XCTAssertEqual(model(timetable(), at: date(2026, 11, 2, 9)).term?.week, 2)
    }

    // MARK: Timeline boundaries

    /// Every moment a widget changes, and nothing in between.
    func testRefreshDatesAreExactBoundaries() {
        let table = timetable(tasks: [TaskEvent(title: "T", due: date(2026, 11, 2, 23, 59), kind: .assignment)])
        let dates = WidgetModel.refreshDates(timetable: table, hidden: [], leaveBuffer: 5,
                                             from: date(2026, 11, 2, 8), walkSeconds: walk)
        for expected in [date(2026, 11, 2, 9, 30), date(2026, 11, 2, 10, 20),   // class start, end
                         date(2026, 11, 2, 12, 45),                             // leave for 13:00 (10 min walk + 5)
                         date(2026, 11, 2, 13, 20),                             // prompt for 9:30 expires
                         date(2026, 11, 2, 23, 59),                             // a deadline
                         date(2026, 11, 3)] {                                   // midnight
            XCTAssertTrue(dates.contains(expected), "Missing \(expected)")
        }
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(dates.allSatisfy { $0 > date(2026, 11, 2, 8) })
        XCTAssertFalse(dates.contains(date(2026, 11, 2, 11)), "No polling: nothing changes at 11")
    }
}

final class WidgetActionTests: XCTestCase {

    override func setUp() { WidgetActions.clear() }
    override func tearDown() { WidgetActions.clear() }

    func testTapsAreQueuedAndReadBackAtOnce() {
        let id = UUID()
        WidgetActions.append(.taskDone(id))
        WidgetActions.append(.attendance(course: "ECE 30200", start: date(2026, 11, 2, 13), went: true))
        XCTAssertEqual(WidgetActions.completedTasks, [id])
        XCTAssertTrue(WidgetActions.markedAttendance.contains(
            WidgetModel.attendanceKey(course: "ECE 30200", start: date(2026, 11, 2, 13))))
    }

    @MainActor
    func testTheAppAppliesTheQueueAndClearsIt() {
        let store = BellStore(inMemory: true)
        let id = store.addTask(title: "HW", course: nil, due: date(2026, 11, 5), kind: .assignment)
        WidgetActions.append(.taskDone(id))
        WidgetActions.append(.attendance(course: "ECE 30200", start: date(2026, 11, 2, 13), went: false))

        store.applyWidgetActions()
        XCTAssertEqual(store.timetable.tasks.first?.isDone, true)
        XCTAssertEqual(store.attendance(forCourse: "ECE 30200").first?.state, .missed)
        XCTAssertTrue(WidgetActions.pending().isEmpty)
    }
}
