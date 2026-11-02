import EventKit
import XCTest
@testable import Bell

// Phase 3: calendar sync and clashes. The reconciler gets the most tests
// because it's the code that can delete things in someone else's app.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

/// Monday and Wednesday lecture plus a Tuesday lab. Term starts 2 Nov 2026,
/// a Monday.
private func timetable() -> Timetable {
    var table = Timetable()
    table.events = [
        ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 0,
                   startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
        ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 2,
                   startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0,
                   instructor: "A R Reibman"),
        ClassEvent(course: "ECE 30864L", room: "BHEE 206", dayIndex: 1,
                   startSecond: 9 * 3600 + 1800, endSecond: 11 * 3600 + 1200, weekIndex: 0),
    ]
    table.termStart = date(2026, 11, 2)
    table.termEnd = date(2026, 12, 12)
    return table
}

private let monday = date(2026, 11, 2, 8, 0)

// MARK: - Plan

final class CalendarPlanTests: XCTestCase {

    func testDesiredCoversTheHorizonOnly() {
        let desired = CalendarPlan.desired(engine: ScheduleEngine(timetable: timetable()),
                                           from: monday, days: 7, hidden: [])
        XCTAssertEqual(desired.count, 3, "One week: Mon, Tue, Wed")
        XCTAssertEqual(desired.map(\.start), desired.map(\.start).sorted())
    }

    func testHiddenCoursesAreNotWritten() {
        let desired = CalendarPlan.desired(engine: ScheduleEngine(timetable: timetable()),
                                           from: monday, days: 7, hidden: ["ECE 30864L"])
        XCTAssertFalse(desired.contains { $0.title == "ECE 30864L" })
    }

    func testCancelledMeetingsAreNotWritten() {
        var table = timetable()
        let engine = ScheduleEngine(timetable: table)
        let first = engine.occurrences(on: monday)[0]
        table.cancelled = [first.key]

        let desired = CalendarPlan.desired(engine: ScheduleEngine(timetable: table),
                                           from: monday, days: 7, hidden: [])
        XCTAssertFalse(desired.contains { $0.key == first.key })
    }

    func testKeyRoundTripsThroughTheURL() {
        let key = "ECE 30864L|1730000000"
        XCTAssertEqual(CalendarPlan.key(url: CalendarPlan.url(for: key), notes: nil), key,
                       "Spaces and the bar survive percent-encoding")
    }

    /// Some servers drop the URL field. The notes marker is the fallback;
    /// without one Bell can't recognise its own events and duplicates them.
    func testKeySurvivesInNotesWhenTheURLIsLost() {
        let notes = CalendarPlan.notes(instructor: "A R Reibman", key: "ECE 30200|1730000000")
        XCTAssertEqual(CalendarPlan.key(url: nil, notes: notes), "ECE 30200|1730000000")
        XCTAssertTrue(notes.hasPrefix("A R Reibman"))
    }

    func testOtherPeoplesEventsHaveNoKey() {
        XCTAssertNil(CalendarPlan.key(url: URL(string: "https://zoom.us/j/123"), notes: "Bring laptop"))
        XCTAssertNil(CalendarPlan.key(url: nil, notes: nil))
        XCTAssertNil(CalendarPlan.key(url: nil, notes: "bell:"), "An empty marker is not a key")
    }

    func testKeysAreStableAcrossEngineRebuilds() {
        let a = ScheduleEngine(timetable: timetable()).occurrences(on: monday).map(\.key)
        let b = ScheduleEngine(timetable: timetable()).occurrences(on: monday).map(\.key)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first, "ECE 30200|\(Int(date(2026, 11, 2, 15, 30).timeIntervalSince1970))")
    }
}

// MARK: - Reconciler

final class CalendarReconcilerTests: XCTestCase {

    private var desired: [CalendarPlan.Planned] {
        CalendarPlan.desired(engine: ScheduleEngine(timetable: timetable()), from: monday, days: 14, hidden: [])
    }

