import CoreLocation
import XCTest
@testable import Bell

// Phase 6: location. Everything here runs in the background in real use,
// where a mistake is invisible until it marks the wrong class or nags someone
// who's already in their seat, so the decisions are tested directly.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

private func seconds(_ h: Int, _ m: Int = 0) -> Int { h * 3600 + m * 60 }

/// Mon: 7:30 ECE 30100 (BHEE 170), 9:30 ECE 30864 (WALC 2088),
/// 15:30 ECE 30200 (WALC 1018). Tue: 9:30 ECE 30864L (BHEE 206).
private func timetable() -> Timetable {
    var table = Timetable()
    table.events = [
        ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 0,
                   startSecond: seconds(7, 30), endSecond: seconds(8, 45), weekIndex: 0),
        ClassEvent(course: "ECE 30864", room: "WALC 2088", dayIndex: 0,
                   startSecond: seconds(9, 30), endSecond: seconds(10, 20), weekIndex: 0),
        ClassEvent(course: "ECE 30200", room: "WALC 1018", dayIndex: 0,
                   startSecond: seconds(15, 30), endSecond: seconds(16, 20), weekIndex: 0),
        ClassEvent(course: "ECE 30864L", room: "BHEE 206", dayIndex: 1,
                   startSecond: seconds(9, 30), endSecond: seconds(11, 20), weekIndex: 0),
    ]
    table.termStart = date(2026, 10, 26)
    table.termEnd = date(2026, 12, 12)
    return table
}

private let engine = ScheduleEngine(timetable: timetable())
private let coordinates: [String: CLLocationCoordinate2D] = [
    "BHEE": .init(latitude: 40.4289, longitude: -86.9118),
    "WALC": .init(latitude: 40.4274, longitude: -86.9132),
]
private func lookup(_ building: String) -> CLLocationCoordinate2D? { coordinates[building] }

// MARK: - Geofences

final class GeofencePlanTests: XCTestCase {

    func testBuildingsInOrderOfTheNextClassOnceEach() {
        let regions = GeofencePlan.regions(engine: engine, hidden: [], from: date(2026, 11, 2, 6), coordinate: lookup)
        XCTAssertEqual(regions.map(\.building), ["BHEE", "WALC"])
        XCTAssertEqual(regions.first?.radius, GeofencePlan.radius)
    }

    func testFinishedClassesDontHoldASlot() {
        let regions = GeofencePlan.regions(engine: engine, hidden: [], from: date(2026, 11, 2, 9), coordinate: lookup)
        XCTAssertEqual(regions.map(\.building), ["WALC", "BHEE"], "BHEE comes back for Tuesday's lab, after WALC")
    }

    func testUnknownBuildingsAndHiddenCoursesAreSkipped() {
        let regions = GeofencePlan.regions(engine: engine, hidden: ["ECE 30100", "ECE 30864L"],
                                           from: date(2026, 11, 2, 6),
                                           coordinate: { $0 == "WALC" ? coordinates["WALC"] : nil })
        XCTAssertEqual(regions.map(\.building), ["WALC"])
    }

    func testHomeComesFirst() {
        let home = CLLocationCoordinate2D(latitude: 40.42, longitude: -86.92)
        let regions = GeofencePlan.regions(engine: engine, hidden: [], from: date(2026, 11, 2, 6), home: home,
                                           coordinate: lookup)
        XCTAssertEqual(regions.map(\.building), ["HOME", "BHEE", "WALC"])
    }

    /// iOS refuses more than 20.
    func testNeverMoreThanTheSystemLimit() {
        var table = Timetable()
        table.events = (0 ..< 30).map { i in
            ClassEvent(course: "C \(i)", room: "B\(i) 1", dayIndex: 0,
                       startSecond: seconds(7) + i * 60, endSecond: seconds(7) + i * 60 + 50, weekIndex: 0)
        }
        let regions = GeofencePlan.regions(engine: ScheduleEngine(timetable: table), hidden: [],
                                           from: date(2026, 11, 2, 6),
                                           home: .init(latitude: 40, longitude: -86),
                                           coordinate: { _ in .init(latitude: 40.4, longitude: -86.9) })
        XCTAssertEqual(regions.count, GeofencePlan.limit)
    }
}

