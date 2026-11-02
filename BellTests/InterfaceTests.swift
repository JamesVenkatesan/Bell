import XCTest
import SwiftUI
@testable import Bell

// Phase 2 moved the interface's arithmetic out of view bodies so it could be
// tested here. A view that draws a class in the wrong place, hides the class
// that's next, or names a time outside the grid is a logic bug wearing a UI;
// these catch it before it reaches a screen.

// MARK: - Fixtures

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

/// 4 November 2026 is a Wednesday.
private func occurrence(_ course: String, _ room: String,
                        _ start: (Int, Int), _ end: (Int, Int),
                        on day: (Int, Int, Int) = (2026, 11, 4)) -> ScheduleEngine.Occurrence {
    let event = ClassEvent(course: course, room: room, dayIndex: 2,
                           startSecond: start.0 * 3600 + start.1 * 60,
                           endSecond: end.0 * 3600 + end.1 * 60,
                           weekIndex: 0)
    return ScheduleEngine.Occurrence(event: event,
                                     start: date(day.0, day.1, day.2, start.0, start.1),
                                     end: date(day.0, day.1, day.2, end.0, end.1))
}

/// Walk times that don't depend on real campus coordinates: different
/// buildings are always eight minutes apart.
private func eightMinuteWalk(_ a: String?, _ b: String?) -> TimeInterval {
    guard let a, let b, a != b else { return 0 }
    return 8 * 60
}

// MARK: - Day layout

final class DayLayoutTests: XCTestCase {

    private var wednesday: [ScheduleEngine.Occurrence] {
        [
            occurrence("ECE 36200", "WTHR 200", (7, 30), (8, 20)),
            occurrence("ECE 36200L", "BHEE 162", (8, 30), (11, 20)),
            occurrence("ECE 30200", "WALC 1018", (15, 30), (16, 20)),
        ]
    }

