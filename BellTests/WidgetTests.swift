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

// MARK: - Bell Max

/// Mon: 8:00, 9:30, 13:00, 15:30.
private func fourClasses(tasks: [TaskEvent] = []) -> Timetable {
    var table = timetable(tasks: tasks)
    table.events += [
        ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 0,
                   startSecond: 8 * 3600, endSecond: 8 * 3600 + 2700, weekIndex: 0),
        ClassEvent(course: "ECE 20869", room: "UC 114", dayIndex: 0,
                   startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
    ]
    return table
}

private func task(_ title: String, _ due: Date, _ kind: TaskEvent.Kind = .assignment,
                  allDay: Bool = false, done: Bool = false) -> TaskEvent {
    TaskEvent(title: title, course: "ECE 30200", due: due, kind: kind, isDone: done, isAllDay: allDay, fromNotion: true)
}

final class MaxLayoutTests: XCTestCase {

    /// Before the first class: the bell leads; the rest of the day is the
    /// list, in time order, without the class the hero already names.
    func testMorningTheBellLeadsAndTheListIsTheRest() {
        let layout = MaxLayout.make(model(fourClasses(), at: date(2026, 11, 2, 7, 30)))
        guard case .bell(let bell) = layout.hero else { return XCTFail("Expected the bell") }
        XCTAssertEqual(bell.occurrence.event.course, "ECE 30100")
        XCTAssertEqual(layout.rows.map(\.time), [date(2026, 11, 2, 9, 30), date(2026, 11, 2, 13), date(2026, 11, 2, 15, 30)])
        XCTAssertNil(layout.footer)
    }

    /// Classes, deadlines and today's exam are one list in time order, not
    /// three sections.
    func testOneMergedListInTimeOrder() {
        let table = fourClasses(tasks: [task("HW 9", date(2026, 11, 2, 12)),
                                        task("Reading", date(2026, 11, 2), .other, allDay: true),
                                        task("Quiz", date(2026, 11, 2, 14, 30), .quiz)])
        let layout = MaxLayout.make(model(table, at: date(2026, 11, 2, 9)))
        let titles = layout.rows.map { row -> String in
            switch row.item {
            case .meeting(let o): o.event.course
            case .deadline(let t), .exam(let t): t.title
            }
        }
        XCTAssertEqual(Array(titles.prefix(3)), ["HW 9", "ECE 30200", "Quiz"], "9:30 is the hero; then noon, 1pm, 2:30")
        XCTAssertEqual(layout.rows.count, MaxLayout.rowLimit)
        XCTAssertEqual(layout.more, 1, "The all-day reading, sorted last, didn't fit")
    }

    /// After the last class the next deadline takes the hero, and finished
    /// classes fill the spare rows, marked past.
    func testAfterClassesTheNextDeadlineLeads() {
        let table = timetable(tasks: [task("HW 9", date(2026, 11, 2, 23, 59))])
        let layout = MaxLayout.make(model(table, at: date(2026, 11, 2, 15)))
        guard case .due(let t) = layout.hero else { return XCTFail("Expected a deadline hero") }
        XCTAssertEqual(t.title, "HW 9")
        XCTAssertTrue(layout.rows.allSatisfy(\.isPast))
        XCTAssertEqual(layout.rows.count, 2)
    }

    func testAnExamTodayOrTomorrowTakesTheHero() {
        let tomorrow = MaxLayout.make(model(timetable(tasks: [task("Final", date(2026, 11, 3, 8), .exam)]),
                                            at: date(2026, 11, 2, 9)))
        guard case .exam(let exam) = tomorrow.hero else { return XCTFail("Expected the exam") }
        XCTAssertEqual(exam.daysOut, 1)
        XCTAssertNil(tomorrow.footer)
    }

    func testAnExamLaterInTheWeekIsTheFooter() {
        let layout = MaxLayout.make(model(timetable(tasks: [task("Midterm", date(2026, 11, 5, 19), .exam)]),
                                          at: date(2026, 11, 2, 9)))
        guard case .bell = layout.hero else { return XCTFail("The day still leads") }
        if case .exam(let e)? = layout.footer { XCTAssertEqual(e.daysOut, 3) } else { XCTFail("Expected the exam footer") }
    }