// MARK: - Attendance

final class AttendanceRuleTests: XCTestCase {

    private var monday: [ScheduleEngine.Occurrence] { engine.occurrences(on: date(2026, 11, 2)) }

    func testArrivingShortlyBeforeCounts() {
        XCTAssertEqual(AttendanceRule.occurrence(enteringBuilding: "WALC", at: date(2026, 11, 2, 9, 20),
                                                 among: monday)?.event.course, "ECE 30864")
    }

    func testArrivingLateCountsUntilHalfway() {
        XCTAssertNotNil(AttendanceRule.occurrence(enteringBuilding: "WALC", at: date(2026, 11, 2, 9, 54), among: monday))
        XCTAssertNil(AttendanceRule.occurrence(enteringBuilding: "WALC", at: date(2026, 11, 2, 10, 0), among: monday),
                     "Past halfway is for the user to decide")
    }

    func testTooEarlyOrWrongBuildingDoesntCount() {
        XCTAssertNil(AttendanceRule.occurrence(enteringBuilding: "WALC", at: date(2026, 11, 2, 9, 0), among: monday))
        XCTAssertNil(AttendanceRule.occurrence(enteringBuilding: "BHEE", at: date(2026, 11, 2, 9, 25), among: monday))
    }

    func testBuildingMatchIgnoresCase() {
        XCTAssertNotNil(AttendanceRule.occurrence(enteringBuilding: "walc", at: date(2026, 11, 2, 15, 25), among: monday))
    }
}

@MainActor
final class AutomaticAttendanceStoreTests: XCTestCase {

    private let start = date(2026, 11, 2, 9, 30)

    /// A geofence never overrules the user.
    func testAutomaticNeverOverwritesManual() {
        let store = BellStore(inMemory: true)
        store.record(.missed, forCourse: "ECE 30864", at: start)
        store.record(.attended, forCourse: "ECE 30864", at: start, automatic: true)
        XCTAssertEqual(store.attendance(forCourse: "ECE 30864").first?.state, .missed)
    }

    func testTheUserCanCorrectAnAutomaticMark() {
        let store = BellStore(inMemory: true)
        store.record(.attended, forCourse: "ECE 30864", at: start, automatic: true)
        store.record(.excused, forCourse: "ECE 30864", at: start)
        let entry = store.attendance(forCourse: "ECE 30864").first
        XCTAssertEqual(entry?.state, .excused)
        XCTAssertEqual(entry?.wasAutomatic, false)
    }
}

// MARK: - Escalation

final class EscalationTests: XCTestCase {

    private var lab: ScheduleEngine.Occurrence { engine.occurrences(on: date(2026, 11, 2))[1] }   // 9:30 WALC

    func testThreeStepsAtTheRightTimes() {
        let alerts = Escalation.plan(for: lab, walkMinutes: 12, bufferMinutes: 5, now: date(2026, 11, 2, 6))
        XCTAssertEqual(alerts.map(\.level), [.headsUp, .leaveNow, .late])
        XCTAssertEqual(alerts.map(\.fireAt), [date(2026, 11, 2, 9, 3), date(2026, 11, 2, 9, 13),
                                              date(2026, 11, 2, 9, 20)])
        XCTAssertEqual(alerts.last?.body, "Leaving now gets you there about 2 minutes late.")
    }

    /// The running-late step used to fire at leave-now plus five, which with
    /// the default five-minute buffer is exactly on time, so it never sent.
    func testRunningLateFiresWithTheDefaultBuffer() {
        let alerts = Escalation.plan(for: lab, walkMinutes: 12, bufferMinutes: Preferences.leaveBuffer,
                                     now: date(2026, 11, 2, 6))
        XCTAssertTrue(alerts.contains { $0.level == .late })
    }

    func testNoWalkNoAlerts() {
        XCTAssertTrue(Escalation.plan(for: lab, walkMinutes: 0, bufferMinutes: 5, now: date(2026, 11, 2, 6)).isEmpty)
    }

    func testAlertsAlreadyDueAreDropped() {
        let alerts = Escalation.plan(for: lab, walkMinutes: 12, bufferMinutes: 5, now: date(2026, 11, 2, 9, 10))
        XCTAssertEqual(alerts.map(\.level), [.leaveNow, .late])
    }

