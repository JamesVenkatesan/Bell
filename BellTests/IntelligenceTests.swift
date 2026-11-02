import XCTest
@testable import Bell

// Phase 5: daily intelligence. The numbers are tested here; the model only
// phrases them, and the grounding tests make sure it can't change them.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

private func seconds(_ h: Int, _ m: Int = 0) -> Int { h * 3600 + m * 60 }

/// Mon: 7:30 ECE 30100 (BHEE 170), 15:30 ECE 30200 (WALC 1018).
/// Tue: 9:30–11:20 ECE 30864L (BHEE 206). Wed: 15:30 ECE 30200.
private func timetable(tasks: [TaskEvent] = []) -> Timetable {
    var table = Timetable()
    table.events = [
        ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 0,
                   startSecond: seconds(7, 30), endSecond: seconds(8, 45), weekIndex: 0),
        ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 0,
                   startSecond: seconds(15, 30), endSecond: seconds(16, 20), weekIndex: 0),
        ClassEvent(course: "ECE 30864L", room: "BHEE 206", dayIndex: 1,
                   startSecond: seconds(9, 30), endSecond: seconds(11, 20), weekIndex: 0),
        ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 2,
                   startSecond: seconds(15, 30), endSecond: seconds(16, 20), weekIndex: 0),
    ]
    table.tasks = tasks
    table.termStart = date(2026, 10, 26)
    table.termEnd = date(2026, 12, 12)
    return table
}

private let monday = date(2026, 11, 2)
private let mondayMorning = date(2026, 11, 2, 9, 0)

// MARK: - Free time

final class FreeTimeTests: XCTestCase {

    func testFreeTimeIsTheDayMinusClassesWithinWakingHours() {
        let engine = ScheduleEngine(timetable: timetable())
        let free = FreeTime.intervals(engine: engine, from: monday, to: date(2026, 11, 3))
        XCTAssertEqual(free, [
            DateInterval(start: date(2026, 11, 2, 8, 45), end: date(2026, 11, 2, 15, 30)),
            DateInterval(start: date(2026, 11, 2, 16, 20), end: date(2026, 11, 2, 22, 0)),
        ])
    }

    func testOtherEventsAreNotFree() {
        let engine = ScheduleEngine(timetable: timetable())
        let lunch = ExternalEvent(id: "x", title: "Lunch", start: date(2026, 11, 2, 12), end: date(2026, 11, 2, 13),
                                  calendarTitle: "Home")
        let free = FreeTime.intervals(engine: engine, busy: [lunch], from: monday, to: date(2026, 11, 3))
        XCTAssertEqual(free.count, 3)
        // 8:45–15:30 and 16:20–22:00 is 12 h 25 min; lunch takes an hour.
        XCTAssertEqual(FreeTime.hours(free), (6.75 + 340.0 / 60) - 1, accuracy: 0.01)
    }

    func testSpansMidnightUsingEachDaysWakingHours() {
        let engine = ScheduleEngine(timetable: timetable())
        let free = FreeTime.intervals(engine: engine, from: date(2026, 11, 2, 20), to: date(2026, 11, 3, 10))
        XCTAssertEqual(free, [
            DateInterval(start: date(2026, 11, 2, 20), end: date(2026, 11, 2, 22)),
            DateInterval(start: date(2026, 11, 3, 8), end: date(2026, 11, 3, 9, 30)),
        ], "Nothing between 22:00 and 8:00 counts")
    }

    func testFragmentsShorterThanTheMinimumDontCount() {
        let engine = ScheduleEngine(timetable: timetable())
        XCTAssertTrue(FreeTime.intervals(engine: engine, from: date(2026, 11, 2, 15, 0),
                                         to: date(2026, 11, 2, 15, 25)).isEmpty)
    }
}

// MARK: - Deadline pressure

final class DeadlinePressureTests: XCTestCase {

    func testLevels() {
        XCTAssertEqual(DeadlinePressure.level(effort: 3, free: 12), .comfortable)
        XCTAssertEqual(DeadlinePressure.level(effort: 3, free: 6), .tight)
        XCTAssertEqual(DeadlinePressure.level(effort: 6, free: 6), .critical)
        XCTAssertEqual(DeadlinePressure.level(effort: 3, free: 0), .critical)
        XCTAssertEqual(DeadlinePressure.level(effort: 0, free: 0), .comfortable)
    }