    func testWindowSnapsOutwardToWholeHours() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.windowStart, date(2026, 11, 4, 7, 0), "7:30 start rounds down to 7:00")
        XCTAssertEqual(layout.windowEnd, date(2026, 11, 4, 17, 0), "16:20 end rounds up to 17:00")
    }

    func testWindowOnAnExactHourDoesNotGrowAnExtraHour() {
        let layout = DayLayout(occurrences: [occurrence("A", "X 1", (9, 0), (10, 0))],
                               walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.windowStart, date(2026, 11, 4, 9, 0))
        XCTAssertEqual(layout.windowEnd, date(2026, 11, 4, 10, 0))
    }

    /// The point of the view: length is proportional to time.
    func testBlocksAreDrawnAtTrueScale() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        let lecture = layout.blocks[0], lab = layout.blocks[1]

        XCTAssertEqual(lecture.y, 30 * layout.pointsPerMinute, accuracy: 0.001)
        XCTAssertEqual(lab.height / lecture.height, 170.0 / 50.0, accuracy: 0.001,
                       "A 170-minute lab is 3.4 times as tall as a 50-minute lecture")
        XCTAssertEqual(layout.height, 600 * layout.pointsPerMinute, accuracy: 0.001)
    }

    func testScaleRisesSoTheShortestClassIsLegible() {
        // Thirty minutes needs ~1.9 points a minute: above the base, under the cap.
        let short = occurrence("A", "X 1", (9, 0), (9, 30))
        let layout = DayLayout(occurrences: [short], basePointsPerMinute: 1, walkSeconds: eightMinuteWalk)
        XCTAssertGreaterThanOrEqual(layout.blocks[0].height, DayLayout.minimumBlockHeight - 0.001)
    }

    func testScaleRiseIsCapped() {
        let tiny = occurrence("A", "X 1", (9, 0), (9, 5))
        let layout = DayLayout(occurrences: [tiny], walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.pointsPerMinute, DayLayout.maximumPointsPerMinute)
    }

    func testGapsAreClassifiedByWhatTheyMean() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.gaps.count, 2)

        XCTAssertEqual(layout.gaps[0].kind, .change, "10 minutes with an 8 minute walk fits")
        XCTAssertEqual(layout.gaps[0].walkMinutes, 8)
        XCTAssertEqual(layout.gaps[1].kind, .free)
        XCTAssertEqual(layout.gaps[1].minutes, 250)
    }

    func testGapShorterThanTheWalkIsTight() {
        let layout = DayLayout(occurrences: [
            occurrence("A", "WTHR 200", (8, 0), (9, 0)),
            occurrence("B", "EVER 500", (9, 5), (10, 0)),
        ], walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.gaps.first?.kind, .tight)
    }

    func testBackToBackInOneBuildingHasNoGap() {
        let layout = DayLayout(occurrences: [
            occurrence("A", "BHEE 162", (8, 0), (9, 0)),
            occurrence("B", "BHEE 206", (9, 0), (10, 0)),
        ], walkSeconds: eightMinuteWalk)
        XCTAssertTrue(layout.gaps.isEmpty)
    }

    /// A long class that swallows a short one must not produce a phantom gap
    /// measured from the short one's end.
    func testOverlapDoesNotInventFreeTime() {
        let layout = DayLayout(occurrences: [
            occurrence("Long", "X 1", (9, 0), (12, 0)),
            occurrence("Short", "X 2", (9, 30), (10, 0)),
            occurrence("After", "X 3", (12, 0), (13, 0)),
        ], walkSeconds: { _, _ in 0 })
        XCTAssertTrue(layout.gaps.isEmpty, "Nothing is free between 10:00 and 12:00")
    }

    func testClashingClassesSitSideBySide() {
        let layout = DayLayout(occurrences: [
            occurrence("A", "X 1", (9, 0), (10, 0)),
            occurrence("B", "X 2", (9, 30), (10, 30)),
            occurrence("C", "X 3", (11, 0), (12, 0)),
        ], walkSeconds: { _, _ in 0 })

        XCTAssertEqual(layout.blocks.map(\.lane), [0, 1, 0])
        XCTAssertEqual(layout.blocks.map(\.laneCount), [2, 2, 1],
                       "The clash shares width; the later class gets the full column back")
    }

    func testNowLineOnlyAppearsInsideTheWindow() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        XCTAssertNil(layout.nowY(at: date(2026, 11, 4, 6, 0)), "Before the window")
        XCTAssertNil(layout.nowY(at: date(2026, 11, 4, 18, 0)), "After the window")
        XCTAssertEqual(layout.nowY(at: date(2026, 11, 4, 8, 0))!, 60 * layout.pointsPerMinute, accuracy: 0.001)
    }

    func testFractionIsClamped() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.fraction(for: date(2026, 11, 4, 0, 0)), 0)
        XCTAssertEqual(layout.fraction(for: date(2026, 11, 4, 23, 0)), 1)
        XCTAssertEqual(layout.fraction(for: date(2026, 11, 4, 12, 0)), 0.5, accuracy: 0.001)
    }

    func testHourMarksCoverTheWindowInclusive() {
        let layout = DayLayout(occurrences: wednesday, walkSeconds: eightMinuteWalk)
        XCTAssertEqual(layout.hourMarks().count, 11, "7:00 through 17:00")
    }

    func testEmptyDayHasNoGeometry() {
        let layout = DayLayout(occurrences: [], walkSeconds: eightMinuteWalk)
        XCTAssertTrue(layout.blocks.isEmpty)
        XCTAssertEqual(layout.height, 0)
        XCTAssertNil(layout.nowY(at: .now))
        XCTAssertTrue(layout.hourMarks().isEmpty)
    }
}

// MARK: - Row window

/// The large widget used `prefix(6)` on the whole day, which by late
/// afternoon is all finished classes: it showed the morning and hid what was
/// still ahead.
final class RowWindowTests: XCTestCase {

    private var longDay: [ScheduleEngine.Occurrence] {
        (8 ..< 15).map { occurrence("C\($0)", "X 1", ($0, 0), ($0, 50)) }
    }

    func testLateInTheDayKeepsWhatsStillAhead() {
        let result = RowWindow.select(longDay, now: date(2026, 11, 4, 13, 55), limit: 3)
        XCTAssertEqual(result.rows.map(\.event.course), ["C12", "C13", "C14"],
                       "Most recent finished class, then everything still to come")
        XCTAssertEqual(result.hiddenEarlier, 4)
        XCTAssertEqual(result.hiddenLater, 0)
    }

