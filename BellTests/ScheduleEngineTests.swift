import XCTest
@testable import Bell

/// The scheduling logic is where a wrong answer is both most likely and least
/// visible — an off-by-one in day mapping shows up as a widget that's quietly
/// a day ahead, which you might not notice for a week.
final class ScheduleEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// Monday 0 … Sunday 6, matching the export's `dayNum`.
    private enum Day { static let mon = 0, tue = 1, wed = 2, thu = 3, fri = 4 }

    private func seconds(_ hour: Int, _ minute: Int = 0) -> Int {
        hour * 3600 + minute * 60
    }

    private func event(_ course: String,
                       _ room: String,
                       _ day: Int,
                       _ start: (Int, Int),
                       _ end: (Int, Int)) -> ClassEvent {
        ClassEvent(course: course,
                   room: room,
                   dayIndex: day,
                   startSecond: seconds(start.0, start.1),
                   endSecond: seconds(end.0, end.1),
                   weekIndex: 0)
    }

    /// A slice of the real schedule: Wednesday's back-to-back lecture and lab
    /// in different buildings, which is the case that exercises nearly every
    /// edge in the engine.
    private func wednesdaySchedule() -> Timetable {
        var table = Timetable()
        table.events = [
            event("ECE 36200", "WTHR 200", Day.wed, (7, 30), (8, 20)),
            event("ECE 36200L", "BHEE 162", Day.wed, (8, 30), (11, 20)),
            event("ECE 30200", "WALC 1018", Day.wed, (15, 30), (16, 20)),
        ]
        return table
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)!
    }

    // MARK: - Day mapping

    func testMondayIsIndexZero() {
        let engine = ScheduleEngine(timetable: .empty)
        // 2 November 2026 is a Monday.
        XCTAssertEqual(engine.mondayBasedIndex(for: date(2026, 11, 2)), 0)
        XCTAssertEqual(engine.mondayBasedIndex(for: date(2026, 11, 3)), 1)
        XCTAssertEqual(engine.mondayBasedIndex(for: date(2026, 11, 8)), 6, "Sunday is 6")
    }

    // MARK: - Occurrences

    func testOccurrencesOnlyOnMatchingDay() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())

        // 4 November 2026 is a Wednesday.
        XCTAssertEqual(engine.occurrences(on: date(2026, 11, 4)).count, 3)
        XCTAssertTrue(engine.occurrences(on: date(2026, 11, 3)).isEmpty, "Tuesday is clear")
    }

    func testOccurrencesAreSortedByStart() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let starts = engine.occurrences(on: date(2026, 11, 4)).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: - Status

    func testStatusTransitionsAcrossAClass() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let lecture = engine.occurrences(on: date(2026, 11, 4))[0]

        XCTAssertEqual(lecture.status(at: date(2026, 11, 4, 7, 0)), .upcoming)
        XCTAssertEqual(lecture.status(at: date(2026, 11, 4, 8, 0)), .inProgress)
        XCTAssertEqual(lecture.status(at: date(2026, 11, 4, 9, 0)), .finished)
    }

    func testProgressIsClampedAtBothEnds() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let lecture = engine.occurrences(on: date(2026, 11, 4))[0]

        XCTAssertEqual(lecture.progress(at: date(2026, 11, 4, 6, 0)), 0)
        XCTAssertEqual(lecture.progress(at: date(2026, 11, 4, 12, 0)), 1)
        XCTAssertEqual(lecture.progress(at: date(2026, 11, 4, 7, 55)), 0.5, accuracy: 0.01)
    }

    // MARK: - Next

    func testNextSkipsToTheFollowingWeekWhenTodayIsDone() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let afterEverything = date(2026, 11, 4, 20, 0)

        let next = engine.next(after: afterEverything)
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.event.course, "ECE 36200",
                       "Next Wednesday's first class, not today's")
        XCTAssertTrue(next!.start > afterEverything)
    }

    func testNextReturnsNilWhenNothingIsScheduled() {
        let engine = ScheduleEngine(timetable: .empty)
        XCTAssertNil(engine.next(after: date(2026, 11, 4)))
    }

    // MARK: - Gaps

    func testGapIgnoresShortBreaks() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())

        // 8:20 to 8:30 is ten minutes and shouldn't register as free time.
        let gaps = engine.gaps(on: date(2026, 11, 4), minimumMinutes: 30)
        XCTAssertEqual(gaps.count, 1, "Only the long afternoon gap qualifies")

        let minutes = gaps[0].end.timeIntervalSince(gaps[0].start) / 60
        XCTAssertEqual(minutes, 250, accuracy: 1, "11:20 to 15:30")
    }

    // MARK: - Transitions

    func testTenMinuteChangeAcrossCampusIsNotTight() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let today = engine.occurrences(on: date(2026, 11, 4))

        // WTHR to BHEE is roughly 340 m: about seven minutes with overhead,
        // inside the ten-minute gap.
        XCTAssertFalse(engine.isTightTransition(from: today[0], to: today[1]))
    }

    func testZeroGapAcrossBuildingsIsTight() {
        var table = Timetable()
        table.events = [
            event("A", "WTHR 200", Day.wed, (8, 0), (9, 0)),
            event("B", "EVER 500", Day.wed, (9, 0), (10, 0)),
        ]
        let engine = ScheduleEngine(timetable: table)
        let today = engine.occurrences(on: date(2026, 11, 4))

        XCTAssertTrue(engine.isTightTransition(from: today[0], to: today[1]),
                      "EVER is far enough that no walk fits a zero gap")
    }

    func testTransitionWithinOneBuildingIsNeverTight() {
        var table = Timetable()
        table.events = [
            event("A", "BHEE 162", Day.wed, (8, 0), (9, 0)),
            event("B", "BHEE 206", Day.wed, (9, 0), (10, 0)),
        ]
        let engine = ScheduleEngine(timetable: table)
        let today = engine.occurrences(on: date(2026, 11, 4))

        XCTAssertFalse(engine.isTightTransition(from: today[0], to: today[1]))
    }

    // MARK: - Term and breaks

    func testNothingIsScheduledOutsideTheTerm() {
        var table = wednesdaySchedule()
        table.termStart = date(2026, 8, 24)
        table.termEnd = date(2026, 12, 12)

        let engine = ScheduleEngine(timetable: table)
        XCTAssertTrue(engine.occurrences(on: date(2027, 1, 6)).isEmpty)
        XCTAssertFalse(engine.occurrences(on: date(2026, 11, 4)).isEmpty)
    }

    func testBreaksSuppressTheWholeDay() {
        var table = wednesdaySchedule()
        table.exceptions = [
            ScheduleException(name: "Break",
                              start: date(2026, 11, 4),
                              end: date(2026, 11, 4))
        ]
        let engine = ScheduleEngine(timetable: table)
        XCTAssertTrue(engine.occurrences(on: date(2026, 11, 4)).isEmpty)
    }

    /// The test above only asked at midnight, which is the one instant the
    /// old comparison got right. The widget asks at whatever time it is.
    func testBreaksSuppressTheWholeDayAtAnyHour() {
        var table = wednesdaySchedule()
        table.exceptions = [
            ScheduleException(name: "Break", start: date(2026, 11, 4), end: date(2026, 11, 4))
        ]
        let engine = ScheduleEngine(timetable: table)
        let midMorning = date(2026, 11, 4, 9, 0)

        XCTAssertTrue(engine.occurrences(on: midMorning).isEmpty)
        XCTAssertNotNil(engine.exception(on: midMorning))
        XCTAssertNil(engine.current(at: date(2026, 11, 4, 8, 45)), "No class in progress on a break")
        XCTAssertEqual(engine.next(after: date(2026, 11, 4, 6, 0))?.start, date(2026, 11, 11, 7, 30),
                       "Next class skips the break day entirely")
    }

    func testMultiDayBreakCoversItsLastDay() {
        var table = wednesdaySchedule()
        table.exceptions = [
            ScheduleException(name: "Thanksgiving", start: date(2026, 11, 2), end: date(2026, 11, 4))
        ]
        XCTAssertTrue(ScheduleEngine(timetable: table).occurrences(on: date(2026, 11, 4, 15, 0)).isEmpty)
    }

    func testTermIncludesItsWholeLastDay() {
        var table = wednesdaySchedule()
        table.termStart = date(2026, 8, 24)
        table.termEnd = date(2026, 11, 4)
        let engine = ScheduleEngine(timetable: table)

        XCTAssertEqual(engine.occurrences(on: date(2026, 11, 4, 12, 0)).count, 3)
        XCTAssertTrue(engine.occurrences(on: date(2026, 11, 5, 0, 1)).isEmpty)
    }

    // MARK: - Timeline

    func testRefreshPointsCoverEveryBoundaryAndAreOrdered() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let from = date(2026, 11, 4, 6, 0)
        let points = engine.refreshPoints(from: from, days: 0)

        XCTAssertEqual(points, points.sorted(), "Timeline entries must ascend")
        XCTAssertTrue(points.allSatisfy { $0 >= from }, "No entries in the past")

        let starts = engine.occurrences(on: from).map(\.start)
        for start in starts {
            XCTAssertTrue(points.contains(start), "Missing a class start boundary")
        }
    }

    func testRefreshPointsAreUnique() {
        let engine = ScheduleEngine(timetable: wednesdaySchedule())
        let points = engine.refreshPoints(from: date(2026, 11, 4, 6, 0), days: 2)
        XCTAssertEqual(points.count, Set(points).count)
    }
}
