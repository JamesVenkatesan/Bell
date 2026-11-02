import XCTest
@testable import Bell

/// The importer reads a file produced by someone else's app. Everything here
/// is about what happens when that file isn't what we expect, because that's
/// the case that reaches users.
final class ImporterTests: XCTestCase {

    private func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """.utf8)
    }

    private let oneEvent = """
        <key>WeekEvents</key>
        <array>
            <dict>
                <key>title</key><string>ECE 36200</string>
                <key>info</key><string>WTHR 200</string>
                <key>dayNum</key><integer>0</integer>
                <key>time</key><real>27000</real>
                <key>endTime</key><real>30000</real>
                <key>weekNum</key><integer>0</integer>
            </dict>
        </array>
        <key>Settings</key>
        <dict>
            <key>NumberOfWeeks</key><integer>1</integer>
            <key>WeekendDaysAreActive</key><false/>
        </dict>
        """

    // MARK: - Happy path

    func testDecodesSecondsSinceMidnight() throws {
        let table = try TimetableImporter.timetable(fromPropertyList: plist(oneEvent))

        XCTAssertEqual(table.events.count, 1)
        let event = table.events[0]
        XCTAssertEqual(event.course, "ECE 36200")
        XCTAssertEqual(event.room, "WTHR 200")
        XCTAssertEqual(event.dayIndex, 0, "dayNum 0 is Monday")
        XCTAssertEqual(event.startSecond, 27000, "07:30")
        XCTAssertEqual(event.endSecond, 30000, "08:20")
    }

    func testBuildingIsTheFirstTokenOfTheRoom() throws {
        let table = try TimetableImporter.timetable(fromPropertyList: plist(oneEvent))
        XCTAssertEqual(table.events[0].building, "WTHR")
    }

    func testEmptyRoomHasNoBuilding() {
        let event = ClassEvent(course: "SOC 10000", room: "", dayIndex: 2,
                               startSecond: 0, endSecond: 60, weekIndex: 0)
        XCTAssertNil(event.building)
    }

    // MARK: - Course families
    //
    // Lab sections have to resolve to their lecture so the two share a colour.

    func testLabSectionSharesItsLectureFamily() {
        let lecture = ClassEvent(course: "ECE 30864", room: "", dayIndex: 0,
                                 startSecond: 0, endSecond: 1, weekIndex: 0)
        let lab = ClassEvent(course: "ECE 30864L", room: "", dayIndex: 0,
                             startSecond: 0, endSecond: 1, weekIndex: 0)
        XCTAssertEqual(lecture.courseFamily, lab.courseFamily)
    }

    func testTeachingPrefixIsStrippedFromFamily() {
        let ta = ClassEvent(course: "TA: ECE 36800", room: "", dayIndex: 0,
                            startSecond: 0, endSecond: 1, weekIndex: 0)
        XCTAssertEqual(ta.courseFamily, "ECE 36800")
        XCTAssertTrue(ta.isTeaching)
    }

    func testTrailingLetterIsOnlyStrippedAfterADigit() {
        // "WALC" must not become "WAL" — the rule applies to section suffixes,
        // not to any word ending in L.
        let event = ClassEvent(course: "MATH CALCL", room: "", dayIndex: 0,
                               startSecond: 0, endSecond: 1, weekIndex: 0)
        XCTAssertEqual(event.courseFamily, "MATH CALCL")
    }

    // MARK: - Malformed input

    func testMissingWeekEventsYieldsAnEmptyTimetable() throws {
        let table = try TimetableImporter.timetable(
            fromPropertyList: plist("<key>Settings</key><dict/>"))
        XCTAssertTrue(table.events.isEmpty)
    }

    func testGarbageThrowsRatherThanReturningNonsense() {
        XCTAssertThrowsError(
            try TimetableImporter.timetable(fromPropertyList: Data("not a plist".utf8)))
    }

    func testMissingRoomIsToleratedNotFatal() throws {
        let body = oneEvent.replacingOccurrences(
            of: "<key>info</key><string>WTHR 200</string>", with: "")
        let table = try TimetableImporter.timetable(fromPropertyList: plist(body))
        XCTAssertEqual(table.events.count, 1)
        XCTAssertEqual(table.events[0].room, "")
    }
}

/// The palette's whole purpose is staying legible when the system throws hue
/// away, so the property worth testing is luminance separation.
final class PaletteTests: XCTestCase {

    func testAssignedColoursAreDistinguishableByBrightnessAlone() {
        let courses = ["ECE 20869", "ECE 30100", "ECE 30200",
                       "ECE 30864", "ECE 36200", "SOC 10000"]
        let assignment = Palette.assign(courses: courses)

        let luminances = assignment.values
            .map(Palette.relativeLuminance)
            .sorted()

        for (a, b) in zip(luminances, luminances.dropFirst()) {
            XCTAssertGreaterThan(b - a, 0.02,
                                 "Two courses collapse to the same grey when tinted")
        }
    }

    func testLabInheritsItsLectureColour() {
        let assignment = Palette.assign(courses: ["ECE 30864", "ECE 30864L"])
        XCTAssertEqual(assignment["ECE 30864"], assignment["ECE 30864L"])
    }

    func testAssignmentIsDeterministicAcrossProcesses() {
        // The app and the widget compute this independently and must agree.
        let courses = ["ECE 30200", "ECE 36200", "SOC 10000"]
        XCTAssertEqual(Palette.assign(courses: courses),
                       Palette.assign(courses: courses.reversed()))
    }

    func testEmptyInputDoesNotCrash() {
        XCTAssertTrue(Palette.assign(courses: []).isEmpty)
    }
}