    func testAnExamThisAfternoonIsCritical() {
        let exam = TaskEvent(title: "Midterm", course: "ECE 30200", due: date(2026, 11, 2, 15, 0), kind: .exam)
        let engine = ScheduleEngine(timetable: timetable(tasks: [exam]))
        let result = DeadlinePressure.evaluate(tasks: [exam], engine: engine, now: mondayMorning)
        XCTAssertEqual(result.first?.freeHours ?? 0, 6, accuracy: 0.01, "9:00 to 15:00, nothing scheduled")
        XCTAssertEqual(result.first?.level, .critical, "Six hours of revision in six free hours")
    }

    func testMostPressingComesFirstAndMeetingsAreLeftOut() {
        let tasks = [
            TaskEvent(title: "Later", due: date(2026, 11, 20), kind: .assignment),
            TaskEvent(title: "Soon", due: date(2026, 11, 2, 14), kind: .exam),
            TaskEvent(title: "Interview", due: date(2026, 11, 3, 10), kind: .meeting),
            TaskEvent(title: "Gone", due: date(2026, 11, 1), kind: .quiz),
        ]
        let engine = ScheduleEngine(timetable: timetable(tasks: tasks))
        let titles = DeadlinePressure.evaluate(tasks: tasks, engine: engine, now: mondayMorning).map(\.task.title)
        XCTAssertEqual(titles, ["Gone", "Soon", "Later"])
    }

    func testDoneWorkIsIgnored() {
        let done = TaskEvent(title: "Done", due: date(2026, 11, 3), kind: .exam, isDone: true)
        XCTAssertTrue(DeadlinePressure.evaluate(tasks: [done], engine: ScheduleEngine(timetable: timetable()),
                                                now: mondayMorning).isEmpty)
    }
}

// MARK: - Gap suggestions

final class GapAdvisorTests: XCTestCase {

    private func pressure(_ title: String, due: Date, level: DeadlinePressure.Level) -> DeadlinePressure {
        DeadlinePressure(task: TaskEvent(title: title, due: due, kind: .assignment),
                         freeHours: 5, effortHours: 3, level: level)
    }

    func testTheMostPressingTaskGetsTheFirstGoodGap() {
        let gaps = [DateInterval(start: date(2026, 11, 2, 9), end: date(2026, 11, 2, 10))]
        let result = GapAdvisor.suggest(gaps: gaps, pressures: [pressure("Lab report", due: date(2026, 11, 3), level: .tight)])
        XCTAssertEqual(result.first?.text, "Good for Lab report")
    }

    func testATaskIsntSuggestedAfterItsDue() {
        let gaps = [DateInterval(start: date(2026, 11, 2, 16), end: date(2026, 11, 2, 18))]
        let result = GapAdvisor.suggest(gaps: gaps, pressures: [pressure("Quiz prep", due: date(2026, 11, 2, 15), level: .critical)])
        XCTAssertTrue(result.isEmpty)
    }

    func testEachTaskIsSuggestedOnce() {
        let gaps = [DateInterval(start: date(2026, 11, 2, 9), end: date(2026, 11, 2, 10)),
                    DateInterval(start: date(2026, 11, 2, 14), end: date(2026, 11, 2, 15))]
        let result = GapAdvisor.suggest(gaps: gaps, pressures: [pressure("Lab report", due: date(2026, 11, 3), level: .tight)])
        XCTAssertEqual(result.count, 1)
    }

    func testLunchWhenNothingIsPressing() {
        let gaps = [DateInterval(start: date(2026, 11, 2, 11, 30), end: date(2026, 11, 2, 12, 30))]
        XCTAssertEqual(GapAdvisor.suggest(gaps: gaps, pressures: []).first?.text, "Time for lunch")
    }

    /// Something comfortable doesn't take a 45-minute gap at lunchtime.
    func testComfortableWorkNeedsAnHour() {
        let gaps = [DateInterval(start: date(2026, 11, 2, 11, 45), end: date(2026, 11, 2, 12, 35))]
        let result = GapAdvisor.suggest(gaps: gaps, pressures: [pressure("Reading", due: date(2026, 11, 9), level: .comfortable)])
        XCTAssertEqual(result.first?.text, "Time for lunch")
    }
}

// MARK: - Wake-up

final class WakePlanTests: XCTestCase {

    private let engine = ScheduleEngine(timetable: timetable())