    func testAMissedDeadlineIsFlagged() {
        let layout = MaxLayout.make(model(timetable(tasks: [task("Lab", date(2026, 11, 2, 9)), task("HW", date(2026, 11, 2, 22))]),
                                          at: date(2026, 11, 2, 10)))
        XCTAssertEqual(layout.rows.first { $0.isMissed }.map(\.time), date(2026, 11, 2, 9))
    }

    func testQuietDays() {
        XCTAssertEqual(MaxLayout.make(model(timetable(), at: date(2026, 11, 7, 10))).hero, .quiet(.noClasses))
        XCTAssertEqual(MaxLayout.make(model(timetable(), at: date(2026, 11, 2, 18))).hero,
                       .quiet(.done(at: date(2026, 11, 2, 14))))
        let onBreak = timetable(exceptions: [ScheduleException(name: "Fall break", start: date(2026, 11, 2), end: date(2026, 11, 2))])
        XCTAssertEqual(MaxLayout.make(model(onBreak, at: date(2026, 11, 2, 10))).hero, .quiet(.away("Fall break")))
    }

    /// A quiet day looks ahead: the next class and the week's deadlines,
    /// labelled with their days, instead of an empty list.
    func testAQuietDayShowsWhatsComingUp() {
        let table = timetable(tasks: [task("HW 10", date(2026, 11, 10, 23, 59))])
        let layout = MaxLayout.make(model(table, at: date(2026, 11, 7, 10)))
        XCTAssertEqual(layout.listTitle, "Coming up")
        XCTAssertEqual(layout.rows.map(\.time), [date(2026, 11, 9, 9, 30), date(2026, 11, 10, 23, 59)])
        XCTAssertTrue(layout.rows.allSatisfy(\.isLater))
        // On a class day the list is today's, untitled.
        XCTAssertNil(MaxLayout.make(model(table, at: date(2026, 11, 2, 8))).listTitle)
    }

    func testStaleNotionIsTheFooterWhenNothingElseIs() {
        var m = model(timetable(), at: date(2026, 11, 2, 9))
        m.notionSyncedAt = date(2026, 11, 2, 1)
        XCTAssertEqual(MaxLayout.make(m).footer, .stale(date(2026, 11, 2, 1)))
    }
}

final class DueTodayTests: XCTestCase {

    func testDueTodayOrderingAndFiltering() {
        let tasks = [
            task("All day", date(2026, 11, 2), allDay: true),
            task("Evening", date(2026, 11, 2, 21)),
            task("Missed this morning", date(2026, 11, 2, 9)),
            task("Done", date(2026, 11, 2, 12), done: true),
            task("Tomorrow", date(2026, 11, 3, 9)),
            task("Exam tonight", date(2026, 11, 2, 19), .exam),
        ]
        let m = model(timetable(tasks: tasks), at: date(2026, 11, 2, 14))
        XCTAssertEqual(m.dueToday.map(\.title), ["Missed this morning", "Evening", "All day"],
                       "Timed first, past ones kept, the warned exam left to its own block")
        XCTAssertEqual(m.exam?.task.title, "Exam tonight")
    }

    func testExamWindow() {
        let past = task("Old exam", date(2026, 11, 1, 19), .exam)
        let sitting = task("Sitting it now", date(2026, 11, 2, 13), .exam)
        let m = model(timetable(tasks: [past, sitting]), at: date(2026, 11, 2, 14))
        XCTAssertEqual(m.exam?.task.title, "Sitting it now", "Two hours from its start it still counts")
        XCTAssertEqual(m.exam?.daysOut, 0)
        XCTAssertNil(model(timetable(tasks: [sitting]), at: date(2026, 11, 2, 15, 30)).exam)
        let allDay = task("Take-home", date(2026, 11, 2), .exam, allDay: true)
        XCTAssertNotNil(model(timetable(tasks: [allDay]), at: date(2026, 11, 2, 22)).exam, "All day lasts all day")
    }

    func testStaleNotionIsFlagged() {
        var m = model(timetable(), at: date(2026, 11, 2, 14))
        XCTAssertFalse(m.notionIsStale, "Not connected: nothing to flag")
        m.notionSyncedAt = date(2026, 11, 2, 8)
        XCTAssertTrue(m.notionIsStale)
        m.notionSyncedAt = date(2026, 11, 2, 12)
        XCTAssertFalse(m.notionIsStale)
    }
}