    private func existing(_ planned: CalendarPlan.Planned, id: String? = nil) -> CalendarReconciler.Existing {
        .init(identifier: id ?? "ek-\(planned.key)", key: planned.key, title: planned.title,
              location: planned.location, start: planned.start, end: planned.end)
    }

    func testFirstSyncCreatesEverything() {
        let result = CalendarReconciler.reconcile(desired: desired, existing: [], ledger: [])
        XCTAssertEqual(result.create.count, desired.count)
        XCTAssertTrue(result.update.isEmpty && result.delete.isEmpty && result.cancelled.isEmpty)
        XCTAssertEqual(result.ledger, Set(desired.map(\.key)))
    }

    func testSecondSyncIsANoOp() {
        let result = CalendarReconciler.reconcile(desired: desired,
                                                  existing: desired.map { existing($0) },
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.cancelled.isEmpty)
    }

    /// A room change edits the event in place: same identifier, so anything
    /// the user attached to it in their calendar app stays attached.
    func testRoomChangeUpdatesInPlace() {
        var moved = desired
        moved[0].location = "WALC 2088"
        let result = CalendarReconciler.reconcile(desired: moved,
                                                  existing: desired.map { existing($0) },
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertEqual(result.update.map(\.identifier), ["ek-\(desired[0].key)"])
        XCTAssertEqual(result.update.first?.planned.location, "WALC 2088")
        XCTAssertTrue(result.create.isEmpty && result.delete.isEmpty)
    }

    func testDroppedCourseIsDeleted() {
        let kept = desired.filter { $0.title != "ECE 30864L" }
        let result = CalendarReconciler.reconcile(desired: kept,
                                                  existing: desired.map { existing($0) },
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertEqual(result.delete.count, 2, "Two weeks of Tuesday labs")
        XCTAssertTrue(result.cancelled.isEmpty, "Bell removed them; the user didn't")
    }

    /// The two-way part: deleting one class in Calendar means it's cancelled.
    func testUserDeletionBecomesACancellation() {
        let deleted = desired[1]
        let result = CalendarReconciler.reconcile(desired: desired,
                                                  existing: desired.filter { $0 != deleted }.map { existing($0) },
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertEqual(result.cancelled, [deleted.key])
        XCTAssertTrue(result.create.isEmpty, "Not put back")
        XCTAssertFalse(result.ledger.contains(deleted.key))
    }

    /// Missing but never written is just "not yet created". Without the
    /// ledger, every new class entering the four-week window would look
    /// deleted.
    func testMissingButNeverWrittenIsCreated() {
        let newOne = desired.last!
        let result = CalendarReconciler.reconcile(desired: desired,
                                                  existing: desired.dropLast().map { existing($0) },
                                                  ledger: Set(desired.dropLast().map(\.key)))
        XCTAssertEqual(result.create.map(\.key), [newOne.key])
        XCTAssertTrue(result.cancelled.isEmpty)
    }

    /// An account removed and re-added, or a calendar reset, makes every
    /// event vanish at once. That must never read as "cancel all classes".
    func testMassDisappearanceIsTreatedAsAResetNotCancellations() {
        let result = CalendarReconciler.reconcile(desired: desired, existing: [],
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertTrue(result.suspectedReset)
        XCTAssertTrue(result.cancelled.isEmpty)
        XCTAssertEqual(result.create.count, desired.count)
    }

    func testThreeDeletionsStillCountAsDeliberate() {
        let gone = Array(desired.prefix(CalendarReconciler.deliberateDeletionLimit))
        let result = CalendarReconciler.reconcile(desired: desired,
                                                  existing: desired.dropFirst(gone.count).map { existing($0) },
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertFalse(result.suspectedReset)
        XCTAssertEqual(Set(result.cancelled), Set(gone.map(\.key)))
    }

    /// The user's own events in a shared target calendar are not Bell's.
    func testEventsWithoutAKeyAreNeverTouched() {
        let theirs = CalendarReconciler.Existing(identifier: "dentist", key: nil, title: "Dentist",
                                                 location: "", start: monday, end: monday.addingTimeInterval(3600))
        let result = CalendarReconciler.reconcile(desired: desired,
                                                  existing: desired.map { existing($0) } + [theirs],
                                                  ledger: Set(desired.map(\.key)))
        XCTAssertFalse(result.delete.contains("dentist"))
        XCTAssertFalse(result.update.contains { $0.identifier == "dentist" })
    }

    func testDuplicatesAreCollapsed() {
        let first = desired[0]
        let result = CalendarReconciler.reconcile(
            desired: desired,
            existing: desired.map { existing($0) } + [existing(first, id: "ek-dupe")],
            ledger: Set(desired.map(\.key)))
        XCTAssertEqual(result.delete, ["ek-dupe"])
    }
}

// MARK: - Conflicts

final class ConflictDetectorTests: XCTestCase {

    private func lecture(_ start: (Int, Int), _ end: (Int, Int), room: String = "WALC 1018") -> ScheduleEngine.Occurrence {
        let event = ClassEvent(course: "ECE 30200", room: room, dayIndex: 0,
                               startSecond: start.0 * 3600 + start.1 * 60,
                               endSecond: end.0 * 3600 + end.1 * 60, weekIndex: 0)
        return .init(event: event, start: date(2026, 11, 2, start.0, start.1),
                     end: date(2026, 11, 2, end.0, end.1))
    }

    private func event(_ title: String, _ start: (Int, Int), _ end: (Int, Int),
                       building: String? = nil, allDay: Bool = false, busy: Bool = true) -> ExternalEvent {
        ExternalEvent(id: title, title: title,
                      start: date(2026, 11, 2, start.0, start.1), end: date(2026, 11, 2, end.0, end.1),
                      location: building, calendarTitle: "Work", isAllDay: allDay, isBusy: busy,
                      building: building)
    }

    /// Ten minutes between any two different buildings.
    private func walk(_ a: String?, _ b: String?) -> TimeInterval {
        guard let a, let b, a != b else { return 0 }
        return 10 * 60
    }

    func testOverlapIsFound() {
        let found = ConflictDetector.conflicts(classes: [lecture((15, 30), (16, 20))],
                                               events: [event("Interview", (16, 0), (17, 0))],
                                               walkSeconds: walk)
        XCTAssertEqual(found.map(\.kind), [.overlap(minutes: 20)])
    }

    /// The clash a calendar app can't see: no overlap, but no time to walk.
    func testTooCloseToWalkFromAnEventToClass() {
        let found = ConflictDetector.conflicts(classes: [lecture((15, 30), (16, 20))],
                                               events: [event("TA meeting", (14, 30), (15, 25), building: "MSEE")],
                                               walkSeconds: walk)
        XCTAssertEqual(found.map(\.kind), [.cantReachClass(gapMinutes: 5, walkMinutes: 10)])
    }

    func testTooCloseToWalkFromClassToAnEvent() {
        let found = ConflictDetector.conflicts(classes: [lecture((15, 30), (16, 20))],
                                               events: [event("Office hours", (16, 25), (17, 0), building: "MSEE")],
                                               walkSeconds: walk)
        XCTAssertEqual(found.map(\.kind), [.cantReachEvent(gapMinutes: 5, walkMinutes: 10)])
    }

    func testEnoughTimeIsFine() {
        let found = ConflictDetector.conflicts(classes: [lecture((15, 30), (16, 20))],
                                               events: [event("TA meeting", (14, 0), (15, 15), building: "MSEE")],
                                               walkSeconds: walk)
        XCTAssertTrue(found.isEmpty)
    }

    func testUnknownPlaceCantProduceATravelClash() {
        let found = ConflictDetector.conflicts(classes: [lecture((15, 30), (16, 20))],
                                               events: [event("Call", (15, 0), (15, 29))],
                                               walkSeconds: walk)
        XCTAssertTrue(found.isEmpty)
    }

    /// If another class sits between, you aren't walking from the event to
    /// this class, so the distance between them doesn't matter.
    func testOnlyNeighboursAreCheckedForTravel() {
        let found = ConflictDetector.conflicts(
            classes: [lecture((13, 0), (14, 50), room: "MSEE 180"), lecture((15, 30), (16, 20))],
            events: [event("Lunch", (12, 0), (12, 55), building: "PMU")],
            walkSeconds: walk)
        XCTAssertEqual(found.count, 1, "Lunch is only checked against the 13:00 class")
        XCTAssertEqual(found.first?.occurrence.start, date(2026, 11, 2, 13, 0))
    }

    func testAllDayAndFreeEventsNeverClash() {
        let found = ConflictDetector.conflicts(
            classes: [lecture((15, 30), (16, 20))],
            events: [event("Holiday", (0, 0), (23, 59), allDay: true),
                     event("Focus time", (15, 0), (17, 0), busy: false)],
            walkSeconds: walk)
        XCTAssertTrue(found.isEmpty)
    }

    func testBuildingIsFoundInFreeText() {
        XCTAssertEqual(Campus.building(in: "Office hours, MSEE 180"), "MSEE")
        XCTAssertEqual(Campus.building(in: "WALC study room 3"), "WALC")
        XCTAssertNil(Campus.building(in: "Zoom"))
        XCTAssertNil(Campus.building(in: nil))
    }

    /// Upper-casing first made "me" the ME building.
    func testOrdinaryWordsAreNotBuildings() {
        XCTAssertNil(Campus.building(in: "meet me at the uc"))
    }
}

// MARK: - Other calendars in the day view

final class BusyLayoutTests: XCTestCase {

    private func lecture(_ start: (Int, Int), _ end: (Int, Int)) -> ScheduleEngine.Occurrence {
        let event = ClassEvent(course: "A", room: "X 1", dayIndex: 0,
                               startSecond: start.0 * 3600 + start.1 * 60,
                               endSecond: end.0 * 3600 + end.1 * 60, weekIndex: 0)
        return .init(event: event, start: date(2026, 11, 2, start.0, start.1), end: date(2026, 11, 2, end.0, end.1))
    }

    private func busy(_ start: (Int, Int), _ end: (Int, Int)) -> ExternalEvent {
        ExternalEvent(id: "e\(start.0)", title: "Dentist",
                      start: date(2026, 11, 2, start.0, start.1), end: date(2026, 11, 2, end.0, end.1),
                      calendarTitle: "Home")
    }

    /// A gap the user has filled with something else isn't free time.
    func testBusyEventSplitsWhatWouldBeFreeTime() {
        let layout = DayLayout(occurrences: [lecture((9, 0), (10, 0)), lecture((14, 0), (15, 0))],
                               busy: [busy((11, 0), (13, 0))],
                               walkSeconds: { _, _ in 0 })
        XCTAssertEqual(layout.busyBlocks.count, 1)
        XCTAssertEqual(layout.gaps.map(\.minutes), [60, 60], "10–11 and 13–14, not one 4-hour gap")
    }

    func testBusyEventsWidenTheWindow() {
        let layout = DayLayout(occurrences: [lecture((9, 0), (10, 0))],
                               busy: [busy((18, 0), (19, 30))],
                               walkSeconds: { _, _ in 0 })
        XCTAssertEqual(layout.windowEnd, date(2026, 11, 2, 20, 0))
    }

    func testOverlappingBusyEventSharesWidthWithTheClass() {
        let layout = DayLayout(occurrences: [lecture((9, 0), (10, 0))],
                               busy: [busy((9, 30), (10, 30))],
                               walkSeconds: { _, _ in 0 })
        XCTAssertEqual(layout.blocks.first?.laneCount, 2)
        XCTAssertEqual(layout.busyBlocks.first?.lane, 1)
    }

    /// A five-minute reminder in someone's calendar shouldn't stretch the day.
    func testBusyEventsDontDriveTheScale() {
        let plain = DayLayout(occurrences: [lecture((9, 0), (10, 0))], walkSeconds: { _, _ in 0 })
        let withReminder = DayLayout(occurrences: [lecture((9, 0), (10, 0))],
                                     busy: [busy((11, 0), (11, 5))], walkSeconds: { _, _ in 0 })
        XCTAssertEqual(plain.pointsPerMinute, withReminder.pointsPerMinute)
    }
}

// MARK: - Cancellations

final class CancellationTests: XCTestCase {

    func testCancelledMeetingDisappearsOnlyThatDay() {
        var table = timetable()
        let first = ScheduleEngine(timetable: table).occurrences(on: monday)[0]
        table.cancelled = [first.key]
        let engine = ScheduleEngine(timetable: table)

        XCTAssertTrue(engine.occurrences(on: monday).isEmpty)
        XCTAssertEqual(engine.cancelledOccurrences(on: monday).map(\.key), [first.key])
        XCTAssertEqual(engine.occurrences(on: date(2026, 11, 4)).count, 1, "Wednesday still on")
        XCTAssertEqual(engine.next(after: monday)?.event.course, "ECE 30864L",
                       "Next class skips the cancelled lecture")
    }

    /// The widget can read a snapshot written by the previous build. A
    /// missing field must decode as empty, not throw.
    func testOldSnapshotWithoutCancellationsStillDecodes() throws {
        let old = #"{"events":[],"tasks":[],"exceptions":[],"weekCount":1,"rotationAnchor":"2026-08-24T00:00:00Z","showsWeekends":false}"#
        let table = try JSONDecoder.bell.decode(Timetable.self, from: Data(old.utf8))
        XCTAssertTrue(table.cancelled.isEmpty)
        XCTAssertEqual(table.weekCount, 1)
    }

    func testCancellationsRoundTripThroughTheSnapshotFormat() throws {
        var table = timetable()
        table.cancelled = ["ECE 30200|1"]
        let decoded = try JSONDecoder.bell.decode(Timetable.self, from: JSONEncoder.bell.encode(table))
        XCTAssertEqual(decoded, table)
    }
}

@MainActor
final class StoreCancellationTests: XCTestCase {

    func testCancelIsIdempotentAndRestorable() {
        let store = BellStore(inMemory: true)
        store.replaceSchedule(with: timetable(), source: .manual, summary: "test")
        let first = store.engine.occurrences(on: monday)[0]

        store.cancel([first])
        store.cancel([first])
        XCTAssertEqual(store.cancellations().count, 1)
        XCTAssertEqual(store.timetable.cancelled, [first.key])

        store.restore(cancellationKey: first.key)
        XCTAssertTrue(store.timetable.cancelled.isEmpty)
        XCTAssertEqual(store.engine.occurrences(on: monday).count, 1)
    }
}

// MARK: - Info.plist

final class CalendarInfoPlistTests: XCTestCase {

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// Without this string, asking for access crashes the app.
    func testDeclaresWhyItWantsCalendars() {
        XCTAssertFalse((info["NSCalendarsFullAccessUsageDescription"] as? String ?? "").isEmpty)
    }

    func testRegistersTheBellURLScheme() {
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("bell"), "Calendar event links would open nothing")
    }
}

// MARK: - Real EventKit

/// Runs the whole loop against the simulator's real calendar database:
/// write, read back by key, delete one in "another app", sync again.
/// Skipped when calendar access hasn't been granted to the test host
/// (`xcrun simctl privacy <device> grant calendar com.yourteam.bell`).
@MainActor
final class CalendarRoundTripTests: XCTestCase {

    private var saved: (writes: Bool, target: String?, ledger: [String])!

    override func setUp() async throws {
        saved = (Preferences.calendarWritesEnabled, Preferences.calendarIdentifier, Preferences.calendarLedger)
    }

    override func tearDown() async throws {
        Preferences.calendarWritesEnabled = saved.writes
        Preferences.calendarIdentifier = saved.target
        Preferences.calendarLedger = saved.ledger
    }

    func testWriteDeleteOneAndSyncAgain() throws {
        let sync = CalendarSync()
        guard sync.access == .granted else { throw XCTSkip("Calendar access not granted on this simulator") }

        // A throwaway calendar, so nothing real is touched.
        let calendar = EKCalendar(for: .event, eventStore: sync.store)
        calendar.title = "Bell test \(UUID().uuidString.prefix(6))"
        calendar.source = sync.store.sources.first { $0.sourceType == .local }
            ?? sync.store.defaultCalendarForNewEvents?.source
        try sync.store.saveCalendar(calendar, commit: true)
        defer { try? sync.store.removeCalendar(calendar, commit: true) }

        Preferences.calendarWritesEnabled = true
        Preferences.calendarIdentifier = calendar.calendarIdentifier
        Preferences.calendarLedger = []

        let engine = ScheduleEngine(timetable: timetable())
        let first = try XCTUnwrap(sync.sync(engine: engine, hidden: [], now: monday))
        XCTAssertEqual(first.created, 12, "Four weeks of Mon, Tue, Wed")

        let again = try XCTUnwrap(sync.sync(engine: engine, hidden: [], now: monday))
        XCTAssertEqual(again.created + again.updated + again.deleted, 0,
                       "Keys survived the save, so Bell recognises its own events")

        // Delete one, the way Calendar.app would.
        let window = sync.store.predicateForEvents(withStart: monday,
                                                   end: monday.addingTimeInterval(86_400 * 28),
                                                   calendars: [calendar])
        let victim = try XCTUnwrap(sync.store.events(matching: window).min { $0.startDate < $1.startDate })
        let victimKey = CalendarPlan.key(url: victim.url, notes: victim.notes)
        try sync.store.remove(victim, span: .thisEvent, commit: true)

        let third = try XCTUnwrap(sync.sync(engine: engine, hidden: [], now: monday))
        XCTAssertEqual(third.cancelledKeys, [victimKey].compactMap { $0 })
        XCTAssertEqual(third.created, 0, "A deletion is a cancellation, not something to put back")
    }
}

@MainActor
final class LaunchSyncTests: XCTestCase {

    /// Other calendars were never read on a cold launch: nothing triggered a
    /// sync until the timetable or the calendar changed.
    func testLaunchReadsOtherCalendars() async throws {
        let session = AppSession()
        guard session.calendar.access == .granted else { throw XCTSkip("Calendar access not granted") }

        let store = session.calendar.store
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Bell launch test"
        calendar.source = store.sources.first { $0.sourceType == .local } ?? store.defaultCalendarForNewEvents?.source
        try store.saveCalendar(calendar, commit: true)
        defer { try? store.removeCalendar(calendar, commit: true) }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "Launch probe"
        event.startDate = Date.now.addingTimeInterval(3600)
        event.endDate = event.startDate.addingTimeInterval(1800)
        try store.save(event, span: .thisEvent, commit: true)

        let savedReads = Preferences.calendarReadsEnabled
        let savedOnboarded = Preferences.hasCompletedOnboarding
        Preferences.calendarReadsEnabled = true
        // Skip the permission prompts; they'd block a test run.
        Preferences.hasCompletedOnboarding = false
        defer {
            Preferences.calendarReadsEnabled = savedReads
            Preferences.hasCompletedOnboarding = savedOnboarded
        }

        await session.didLaunch(using: BellStore(inMemory: true))
        XCTAssertTrue(session.calendar.external.contains { $0.title == "Launch probe" })
    }
}