    func testWakeIsClassMinusWalkBufferAndRoutine() throws {
        let plan = try XCTUnwrap(WakePlan.make(day: monday, engine: engine, walkMinutes: 10, walkSource: .home,
                                               routineMinutes: 45, bufferMinutes: 5))
        XCTAssertEqual(plan.firstClass.event.course, "ECE 30100")
        XCTAssertEqual(plan.leaveAt, date(2026, 11, 2, 7, 15))
        XCTAssertEqual(plan.wakeAt, date(2026, 11, 2, 6, 30))
    }

    /// Down, never up: rounding up would take minutes the user planned on.
    func testAlarmRoundsDownToFiveMinutes() throws {
        let plan = try XCTUnwrap(WakePlan.make(day: monday, engine: engine, walkMinutes: 12, walkSource: .home,
                                               routineMinutes: 45, bufferMinutes: 5))
        XCTAssertEqual(plan.leaveAt, date(2026, 11, 2, 7, 13))
        XCTAssertEqual(plan.wakeAt, date(2026, 11, 2, 6, 25))
    }

    func testUnknownWalkIsAStatedGuess() throws {
        let plan = try XCTUnwrap(WakePlan.make(day: monday, engine: engine, walkMinutes: nil, walkSource: .home,
                                               routineMinutes: 45, bufferMinutes: 5))
        XCTAssertEqual(plan.walkSource, .estimate, "Never claim it came from home when it didn't")
        XCTAssertEqual(plan.walkMinutes, WakePlan.defaultWalkMinutes)
    }

    func testHiddenFirstClassIsSkipped() throws {
        let plan = try XCTUnwrap(WakePlan.make(day: monday, engine: engine, hidden: ["ECE 30100"], walkMinutes: 10,
                                               walkSource: .home, routineMinutes: 45, bufferMinutes: 5))
        XCTAssertEqual(plan.firstClass.event.course, "ECE 30200")
    }

    func testNoClassesNoPlan() {
        XCTAssertNil(WakePlan.make(day: date(2026, 11, 7), engine: engine, walkMinutes: 10, walkSource: .home,
                                   routineMinutes: 45, bufferMinutes: 5))
    }
}

// MARK: - Brief

final class BriefTests: XCTestCase {

    private func facts(tasks: [TaskEvent] = [], busy: [ExternalEvent] = [], day: Date = monday,
                       now: Date = date(2026, 11, 2, 6, 0), wake: WakePlan? = nil) -> BriefFacts {
        BriefFacts.build(day: day, engine: ScheduleEngine(timetable: timetable(tasks: tasks)), busy: busy,
                         hidden: [], wake: wake, now: now, walkSeconds: { a, b in a != b ? 600 : 0 })
    }

    func testTemplateStatesTheShapeOfTheDay() {
        let text = BriefWriter.template(facts(), now: date(2026, 11, 2, 6, 0))
        XCTAssertTrue(text.hasPrefix("Two classes today, starting with ECE 30100 at 7:30 AM in BHEE 170."), text)
        XCTAssertTrue(text.contains("free from 8:45 AM to 3:30 PM"), text)
        XCTAssertTrue(text.hasSuffix("Done at 4:20 PM."), text)
    }

    func testTemplateNamesWhatTheGapIsFor() {
        let report = TaskEvent(title: "Lab report", course: "ECE 30864L", due: date(2026, 11, 3, 9), kind: .assignment)
        let text = BriefWriter.template(facts(tasks: [report]), now: date(2026, 11, 2, 6, 0))
        XCTAssertTrue(text.contains("which is the time for Lab report"), text)
    }

    func testEveningSaysTomorrow() {
        let text = BriefWriter.template(facts(day: date(2026, 11, 3), now: date(2026, 11, 2, 20)),
                                        now: date(2026, 11, 2, 20))
        XCTAssertTrue(text.hasPrefix("One class tomorrow"), text)
    }

    func testBreakDay() {
        var table = timetable()
        table.exceptions = [ScheduleException(name: "Fall break", start: monday, end: monday)]
        let f = BriefFacts.build(day: monday, engine: ScheduleEngine(timetable: table), busy: [], hidden: [],
                                 wake: nil, now: monday)
        XCTAssertEqual(BriefWriter.template(f, now: monday), "Fall break: no classes today.")
    }

    func testClashIsMentioned() {
        let clash = ExternalEvent(id: "i", title: "Interview", start: date(2026, 11, 2, 15), end: date(2026, 11, 2, 16),
                                  calendarTitle: "Work")
        let text = BriefWriter.template(facts(busy: [clash]), now: date(2026, 11, 2, 6))
        XCTAssertTrue(text.contains("Interview at 3:00 PM clashes with ECE 30200."), text)
    }