    func testEarlyInTheDayOverflowIsCountedBelow() {
        let result = RowWindow.select(longDay, now: date(2026, 11, 4, 7, 0), limit: 3)
        XCTAssertEqual(result.rows.map(\.event.course), ["C8", "C9", "C10"])
        XCTAssertEqual(result.hiddenEarlier, 0)
        XCTAssertEqual(result.hiddenLater, 4)
    }

    func testTheLiveClassIsNeverDropped() {
        let result = RowWindow.select(longDay, now: date(2026, 11, 4, 14, 20), limit: 1)
        XCTAssertEqual(result.rows.map(\.event.course), ["C14"])
    }

    func testAfterTheLastClassShowsTheEndOfTheDay() {
        let result = RowWindow.select(longDay, now: date(2026, 11, 4, 20, 0), limit: 2)
        XCTAssertEqual(result.rows.map(\.event.course), ["C13", "C14"])
        XCTAssertEqual(result.hiddenEarlier, 5)
    }

    func testZeroLimitShowsNothingButCountsEverything() {
        let result = RowWindow.select(longDay, now: date(2026, 11, 4, 11, 0), limit: 0)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.hiddenEarlier + result.hiddenLater, 7)
    }
}

// MARK: - Week grid

final class WeekGridGeometryTests: XCTestCase {