    func testCoveredKeysComeBackFromIdentifiers() {
        let ids = Escalation.plan(for: lab, walkMinutes: 12, bufferMinutes: 5, now: date(2026, 11, 2, 6)).map(\.id)
        XCTAssertEqual(Escalation.coveredKeys(ids + ["brief-1", "bell-x"]), [lab.key])
    }

    func testDepartureReestimatesFromWhereYouLeft() {
        let alert = Escalation.onDeparture(for: lab, walkMinutes: 12, at: date(2026, 11, 2, 9, 25))
        XCTAssertEqual(alert?.title, "About 7 minutes late to ECE 30864")
        XCTAssertNil(Escalation.onDeparture(for: lab, walkMinutes: 12, at: date(2026, 11, 2, 9, 10)), "On time: say nothing")
        XCTAssertNil(Escalation.onDeparture(for: lab, walkMinutes: 12, at: date(2026, 11, 2, 10, 30)), "Class is over")
    }
}

// MARK: - Buildings

final class BuildingLocatorTests: XCTestCase {

    private let center = CLLocationCoordinate2D(latitude: 40.4274, longitude: -86.9132)

    func testQueryNamesTheCampus() {
        XCTAssertEqual(BuildingLocator.query(for: "ARMS"), "ARMS Purdue University")
    }

    func testCampusCenterIsTheMiddleOfWhatsKnown() throws {
        let c = try XCTUnwrap(BuildingLocator.campusCenter(Array(coordinates.values)))
        XCTAssertEqual(c.latitude, (40.4289 + 40.4274) / 2, accuracy: 0.00001)
        XCTAssertNil(BuildingLocator.campusCenter([]))
    }

    /// A search always returns something. A same-named place across the
    /// country must not become the building.
    func testFarAwayResultsAreRejected() {
        let elsewhere = (name: "ARMS", coordinate: CLLocationCoordinate2D(latitude: 39.77, longitude: -86.16))
        XCTAssertNil(BuildingLocator.pick([elsewhere], near: center))
    }

    func testNearestOnCampusResultWins() throws {
        let near = CLLocationCoordinate2D(latitude: 40.4310, longitude: -86.9150)
        let far = CLLocationCoordinate2D(latitude: 40.4450, longitude: -86.9300)
        let picked = try XCTUnwrap(BuildingLocator.pick([("a", far), ("b", near)], near: center))
        XCTAssertEqual(picked.latitude, near.latitude)
    }

    func testNoCampusToJudgeByMeansNoGuess() {
        XCTAssertNil(BuildingLocator.pick([("a", center)], near: nil))
    }

    func testLearningNeedsAnAccurateFixInsideAClassInAnUnknownBuilding() {
        let monday = engine.occurrences(on: date(2026, 11, 2))
        let inLab = date(2026, 11, 2, 9, 45)
        XCTAssertEqual(BuildingLocator.buildingToLearn(at: inLab, accuracy: 15, occurrences: monday,
                                                       isKnown: { _ in false }), "WALC")
        XCTAssertNil(BuildingLocator.buildingToLearn(at: inLab, accuracy: 80, occurrences: monday,
                                                     isKnown: { _ in false }), "Too vague to pin a building")
        XCTAssertNil(BuildingLocator.buildingToLearn(at: date(2026, 11, 2, 9, 32), accuracy: 15, occurrences: monday,
                                                     isKnown: { _ in false }), "Probably still walking up")
        XCTAssertNil(BuildingLocator.buildingToLearn(at: inLab, accuracy: 15, occurrences: monday,
                                                     isKnown: { _ in true }), "Already known")
    }
}

final class LearnedLocationTests: XCTestCase {

    private let code = "ZZTEST\(Int.random(in: 1000 ... 9999))"

    override func tearDown() {
        Campus.LearnedLocations.shared.forget(code)
    }