    /// The template is the fallback for an ungrounded model. It has to pass
    /// its own check, every time.
    func testTheTemplateIsAlwaysGrounded() {
        let wake = WakePlan.make(day: monday, engine: ScheduleEngine(timetable: timetable()), walkMinutes: 10,
                                 walkSource: .home, routineMinutes: 45, bufferMinutes: 5)
        let report = TaskEvent(title: "Lab report", course: "ECE 30864L", due: date(2026, 11, 2, 23, 59), kind: .assignment)
        for f in [facts(), facts(tasks: [report], wake: wake), facts(day: date(2026, 11, 3))] {
            let text = BriefWriter.template(f, now: monday)
            XCTAssertTrue(BriefWriter.isGrounded(text, in: f), text)
        }
    }

    func testAnInventedTimeIsRejected() {
        XCTAssertFalse(BriefWriter.isGrounded("Your lab starts at 2:30.", in: facts()))
    }

    /// Rooms have the shape of course codes. Mentioning the real room must
    /// pass; a room that isn't in the day must not.
    func testRoomsAreKnownButOnlyTheRightOnes() {
        XCTAssertTrue(BriefWriter.isGrounded("First up is BHEE 170 at 7:30.", in: facts()))
        XCTAssertFalse(BriefWriter.isGrounded("First up is LWSN 1142 at 7:30.", in: facts()))
    }

    /// The model's real output at 2:30am, with every time correct.
    func testPastTenseAboutAFutureMorningIsRejected() {
        let wake = WakePlan.make(day: monday, engine: ScheduleEngine(timetable: timetable()), walkMinutes: 10,
                                 walkSource: .home, routineMinutes: 45, bufferMinutes: 5)
        let f = facts(wake: wake)
        let early = date(2026, 11, 2, 2, 30)
        XCTAssertFalse(BriefWriter.keepsTense("You were up by 6:30 AM and out by 7:15 AM.", facts: f, now: early))
        XCTAssertTrue(BriefWriter.keepsTense("You'll be up by 6:30 AM and out by 7:15 AM.", facts: f, now: early))
        XCTAssertTrue(BriefWriter.keepsTense("You were in ECE 30100 at 7:30 AM.", facts: f, now: date(2026, 11, 2, 12)),
                      "Past tense is right once the morning has happened")
    }

    func testAnInventedCourseIsRejected() {
        XCTAssertFalse(BriefWriter.isGrounded("Don't forget MA 26100 at 7:30.", in: facts()))
    }

    func testTeachingCoursesMatchWithoutTheirPrefix() {
        var table = timetable()
        table.events.append(ClassEvent(course: "TA: ECE 36800", room: "BHEE 206", dayIndex: 0,
                                       startSecond: seconds(12, 30), endSecond: seconds(14, 30), weekIndex: 0))
        let f = BriefFacts.build(day: monday, engine: ScheduleEngine(timetable: table), busy: [], hidden: [],
                                 wake: nil, now: monday)
        XCTAssertTrue(BriefWriter.isGrounded("You teach ECE 36800 at 12:30.", in: f))
    }
}

@MainActor
final class BriefingTests: XCTestCase {

    private let engine = ScheduleEngine(timetable: timetable())

    func testBeforeTheLastClassTheBriefIsAboutToday() {
        XCTAssertEqual(Briefing.subjectDay(engine: engine, hidden: [], now: date(2026, 11, 2, 15)), monday)
    }

    func testAfterTheLastClassItsAboutTomorrow() {
        XCTAssertEqual(Briefing.subjectDay(engine: engine, hidden: [], now: date(2026, 11, 2, 16, 30)),
                       date(2026, 11, 3))
    }

    func testOnAClassFreeDayItTurnsOverAtSix() {
        XCTAssertEqual(Briefing.subjectDay(engine: engine, hidden: [], now: date(2026, 11, 7, 17)), date(2026, 11, 7))
        XCTAssertEqual(Briefing.subjectDay(engine: engine, hidden: [], now: date(2026, 11, 7, 19)), date(2026, 11, 8))
    }