    private let events = [
        ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 1,
                   startSecond: 7 * 3600 + 1800, endSecond: 8 * 3600 + 2700, weekIndex: 0),
        ClassEvent(course: "ECE 20869", room: "UC 114", dayIndex: 1,
                   startSecond: 16 * 3600 + 1800, endSecond: 17 * 3600 + 2700, weekIndex: 0),
        ClassEvent(course: "Weekend", room: "X 1", dayIndex: 5,
                   startSecond: 6 * 3600, endSecond: 23 * 3600, weekIndex: 0),
    ]

    private func grid(pointsPerHour: Double = 60) -> WeekGridGeometry {
        WeekGridGeometry(events: events, dayCount: 5, pointsPerHour: pointsPerHour, columnsWidth: 300)
    }

    func testBoundsComeFromTheScheduleNotAFixedDay() {
        let geometry = grid()
        XCTAssertEqual(geometry.startSecond, 7 * 3600, "7:30 lecture isn't clipped")
        XCTAssertEqual(geometry.endSecond, 18 * 3600, "17:45 rounds up to 18:00")
    }

    func testHiddenWeekendDaysDontStretchTheBounds() {
        XCTAssertEqual(grid().startSecond, 7 * 3600, "Saturday's 6:00 isn't drawn, so it can't widen the grid")
    }

    func testEmptyScheduleFallsBackToAWorkingDay() {
        let geometry = WeekGridGeometry(events: [], dayCount: 5, columnsWidth: 300)
        XCTAssertEqual(geometry.startSecond, 8 * 3600)
        XCTAssertEqual(geometry.endSecond, 18 * 3600)
    }

    func testZoomIsClampedBothWays() {
        XCTAssertEqual(WeekGridGeometry.zoom(from: 64, magnification: 100), WeekGridGeometry.maxPointsPerHour)
        XCTAssertEqual(WeekGridGeometry.zoom(from: 64, magnification: 0.01), WeekGridGeometry.minPointsPerHour)
        XCTAssertEqual(WeekGridGeometry.zoom(from: 60, magnification: 1.5), 90)
    }

    func testFrameMatchesTime() {
        let frame = grid().frame(for: events[0])
        XCTAssertEqual(frame.x, 60, "Tuesday is the second of five 60-point columns")
        XCTAssertEqual(frame.y, 30, "Half an hour below the 7:00 top")
        XCTAssertEqual(frame.height, 75, "75 minutes at 60 points an hour")
    }

    /// A finger past the last column or below the grid must still name a
    /// real day and a drawn time.
    func testScrubIsClampedToTheGrid() {
        let geometry = grid()
        XCTAssertEqual(geometry.day(atX: -40), 0)
        XCTAssertEqual(geometry.day(atX: 10_000), 4)
        XCTAssertEqual(geometry.second(atY: -100), geometry.startSecond)
        XCTAssertEqual(geometry.second(atY: 100_000), geometry.endSecond)
    }

    func testScrubSnapsToFiveMinutes() {
        let geometry = grid()
        // 7:00 + 63 points at 60/hour = 8:03, which snaps to 8:05.
        XCTAssertEqual(geometry.second(atY: 63), 8 * 3600 + 5 * 60)
    }

    func testScrubReading() {
        let inClass = WeekGridGeometry.reading(day: 1, second: 8 * 3600, events: events)
        XCTAssertEqual(inClass, .inClass(events[0]))

        let free = WeekGridGeometry.reading(day: 1, second: 12 * 3600, events: events)
        XCTAssertEqual(free, .free(untilSecond: 16 * 3600 + 1800))

        let endOfDay = WeekGridGeometry.reading(day: 1, second: 18 * 3600, events: events)
        XCTAssertEqual(endOfDay, .free(untilSecond: nil))
    }

    func testAClassEndingAtTheScrubbedMinuteIsOver() {
        let reading = WeekGridGeometry.reading(day: 1, second: 8 * 3600 + 2700, events: events)
        XCTAssertEqual(reading, .free(untilSecond: 16 * 3600 + 1800))
    }

    /// Pinching on the afternoon should zoom into the afternoon. The moment
    /// under the fingers must sit at the same height on screen afterwards.
    func testZoomKeepsTheFocusUnderTheFingers() {
        let before = grid(pointsPerHour: 60)
        var after = before
        after.pointsPerHour = 120

        let focusY = 400.0, offsetAtStart = 250.0
        let offset = WeekGridGeometry.anchoredOffset(focusY: focusY, offsetAtStart: offsetAtStart,
                                                     from: before, to: after)

        let secondUnderFinger = Double(before.startSecond) + focusY / 60 * 3600
        let newContentY = (secondUnderFinger - Double(after.startSecond)) / 3600 * 120
        XCTAssertEqual(newContentY - offset, focusY - offsetAtStart, accuracy: 0.001)
    }

    func testZoomOffsetNeverGoesAboveTheTop() {
        let before = grid(pointsPerHour: 120)
        var after = before
        after.pointsPerHour = 40
        XCTAssertEqual(WeekGridGeometry.anchoredOffset(focusY: 10, offsetAtStart: 0, from: before, to: after), 0)
    }
}

// MARK: - Engine: one course

final class CourseOccurrenceTests: XCTestCase {

    private var table: Timetable {
        var table = Timetable()
        table.events = [
            ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 0,
                       startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
            ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 2,
                       startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
            ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 1,
                       startSecond: 7 * 3600 + 1800, endSecond: 8 * 3600 + 2700, weekIndex: 0),
        ]
        table.termStart = date(2026, 10, 26)
        table.termEnd = date(2026, 12, 12)
        return table
    }

    func testPastOccurrencesAreNewestFirstAndOnlyThisCourse() {
        let engine = ScheduleEngine(timetable: table)
        let past = engine.pastOccurrences(ofCourse: "ECE 30200", before: date(2026, 11, 5, 12, 0), limit: 10)

        XCTAssertEqual(past.map(\.start), [
            date(2026, 11, 4, 15, 30), date(2026, 11, 2, 15, 30),
            date(2026, 10, 28, 15, 30), date(2026, 10, 26, 15, 30),
        ], "Stops at term start")
        XCTAssertTrue(past.allSatisfy { $0.event.course == "ECE 30200" })
    }

    /// The class you're sitting in counts as past, so it can be marked.
    func testAClassInProgressCountsAsPast() {
        let engine = ScheduleEngine(timetable: table)
        let past = engine.pastOccurrences(ofCourse: "ECE 30200", before: date(2026, 11, 4, 15, 45), limit: 1)
        XCTAssertEqual(past.first?.start, date(2026, 11, 4, 15, 30))
    }

    func testUpcomingRespectsLimit() {
        let engine = ScheduleEngine(timetable: table)
        let next = engine.upcomingOccurrences(ofCourse: "ECE 30200", after: date(2026, 11, 4, 16, 0), limit: 2)
        XCTAssertEqual(next.map(\.start), [date(2026, 11, 9, 15, 30), date(2026, 11, 11, 15, 30)])
    }
}