    /// Being there beats a search result.
    func testALookupNeverOverwritesAPositionMeasuredInTheBuilding() throws {
        let measured = CLLocationCoordinate2D(latitude: 40.43, longitude: -86.91)
        Campus.LearnedLocations.shared.record(measured, for: code, source: .observed)
        Campus.LearnedLocations.shared.record(.init(latitude: 40.50, longitude: -86.80), for: code, source: .lookedUp)
        XCTAssertEqual(try XCTUnwrap(Campus.coordinate(for: code)).latitude, 40.43)
        XCTAssertEqual(Campus.LearnedLocations.shared.source(for: code), .observed)
    }

    func testBeingThereImprovesOnALookup() throws {
        Campus.LearnedLocations.shared.record(.init(latitude: 40.50, longitude: -86.80), for: code, source: .lookedUp)
        Campus.LearnedLocations.shared.record(.init(latitude: 40.43, longitude: -86.91), for: code, source: .observed)
        XCTAssertEqual(try XCTUnwrap(Campus.coordinate(for: code)).latitude, 40.43)
    }

    func testLearnedBuildingsFeedWalkingTimes() {
        Campus.LearnedLocations.shared.record(.init(latitude: 40.4300, longitude: -86.9150), for: code, source: .observed)
        XCTAssertGreaterThan(Campus.walkingSeconds(from: "WALC", to: code), 0,
                             "A building Bell learned resolves without editing RoomCoordinates")
    }
}

// MARK: - Live Activity

final class ActivityPolicyTests: XCTestCase {

    func testTheClassYoureInComesFirst() {
        XCTAssertEqual(ActivityPolicy.occurrenceToShow(engine: engine, hidden: [], now: date(2026, 11, 2, 9, 40))?
            .event.course, "ECE 30864")
    }

    func testTheNextClassWithinThreeHours() {
        XCTAssertEqual(ActivityPolicy.occurrenceToShow(engine: engine, hidden: [], now: date(2026, 11, 2, 12, 45))?
            .event.course, "ECE 30200")
        XCTAssertNil(ActivityPolicy.occurrenceToShow(engine: engine, hidden: [], now: date(2026, 11, 2, 11)),
                     "Four and a half hours out is too early for the lock screen")
    }

    func testHiddenCoursesNeverShow() {
        XCTAssertNil(ActivityPolicy.occurrenceToShow(engine: engine, hidden: ["ECE 30864"], now: date(2026, 11, 2, 9, 40)))
    }

    /// The progress bar used to run from whenever the activity was rendered,
    /// so one started mid-lecture showed the class as just beginning.
    func testTheActivityRangeIsTheClassItself() {
        let attributes = ClassActivityAttributes(startedAt: date(2026, 11, 2, 9, 30), colorComponents: [0, 0, 0])
        let state = ClassActivityAttributes.ContentState(courseCode: "ECE 30864", room: "WALC 2088",
                                                         endsAt: date(2026, 11, 2, 10, 20))
        XCTAssertEqual(attributes.classRange(state), date(2026, 11, 2, 9, 30) ... date(2026, 11, 2, 10, 20))
    }
}

final class NotABuildingTests: XCTestCase {

    /// An online section's room is "REMOTE", which was watched, looked up and
    /// walked to as if it were a building.
    func testRemoteAndPlaceholderRoomsHaveNoBuilding() {
        for room in ["REMOTE", "Online", "TBA", "ARR ARR"] {
            let event = ClassEvent(course: "X", room: room, dayIndex: 0, startSecond: 0, endSecond: 60, weekIndex: 0)
            XCTAssertNil(event.building, room)
        }
        XCTAssertEqual(ClassEvent(course: "X", room: "WALC 1018", dayIndex: 0, startSecond: 0, endSecond: 60,
                                  weekIndex: 0).building, "WALC")
    }
}

final class MonitorNameTests: XCTestCase {

    /// CLMonitor raises an uncaught exception, not an error, for a name it
    /// doesn't accept. "bell.buildings" crashed every launch with monitoring on.
    func testMonitorNameIsLettersAndDigitsOnly() {
        XCTAssertTrue(LocationServices.monitorName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
}

final class LocationInfoPlistTests: XCTestCase {

    /// Without it, asking for "always" silently does nothing.
    func testDeclaresWhyItWantsAlwaysLocation() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertFalse((info["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String ?? "").isEmpty)
    }
}