    func testNotificationsForClassDaysPlusTheReview() {
        let saved = Preferences.briefNotificationsEnabled
        defer { Preferences.briefNotificationsEnabled = saved }
        Preferences.briefNotificationsEnabled = true

        let requests = Briefing.notificationRequests(engine: engine, busy: [], hidden: [], now: date(2026, 11, 1, 20))
        let briefs = requests.filter { $0.identifier.hasPrefix("brief-") }
        XCTAssertEqual(briefs.count, 3, "Sun to Sat: Mon, Tue and Wed have classes")
        XCTAssertEqual(requests.filter { $0.identifier.hasPrefix("review-") }.count, 1)

        Preferences.briefNotificationsEnabled = false
        XCTAssertTrue(Briefing.notificationRequests(engine: engine, busy: [], hidden: [], now: monday).isEmpty)
    }
}

// MARK: - Weekly review

final class WeeklyReviewTests: XCTestCase {

    func testCountsTheWeek() {
        let tasks = [
            TaskEvent(title: "HW 5", due: date(2026, 11, 4), kind: .assignment, isDone: true),
            TaskEvent(title: "Lab 6", due: date(2026, 11, 6), kind: .assignment),
            TaskEvent(title: "Midterm", due: date(2026, 11, 10, 19), kind: .exam),
        ]
        var table = timetable(tasks: tasks)
        let engine0 = ScheduleEngine(timetable: table)
        table.cancelled = [engine0.occurrences(on: date(2026, 11, 4))[0].key]
        let engine = ScheduleEngine(timetable: table)

        let records: [(course: String, entry: AttendanceEntry)] = [
            ("ECE 30100", AttendanceEntry(date: date(2026, 11, 2, 7, 30), state: .attended, wasAutomatic: true)),
            ("ECE 30200", AttendanceEntry(date: date(2026, 11, 2, 15, 30), state: .missed, wasAutomatic: false)),
        ]
        let review = WeeklyReview.build(weekStart: monday, engine: engine, attendance: records)

        XCTAssertEqual(review.classesHeld, 3, "Wednesday's lecture was cancelled")
        XCTAssertEqual(review.cancelled, 1)
        XCTAssertEqual(review.attended, 1)
        XCTAssertEqual(review.missed, 1)
        XCTAssertEqual(review.unrecorded, 1)
        XCTAssertEqual(review.minutesInClass, 75 + 50 + 110)
        XCTAssertEqual(review.busiestDay?.day, date(2026, 11, 2))
        XCTAssertEqual(review.tasksDone.map(\.title), ["HW 5"])
        XCTAssertEqual(review.tasksSlipped.map(\.title), ["Lab 6"])
        XCTAssertEqual(review.dueNextWeek.map(\.title), ["Midterm"])
        XCTAssertEqual(review.nextWeekFirst?.start, date(2026, 11, 9, 7, 30))
    }

    /// Stated, not scolded.
    func testSummaryReadsAsPlanningNotJudgement() {
        let records: [(course: String, entry: AttendanceEntry)] = [
            ("ECE 30200", AttendanceEntry(date: date(2026, 11, 2, 15, 30), state: .missed, wasAutomatic: false)),
        ]
        let summary = WeeklyReview.build(weekStart: monday, engine: ScheduleEngine(timetable: timetable()),
                                         attendance: records).summary
        XCTAssertTrue(summary.hasPrefix("4 classes this week, 4.8 hours in all, and you marked 1 as missed."), summary)
        XCTAssertTrue(summary.contains("Next week has 4 classes, starting Monday with ECE 30100 at 7:30 AM."), summary)
    }

    func testMondayOfTheWeek() {
        let engine = ScheduleEngine(timetable: timetable())
        XCTAssertEqual(WeeklyReview.monday(of: date(2026, 11, 8, 18), engine: engine), monday, "Sunday belongs to the week before")
        XCTAssertEqual(WeeklyReview.monday(of: date(2026, 11, 9, 1), engine: engine), date(2026, 11, 9))
    }
}

// MARK: - Asking

final class AskTests: XCTestCase {

    private let engine = ScheduleEngine(timetable: timetable(tasks: [
        TaskEvent(title: "Lab report", course: "ECE 30864L", due: date(2026, 11, 4, 23, 59), kind: .assignment),
    ]))

    func testQuestionsAndInstructionsAreToldApart() {
        XCTAssertEqual(AskIntent.classify("when's my next class"), .question)
        XCTAssertEqual(AskIntent.classify("Am I free at 3 tomorrow"), .question)
        XCTAssertEqual(AskIntent.classify("quiz for 302 friday?"), .question)
        XCTAssertEqual(AskIntent.classify("Add a quiz for 302 on Friday at 10am"), .instruction)
        XCTAssertEqual(AskIntent.classify("Dentist Thursday 2pm"), .instruction)
    }