// MARK: - Course summary

final class CourseSummaryTests: XCTestCase {

    private func summary(attendance: [AttendanceEntry], tasks: [TaskEvent] = []) -> CourseSummary {
        var table = Timetable()
        table.events = [
            ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 0,
                       startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
            ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 2,
                       startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
        ]
        table.tasks = tasks
        table.termStart = date(2026, 10, 19)
        return CourseSummary.build(course: "ECE 30200",
                                   engine: ScheduleEngine(timetable: table),
                                   attendance: attendance,
                                   now: date(2026, 11, 5, 9, 0))
    }

    private func marked(_ day: Int, _ state: AttendanceState, month: Int = 11) -> AttendanceEntry {
        AttendanceEntry(date: date(2026, month, day, 15, 30), state: state, wasAutomatic: false)
    }

    /// No record and 0% are different facts and must read differently.
    func testNothingRecordedIsNilNotZero() {
        XCTAssertNil(summary(attendance: []).attendanceRate)
    }

    func testRateCountsOnlyRecordedAndIgnoresExcused() {
        let s = summary(attendance: [marked(4, .attended), marked(2, .missed),
                                     marked(28, .attended, month: 10), marked(26, .excused, month: 10)])
        XCTAssertEqual(s.attendanceRate!, 2.0 / 3.0, accuracy: 0.001)
    }

    func testRecordsAttachToTheirExactMeeting() {
        let s = summary(attendance: [marked(2, .missed)])
        XCTAssertEqual(s.history.first { $0.state != nil }?.occurrence.start, date(2026, 11, 2, 15, 30))
        XCTAssertNil(s.history.first?.state, "Wednesday the 4th is unrecorded")
    }

    /// Forgetting to tap isn't the same as not going.
    func testStreakSkipsUnrecordedAndStopsAtAMiss() {
        let s = summary(attendance: [marked(2, .attended), marked(28, .attended, month: 10),
                                     marked(26, .missed, month: 10), marked(21, .attended, month: 10)])
        XCTAssertEqual(s.streak, 2)
    }

    func testWorkIsThisCourseFamilyUndoneAndInDateOrder() {
        let tasks = [
            TaskEvent(title: "Lab report", course: "ECE 30200L", due: date(2026, 11, 9), kind: .assignment),
            TaskEvent(title: "Exam 2", course: "ECE 30200", due: date(2026, 11, 7), kind: .exam),
            TaskEvent(title: "Done", course: "ECE 30200", due: date(2026, 11, 8), kind: .quiz, isDone: true),
            TaskEvent(title: "Old", course: "ECE 30200", due: date(2026, 11, 1), kind: .quiz),
            TaskEvent(title: "Other", course: "ECE 30100", due: date(2026, 11, 8), kind: .quiz),
        ]
        XCTAssertEqual(summary(attendance: [], tasks: tasks).work.map(\.title), ["Exam 2", "Lab report"])
    }

    func testWeeklyMinutes() {
        XCTAssertEqual(summary(attendance: []).weeklyMinutes, 100)
    }
}

// MARK: - Emphasis

/// The user asked for these three tiers explicitly. They must survive every
/// redesign.
final class EmphasisTests: XCTestCase {

    func testThreeTiers() {
        XCTAssertEqual(RowEmphasis(.finished).opacity, 0.34)
        XCTAssertEqual(RowEmphasis(.inProgress).opacity, 1)
        XCTAssertEqual(RowEmphasis(.upcoming).opacity, 0.88)
    }

    func testOnlyFinishedClassesAreStruckThrough() {
        XCTAssertTrue(RowEmphasis(.finished).isStruck)
        XCTAssertFalse(RowEmphasis(.inProgress).isStruck)
        XCTAssertFalse(RowEmphasis(.upcoming).isStruck)
    }
}

// MARK: - Onboarding

final class OnboardingGateTests: XCTestCase {

    func testFreshInstallSeesIt() {
        XCTAssertTrue(OnboardingGate.shouldPresent(hasCompleted: false, hasSchedule: false))
    }

    /// Existing users predate onboarding and never set the flag. They must
    /// not be greeted with a welcome screen over their own schedule.
    func testExistingScheduleSkipsIt() {
        XCTAssertFalse(OnboardingGate.shouldPresent(hasCompleted: false, hasSchedule: true))
    }

    func testFinishedStaysFinished() {
        XCTAssertFalse(OnboardingGate.shouldPresent(hasCompleted: true, hasSchedule: false))
    }
}

// MARK: - Store

@MainActor
final class StoreTaskTests: XCTestCase {

    /// Tasks used to be given a fresh UUID on every refresh, so no task could
    /// be found again to mark done.
    func testTaskIdentitySurvivesRefresh() {
        let store = BellStore(inMemory: true)
        let id = store.addTask(title: "Exam 2", course: "ECE 30200", due: date(2026, 11, 7), kind: .exam)

        XCTAssertEqual(store.timetable.tasks.map(\.id), [id])
        store.refresh()
        XCTAssertEqual(store.timetable.tasks.map(\.id), [id], "Same identity after a rebuild")
    }

    func testMarkingDoneFindsTheTask() {
        let store = BellStore(inMemory: true)
        let id = store.addTask(title: "Exam 2", course: "ECE 30200", due: date(2026, 11, 7), kind: .exam)

        store.setTaskDone(true, id: id)
        XCTAssertEqual(store.timetable.tasks.first?.isDone, true)

        store.deleteTask(id: id)
        XCTAssertTrue(store.timetable.tasks.isEmpty)
    }

    func testAttendanceRoundTrips() {
        let store = BellStore(inMemory: true)
        let start = date(2026, 11, 4, 15, 30)
        store.record(.attended, forCourse: "ECE 30200", at: start)
        store.record(.missed, forCourse: "ECE 30200", at: start)

        let entries = store.attendance(forCourse: "ECE 30200")
        XCTAssertEqual(entries.count, 1, "Re-marking the same meeting replaces, not appends")
        XCTAssertEqual(entries.first?.state, .missed)
        XCTAssertEqual(entries.first?.date, start)
    }
}

// MARK: - Info.plist

/// Both warnings Xcode raised on every build. Checked against the built
/// bundle, because the plist on disk isn't what ships if the project
/// generator ever stops picking it up.
final class InfoPlistTests: XCTestCase {

    /// Read from the file, not `infoDictionary`: on an iPhone that resolves
    /// device-specific keys and silently drops every `~ipad` variant.
    private var info: [String: Any] {
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    func testDeclaresWhetherDocumentsOpenInPlace() {
        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, false)
    }

    func testIPadSupportsEveryOrientationForMultitasking() {
        let orientations = Set(info["UISupportedInterfaceOrientations~ipad"] as? [String] ?? [])
        XCTAssertEqual(orientations, [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
    }
}

// MARK: - Legibility

/// The course header and week blocks put text on the course colour. A fixed
/// luminance cut at 0.45 gave mid-ramp colours white text at about 2:1.
final class LegibilityTests: XCTestCase {

    func testEveryPaletteStepGetsReadableText() {
        let courses = (0 ..< 10).map { "C\($0)00" }
        for (course, color) in Palette.assign(courses: courses) {
            let background = Palette.relativeLuminance(color)
            let text = Palette.relativeLuminance(Bell.legibleOn(color))
            XCTAssertGreaterThanOrEqual(Bell.contrast(background, text), 4.5,
                                        "\(course) text fails WCAG AA for body text")
        }
    }

    func testOrchidGetsDarkText() {
        let orchid = Color(red: 0.85, green: 0.60, blue: 0.85)
        XCTAssertEqual(Bell.legibleOn(orchid), Bell.ink, "Fixed ink, not the adaptive canvas: a light slab needs dark text in dark mode too")
    }
}