    func testNextClass() {
        XCTAssertEqual(ScheduleQA.answer("what's my next class?", engine: engine, now: mondayMorning),
                       "ECE 30200 at 3:30 PM today in WALC 1018.")
    }

    func testFreeAtATimeTheClassOccupies() {
        XCTAssertEqual(ScheduleQA.answer("am I free at 10 tomorrow?", engine: engine, now: mondayMorning),
                       "No: ECE 30864L runs 9:30 AM–11:20 AM in BHEE 206.")
    }

    func testFreeAtATimeThatsClear() {
        XCTAssertEqual(ScheduleQA.answer("am I free at 3 tomorrow?", engine: engine, now: mondayMorning),
                       "Yes, nothing else is on after that tomorrow.")
    }

    func testFreeAcrossADay() {
        XCTAssertEqual(ScheduleQA.answer("when am I free tomorrow?", engine: engine, now: mondayMorning),
                       "Free tomorrow: 8:00 AM–9:30 AM and 11:20 AM–10:00 PM.")
    }

    func testWhatsDue() {
        XCTAssertEqual(ScheduleQA.answer("what's due this week?", engine: engine, now: mondayMorning),
                       "Lab report on Wednesday at 11:59 PM.")
    }

    func testWhereIsACourseBySpokenNumber() {
        XCTAssertEqual(ScheduleQA.answer("where is ECE 302?", engine: engine, now: mondayMorning),
                       "ECE 30200 next meets today at 3:30 PM in WALC 1018.")
    }

    func testWhenDoIFinish() {
        XCTAssertEqual(ScheduleQA.answer("when do I finish today?", engine: engine, now: mondayMorning),
                       "Your last class today is ECE 30200, done at 4:20 PM.")
    }

    func testUnrecognisedGoesToTheModel() {
        XCTAssertNil(ScheduleQA.answer("should I drop a class?", engine: engine, now: mondayMorning))
    }

    func testModelAnswersAreGroundedAgainstTheSchedule() {
        XCTAssertTrue(ScheduleQA.isGrounded("Your lab is at 9:30am.", engine: engine, busy: [], now: mondayMorning))
        XCTAssertFalse(ScheduleQA.isGrounded("Your lab is at 9:45.", engine: engine, busy: [], now: mondayMorning))
        XCTAssertFalse(ScheduleQA.isGrounded("CS 18000 is at 9:30.", engine: engine, busy: [], now: mondayMorning))
        XCTAssertTrue(ScheduleQA.isGrounded("It's in BHEE 206 at 9:30.", engine: engine, busy: [], now: mondayMorning))
    }

    func testChatUsesTheExactAnswerWhenThereIsOne() async {
        let reply = await ScheduleChat.reply(to: "when do I finish today?", engine: engine, busy: [],
                                             hidden: [], now: mondayMorning)
        XCTAssertEqual(reply, .init(text: "Your last class today is ECE 30200, done at 4:20 PM.", byModel: false))
    }
}

// MARK: - Telling

@MainActor
final class TellTests: XCTestCase {

    private func session() -> AppSession {
        let session = AppSession()
        session.inbox.usesModel = false
        return session
    }

    func testAnInstructionWithADateIsAddedAsTheUsers() async throws {
        let store = BellStore(inMemory: true)
        let result = await session().tell("Quiz for ECE 302 on March 5, 2027 at 10:00 AM", store: store)
        guard case .added = result else { return XCTFail("\(result)") }
        let task = try XCTUnwrap(store.timetable.tasks.first)
        XCTAssertFalse(task.isAutomatic)
    }

    /// The user typed it, so even when it contains "exam" it isn't Bell's
    /// automatic add and mustn't carry that badge.
    func testTypedKeywordsAreStillTheUsers() async throws {
        let store = BellStore(inMemory: true)
        _ = await session().tell("Exam review on March 5, 2027 at 10:00 AM", store: store)
        XCTAssertEqual(store.timetable.tasks.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.timetable.tasks.first).isAutomatic)
    }

    func testWithoutADateItGoesToTheInbox() async {
        let store = BellStore(inMemory: true)
        let result = await session().tell("Buy a new lab notebook", store: store)
        XCTAssertEqual(result, .needsDetails)
        XCTAssertEqual(store.inbox.first?.state, .pending)
    }
}
