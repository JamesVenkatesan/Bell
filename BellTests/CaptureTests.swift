import XCTest
@testable import Bell

/// The deterministic parser is the half of capture that can be tested without
/// a model, and it's also the half that decides confidence. If it drifts, the
/// cross-check it provides becomes worthless silently.
final class HeuristicParserTests: XCTestCase {

    // MARK: - Real registrar rows

    func testParsesAUniTimeSectionRow() {
        let line = "ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25-12/10 BHEE 170 I Lin 3 G"
        let events = HeuristicParser.events(fromLine: line)

        XCTAssertEqual(events.count, 2, "TR is two meetings")
        XCTAssertEqual(events.map(\.event.dayIndex), [1, 3], "Tuesday and Thursday")

        let first = events[0].event
        XCTAssertEqual(first.course, "ECE 30100")
        XCTAssertEqual(first.room, "BHEE 170")
        XCTAssertEqual(first.startSecond, 7 * 3600 + 30 * 60)
        XCTAssertEqual(first.endSecond, 8 * 3600 + 45 * 60)
    }

    func testThreeDayCodeProducesThreeMeetings() {
        let line = "ECE 30200 Lec 17104-003 MWF 3:30p 4:20p WALC 1018"
        let events = HeuristicParser.events(fromLine: line)

        XCTAssertEqual(events.map(\.event.dayIndex), [0, 2, 4])
        XCTAssertEqual(events[0].event.startSecond, 15 * 3600 + 30 * 60, "3:30p is 15:30")
        XCTAssertEqual(events[0].event.endSecond, 16 * 3600 + 20 * 60)
    }

    // MARK: - The R-is-Thursday convention

    func testRMeansThursday() {
        let events = HeuristicParser.events(
            fromLine: "ECE 30864 Lab 20243-003 R 9:30a 11:20a BHEE 206")
        XCTAssertEqual(events.map(\.event.dayIndex), [3])
    }

    // MARK: - Course and room disambiguation
    //
    // Both are "LETTERS NUMBER". Getting this backwards swaps every room and
    // course in the import, which is the single worst failure available here.

    func testRoomIsTheSecondCodeOnTheLine() {
        let line = "ECE 36200 Lec MWF 7:30a 8:20a WTHR 200"
        XCTAssertEqual(HeuristicParser.courseCode(in: line), "ECE 36200")
        XCTAssertEqual(HeuristicParser.roomCode(in: line, excluding: "ECE 36200"), "WTHR 200")
    }

    func testCourseWithNoSpaceStillParses() {
        XCTAssertEqual(HeuristicParser.courseCode(in: "MA261 MWF 9:30a 10:20a"), "MA 261")
    }

    // MARK: - Times

    func testTwelveHourMidnightAndNoonAreNotConfused() {
        let noon = HeuristicParser.timePair(in: "X 12:00p 12:50p")
        XCTAssertEqual(noon?.start, 12 * 3600, "12pm is noon, not midnight")

        let morning = HeuristicParser.timePair(in: "X 12:30a 1:20a")
        XCTAssertEqual(morning?.start, 30 * 60, "12:30am is 00:30")
    }

    func testMissingPMOnTheEndTimeIsRecovered() {
        // "11:30 - 1:20" can only mean 13:20.
        let pair = HeuristicParser.timePair(in: "ECE 101 MWF 11:30 1:20 ROOM 1")
        XCTAssertEqual(pair?.start, 11 * 3600 + 30 * 60)
        XCTAssertEqual(pair?.end, 13 * 3600 + 20 * 60)
    }

    func testImplausiblyLongBlockIsRejected() {
        XCTAssertNil(HeuristicParser.timePair(in: "X 8:00a 11:00p"),
                     "Fifteen hours is a parse error, not a class")
    }

    // MARK: - Things that must not parse

    func testHeaderRowsProduceNothing() {
        XCTAssertTrue(HeuristicParser.events(
            fromLine: "Subject Course Type CRN Days Start End Room").isEmpty)
    }

    func testALineWithNoTimesProducesNothing() {
        XCTAssertTrue(HeuristicParser.events(fromLine: "ECE 30100 MWF BHEE 170").isEmpty)
    }

    func testCourseCodeAloneIsNotADayToken() {
        // "MA 261" starts with M; without times on the line it must not
        // register as a Monday class.
        XCTAssertTrue(HeuristicParser.events(fromLine: "MA 261 Calculus III").isEmpty)
    }

    // MARK: - Whole documents

    func testDuplicateRowsAcrossPagesCollapse() {
        let text = """
            ECE 36200 Lec MWF 7:30a 8:20a WTHR 200
            ECE 36200 Lec MWF 7:30a 8:20a WTHR 200
            """
        XCTAssertEqual(HeuristicParser.parse(text).count, 3, "Three days, not six")
    }
}

/// Reconciliation decides what gets auto-accepted, so its edges matter more
/// than they look.
final class ReconciliationTests: XCTestCase {

    private func event(_ course: String, _ room: String, _ day: Int,
                       _ start: Int = 27000, _ end: Int = 30000) -> ClassEvent {
        ClassEvent(course: course, room: room, dayIndex: day,
                   startSecond: start, endSecond: end, weekIndex: 0)
    }

    func testFullAgreementIsNearCertain() {
        let shared = [ParsedEvent(event: event("ECE 36200", "WTHR 200", 0))]
        let merged = ScheduleCapture.reconcile(deterministic: shared, intelligent: shared)

        XCTAssertEqual(merged.count, 1)
        XCTAssertGreaterThan(merged[0].confidence, 0.9)
    }

    func testDisagreementOnRoomIsFlaggedNotAveraged() {
        let regex = [ParsedEvent(event: event("ECE 36200", "WTHR 200", 0))]
        let model = [ParsedEvent(event: event("ECE 36200", "WTHR 2OO", 0))]

        let merged = ScheduleCapture.reconcile(deterministic: regex, intelligent: model)

        XCTAssertEqual(merged.count, 1, "Same meeting, not two")
        XCTAssertEqual(merged[0].event.room, "WTHR 200", "The regex wins on room")
        XCTAssertLessThan(merged[0].confidence, 0.8)
        XCTAssertTrue(merged[0].uncertainFields.contains(.room))
    }

    func testModelOnlyRowsSurviveButRankLower() {
        let model = [ParsedEvent(event: event("SOC 10000", "", 2))]
        let merged = ScheduleCapture.reconcile(deterministic: [], intelligent: model)

        XCTAssertEqual(merged.count, 1)
        XCTAssertLessThan(merged[0].confidence, 0.6, "Unverified by a second method")
    }

    func testWithoutAModelRowsAreLikelyNotCertain() {
        let regex = [ParsedEvent(event: event("ECE 36200", "WTHR 200", 0))]
        let merged = ScheduleCapture.reconcile(deterministic: regex, intelligent: [])

        XCTAssertEqual(merged[0].confidence, 0.75, accuracy: 0.01)
        XCTAssertLessThan(merged[0].confidence, 0.9,
                          "One parser alone must not auto-accept")
    }
}

/// The diff is the safety mechanism. Its defaults are the feature.
final class ScheduleDiffTests: XCTestCase {

    private func event(_ course: String, _ room: String, _ day: Int,
                       _ start: Int = 27000, _ end: Int = 30000) -> ClassEvent {
        ClassEvent(course: course, room: room, dayIndex: day,
                   startSecond: start, endSecond: end, weekIndex: 0)
    }

    func testIdenticalScheduleProducesNoChanges() {
        let current = [event("A", "R 1", 0), event("B", "R 2", 1)]
        let incoming = current.map { ParsedEvent(event: $0) }

        let diff = ScheduleDiff.between(current: current, incoming: incoming)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.unchanged.count, 2)
    }

    func testRoomChangeReadsAsAChangeNotADeleteAndAdd() {
        let current = [event("A", "OLD 1", 0)]
        let incoming = [ParsedEvent(event: event("A", "NEW 2", 0))]

        let diff = ScheduleDiff.between(current: current, incoming: incoming)
        XCTAssertEqual(diff.changes.count, 1)
        if case .relocated(let from) = diff.changes[0].kind {
            XCTAssertEqual(from, "OLD 1")
        } else {
            XCTFail("Expected a relocation")
        }
    }

    func testRemovalsAreNeverAcceptedByDefault() {
        let current = [event("A", "R 1", 0), event("B", "R 2", 1)]
        let incoming = [ParsedEvent(event: event("A", "R 1", 0))]

        let diff = ScheduleDiff.between(current: current, incoming: incoming)
        let removal = diff.changes.first { $0.kind.warrantsAttention }

        XCTAssertNotNil(removal, "B went missing and that must be surfaced")
        XCTAssertFalse(removal!.isAccepted, "A missed class must never be dropped silently")
    }

    func testRejectedRemovalKeepsTheClass() {
        let current = [event("A", "R 1", 0), event("B", "R 2", 1)]
        let incoming = [ParsedEvent(event: event("A", "R 1", 0))]

        let diff = ScheduleDiff.between(current: current, incoming: incoming)
        let resolved = diff.resolved(from: current)

        XCTAssertEqual(resolved.count, 2, "Unticked removal leaves the class in place")
    }

    func testLowConfidenceAdditionsStartUnticked() {
        let incoming = [ParsedEvent(event: event("NEW", "R 1", 0), confidence: 0.55)]
        let diff = ScheduleDiff.between(current: [], incoming: incoming)

        XCTAssertFalse(diff.changes[0].isAccepted)
        XCTAssertTrue(diff.needsAttention)
    }

    func testHighConfidenceAdditionsAreReady() {
        let incoming = [ParsedEvent(event: event("NEW", "R 1", 0), confidence: 0.98)]
        let diff = ScheduleDiff.between(current: [], incoming: incoming)

        XCTAssertTrue(diff.changes[0].isAccepted)
    }
}

/// Calendar feeds are the exact path, so the tests here are about format
/// handling rather than inference.
final class ICSImporterTests: XCTestCase {

    private let feed = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:ECE 36200 Lec
        LOCATION:WTHR 200
        DTSTART;TZID=America/Indianapolis:20260824T073000
        DTEND;TZID=America/Indianapolis:20260824T082000
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261211T235959Z
        END:VEVENT
        END:VCALENDAR
        """

    func testExpandsWeeklyRecurrenceIntoDays() throws {
        let table = try ICSImporter.timetable(fromICS: feed)

        XCTAssertEqual(table.events.count, 3)
        XCTAssertEqual(table.events.map(\.dayIndex), [0, 2, 4])
        XCTAssertEqual(table.events[0].room, "WTHR 200")
        XCTAssertEqual(table.events[0].startSecond, 7 * 3600 + 30 * 60)
    }

    func testTermEndComesFromTheRecurrenceUntil() throws {
        let table = try ICSImporter.timetable(fromICS: feed)
        XCTAssertNotNil(table.termEnd)

        let components = Calendar.current.dateComponents([.year, .month],
                                                         from: table.termEnd!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 12)
    }

    func testSectionTypeBecomesBellsSuffixConvention() {
        XCTAssertEqual(ICSImporter.courseName(from: "ECE 36200 Lec"), "ECE 36200")
        XCTAssertEqual(ICSImporter.courseName(from: "ECE 36200 Lab"), "ECE 36200L")
        XCTAssertEqual(ICSImporter.courseName(from: "ECE 30864 LabP"), "ECE 30864L")
    }

    func testFoldedLinesAreRejoined() throws {
        let folded = feed.replacingOccurrences(
            of: "SUMMARY:ECE 36200 Lec",
            with: "SUMMARY:ECE 36200\n  Lec")
        let table = try ICSImporter.timetable(fromICS: folded)
        XCTAssertEqual(table.events.first?.course, "ECE 36200")
    }

    func testNonCalendarDataThrows() {
        XCTAssertThrowsError(try ICSImporter.timetable(fromICS: "<html>nope</html>"))
    }

    // MARK: Purdue's real feed shape

    func testInstructorComesFromTheOrganizer() {
        XCTAssertEqual(ICSImporter.instructor(organizer: #"ORGANIZER;CN="Diyab, Eman Samy Ahmed (Instr)""#,
                                              description: "Lecture"), "E S A Diyab")
        XCTAssertEqual(ICSImporter.instructor(organizer: #"ORGANIZER;CN="Galarza Tohen, Beatriz (Instr)""#,
                                              description: "Studio"), "B Galarza Tohen")
    }

    func testDescriptionIsAFallbackOnlyWhenItIsAName() {
        XCTAssertEqual(ICSImporter.instructor(organizer: nil, description: "Lin, I"), "I Lin")
        XCTAssertNil(ICSImporter.instructor(organizer: nil, description: "Laboratory"),
                     "A section type is not a person")
        XCTAssertNil(ICSImporter.instructor(organizer: nil, description: nil))
    }

    func testCRNSummaryBecomesTheSameCourseCodeAsAPDF() {
        XCTAssertEqual(ICSImporter.courseName(from: "CS 15900 12941-LE5", sectionType: "Lecture"), "CS 15900")
        XCTAssertEqual(ICSImporter.courseName(from: "CS 15900 12973-L51", sectionType: "Laboratory"), "CS 15900L")
        XCTAssertEqual(ICSImporter.courseName(from: "MA 26100 13697-242", sectionType: "Recitation"), "MA 26100R")
    }

    func testEscapedTextIsDecoded() {
        XCTAssertEqual(ICSImporter.unescape(#"LMBS 3261A\, LMBS 3261B"#), "LMBS 3261A, LMBS 3261B")
    }

    /// The real export, end to end: every class gets a clean course code, a
    /// room and an instructor, like the PDF path.
    func testRealUniTimeFeedProducesTheSameFieldsAsAPDF() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "unitime-2024", withExtension: "ics"),
                                "Fixture unitime-2024.ics missing: it's gitignored, copy it into BellTests/Fixtures")
        let table = try ICSImporter.timetable(fromICS: String(contentsOf: url, encoding: .utf8))
        let byCourse = Dictionary(table.events.map { ($0.course, $0) }, uniquingKeysWith: { a, _ in a })

        XCTAssertEqual(Set(byCourse.keys), ["CS 15900", "CS 15900L", "MA 26100", "MA 26100R", "SCLA 10200", "ENGR 13100"])
        XCTAssertEqual(byCourse["CS 15900"]?.instructor, "E S A Diyab")
        XCTAssertEqual(byCourse["CS 15900"]?.room, "SMTH 108")
        XCTAssertEqual(byCourse["MA 26100R"]?.instructor, "J A Manuel")
        XCTAssertEqual(byCourse["ENGR 13100"]?.room, "LMBS 3261A, LMBS 3261B")
        XCTAssertTrue(table.events.allSatisfy { $0.instructor != nil && !$0.room.isEmpty })
    }
}

/// The table reader is the path that matters most, because it's the one a real
/// registrar PDF takes. These lock down the two things that actually broke it:
/// whitespace in extracted text, and left-aligned column bounds.
final class TableReaderTests: XCTestCase {

    // Flattened text from three real UniTime exports. The wrapping differs in
    // each, which is the entire point: the token order survives wrapping even
    // though the line structure does not.

    /// Room adjacent to its building, date range before it.
    private let currentFormat = """
        Subject  Course  Type  CRN-SectionId  Days  Start  End  Date  Room  Instructor
        ECE  30100  Lec  17727-002  TR  7:30a  8:45a  08/25  -  BHEE  170  I  Lin  3  G
        12/10
        ECE  30200  Lec  17104-003  MWF  3:30p  4:20p  08/24  -  WALC  1018  A  R  Reibman  3  G
        12/11
        ECE  30864  Lab  20243-003  R  9:30a  11:20a  08/27  -  BHEE  206  M  C  Ruiz,  S  P  1  G
        12/10  France
        LabP  20239-001  M  9:30a  10:20a  08/24  -  WALC  2088  S  P  France,  M  G
        12/07  Ikram
        SOC  10000DIST  Dist  30336-065  Arrange  Hours  08/24  -  ASYNC  S  L  Feld  Distance  3  G
        (Online)  12/12  ONLINE
        """

    /// An older export where the room splits across the wrap: "BHEE" lands on
    /// one line and "170" several tokens later, after the instructor.
    private let wrappedFormat = """
        ECE  30100  Lec  17727-002  TR  7:30a  8:45a  08/25  BHEE  I  Lin  3  G  -  170  12/10
        ECE  36200  Lec  17750-001  MWF  7:30a  8:20a  08/24  WTHR  Y  Kim  4  G  -  200  12/11
        """

    // MARK: - The real thing

    func testReadsEverySectionFromTheCurrentFormat() {
        let records = TableReader.records(in: currentFormat)
        XCTAssertEqual(records.count, 5, "Five CRNs, five sections")
    }

    func testFieldsAreExact() {
        let events = TableReader.read(currentFormat)
        let lecture = events.first { $0.event.course == "ECE 30100" }

        XCTAssertNotNil(lecture)
        XCTAssertEqual(lecture?.event.room, "BHEE 170")
        XCTAssertEqual(lecture?.event.startSecond, 7 * 3600 + 30 * 60)
        XCTAssertEqual(lecture?.event.endSecond, 8 * 3600 + 45 * 60)
    }

    func testTRBecomesTwoMeetings() {
        let events = TableReader.read(currentFormat)
            .filter { $0.event.course == "ECE 30100" }
        XCTAssertEqual(events.map(\.event.dayIndex), [1, 3])
    }

    func testLabInheritsTheCourseItSitsUnder() {
        // The LabP row carries a CRN but repeats neither subject nor number.
        let labs = TableReader.read(currentFormat)
            .filter { $0.event.course.hasSuffix("L") }

        XCTAssertEqual(labs.count, 2, "Lab on Thursday, LabP on Monday")
        XCTAssertTrue(labs.allSatisfy { $0.event.course == "ECE 30864L" })
    }

    func testLabPTakesItsOwnRoomNotItsLecturesRoom() {
        let monday = TableReader.read(currentFormat)
            .first { $0.event.course == "ECE 30864L" && $0.event.dayIndex == 0 }
        XCTAssertEqual(monday?.event.room, "WALC 2088")
    }

    func testArrangedOnlineSectionProducesNoMeeting() {
        // "S L Feld" must not read as Saturday, and an async section must not
        // appear on the grid at all.
        let soc = TableReader.read(currentFormat).filter { $0.event.course.hasPrefix("SOC") }
        XCTAssertTrue(soc.isEmpty)
    }

    // MARK: - Wrapping

    func testRoomSplitAcrossAWrapIsStillFound() {
        let events = TableReader.read(wrappedFormat)
        XCTAssertEqual(events.first { $0.event.course == "ECE 30100" }?.event.room, "BHEE 170")
        XCTAssertEqual(events.first { $0.event.course == "ECE 36200" }?.event.room, "WTHR 200")
    }

    func testCreditCountIsNotMistakenForARoom() {
        // "3 G" sits between the building and its number in the wrapped form.
        // A one-digit number is a credit count, never a room.
        XCTAssertFalse(TableReader.isRoomNumber("3"))
        XCTAssertTrue(TableReader.isRoomNumber("170"))
    }

    // MARK: - Token classification

    func testBuildingCodesAreDistinguishedFromDayTokens() {
        XCTAssertTrue(TableReader.isBuildingCode("WTHR"), "H is not a day letter")
        XCTAssertTrue(TableReader.isBuildingCode("WALC"))
        XCTAssertTrue(TableReader.isBuildingCode("UC"))
        XCTAssertFalse(TableReader.isBuildingCode("TR"))
        XCTAssertFalse(TableReader.isBuildingCode("MWF"))
    }

    func testSectionTypeBecomesTheSuffixConvention() {
        XCTAssertEqual(TableReader.sectionSuffix("Lab"), "L")
        XCTAssertEqual(TableReader.sectionSuffix("LabP"), "L")
        XCTAssertEqual(TableReader.sectionSuffix("Lec"), "")
        XCTAssertEqual(TableReader.sectionSuffix("Dist"), "D")
    }

    func testRIsThursdayNotTuesday() {
        XCTAssertEqual(TableReader.dayIndices("R"), [3])
        XCTAssertEqual(TableReader.dayIndices("TR"), [1, 3])
        XCTAssertEqual(TableReader.dayIndices("MWF"), [0, 2, 4])
    }

    func testClockHandlesRegistrarShorthand() {
        XCTAssertEqual(TableReader.clockSeconds("7:30a"), 7 * 3600 + 30 * 60)
        XCTAssertEqual(TableReader.clockSeconds("3:30p"), 15 * 3600 + 30 * 60)
        XCTAssertEqual(TableReader.clockSeconds("12:30p"), 12 * 3600 + 30 * 60)
        XCTAssertEqual(TableReader.clockSeconds("12:30a"), 30 * 60)
    }

    func testTextWithNoCRNsYieldsNothing() {
        XCTAssertTrue(TableReader.read("ECE 30100 meets Tuesdays at half seven").isEmpty)
    }

    func testTableRowsOutrankInference() {
        let events = TableReader.read(currentFormat)
        XCTAssertTrue(events.allSatisfy { $0.confidence > 0.9 })
    }
}

/// Grid reading is approximate by nature. The tests assert that it says so.
final class GridReaderTests: XCTestCase {

    func testHourLabelsParse() {
        XCTAssertEqual(GridReader.TimeAxis.hourLabel("7am"), 7 * 3600)
        XCTAssertEqual(GridReader.TimeAxis.hourLabel("12pm"), 12 * 3600)
        XCTAssertEqual(GridReader.TimeAxis.hourLabel("12am"), 0)
        XCTAssertEqual(GridReader.TimeAxis.hourLabel("5pm"), 17 * 3600)
        XCTAssertNil(GridReader.TimeAxis.hourLabel("Monday"))
    }

    func testCourseCodeToleratesDoubleSpacing() {
        // Extracted text separates tokens with two spaces. A `\s?` pattern
        // matched none of it, which is what made every import wrong.
        XCTAssertEqual(GridReader.courseCode(in: "ECE  30100  Lec"), "ECE 30100")
        XCTAssertEqual(GridReader.courseCode(in: "ECE 30100 Lec"), "ECE 30100")
    }
}

/// Regression tests for the day-token / building-code collision.
///
/// "TR 7:30a" has the exact shape of a room: letters, a space, digits. It was
/// being read as room "TR 7", which meant every imported class carried a
/// nonsense location. Two guards fix it, and both are easy to undo by
/// accident, so both are pinned here.
final class RoomDisambiguationTests: XCTestCase {

    func testDayTokenFollowedByATimeIsNotARoom() {
        let line = "ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25-12/10 BHEE 170 I Lin 3 G"
        XCTAssertEqual(HeuristicParser.roomCode(in: line, excluding: "ECE 30100"), "BHEE 170")
    }

    func testThreeDayTokenFollowedByATimeIsNotARoom() {
        let line = "ECE 36200 Lec MWF 7:30a 8:20a WTHR 200"
        XCTAssertEqual(HeuristicParser.roomCode(in: line, excluding: "ECE 36200"), "WTHR 200")
    }

    func testBuildingsMadeOfDayLettersStillParse() {
        // WTHR is W, T, H, R — the H is what makes it a building and not a
        // day token. The rule has to be "only day letters", not "any".
        XCTAssertFalse(HeuristicParser.isDayTokenNotBuilding("WTHR"))
        XCTAssertFalse(HeuristicParser.isDayTokenNotBuilding("WALC"))
        XCTAssertFalse(HeuristicParser.isDayTokenNotBuilding("UC"))
        XCTAssertFalse(HeuristicParser.isDayTokenNotBuilding("BHEE"))

        XCTAssertTrue(HeuristicParser.isDayTokenNotBuilding("TR"))
        XCTAssertTrue(HeuristicParser.isDayTokenNotBuilding("MWF"))
        XCTAssertTrue(HeuristicParser.isDayTokenNotBuilding("M"))
    }

    func testFullRowStillResolvesCourseAndRoomCorrectly() {
        let events = HeuristicParser.events(
            fromLine: "ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25-12/10 BHEE 170 I Lin 3 G")

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event.course, "ECE 30100")
        XCTAssertEqual(events[0].event.room, "BHEE 170")
    }
}

/// Extraction fidelity.
///
/// The failure these exist for: words were being rebuilt from character boxes
/// and split mid-word, so "ECE" arrived as "CE", "WALC 2088" as "WALC 20", and
/// a broken CRN made a whole section disappear. Tokens are the anchor for
/// everything downstream, so a corrupted token is not a cosmetic problem.
final class ExtractionFidelityTests: XCTestCase {

    func testRawTextIsPreferredOverRebuiltFragments() {
        // Deliberately broken fragments next to correct raw text: the raw text
        // must win, because the source knows its own words.
        let page = TextExtraction.Page(
            fragments: [
                TextExtraction.Fragment(text: "CE", frame: .zero, confidence: 1),
                TextExtraction.Fragment(text: "3086", frame: .zero, confidence: 1),
            ],
            index: 0,
            rawText: "ECE 30864 Lab 20243-003 R 9:30a 11:20a BHEE 206")

        XCTAssertTrue(page.plainText.contains("ECE 30864"))
        XCTAssertFalse(page.plainText.hasPrefix("CE"))
    }

    func testFragmentsAreUsedWhenThereIsNoRawText() {
        let page = TextExtraction.Page(
            fragments: [TextExtraction.Fragment(
                text: "ECE 30100", frame: CGRect(x: 0, y: 0, width: 0.2, height: 0.01),
                confidence: 1)],
            index: 0)

        XCTAssertEqual(page.plainText, "ECE 30100")
    }

    func testATruncatedCRNLosesItsWholeSection() {
        // Documents the blast radius: corrupt the anchor and the section is
        // gone entirely, which is exactly what happened to ECE 30100.
        let intact = "ECE 30100 Lec 17727-002 TR 7:30a 8:45a BHEE 170"
        let broken = "ECE 30100 Lec 1772 7-002 TR 7:30a 8:45a BHEE 170"

        XCTAssertEqual(TableReader.read(intact).count, 2)
        XCTAssertTrue(TableReader.read(broken).isEmpty)
    }
}

/// Instructor parsing is best-effort and deliberately conservative.
final class InstructorTests: XCTestCase {

    func testReadsASingleInstructor() {
        let events = TableReader.read(
            "ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25 - BHEE 170 I Lin 3 G")
        XCTAssertEqual(events.first?.event.instructor, "I Lin")
    }

    func testReadsSeveralInstructors() {
        let events = TableReader.read(
            "ECE 30864 Lab 20243-003 R 9:30a 11:20a 08/27 - BHEE 206 M C Ruiz, S P France 1 G")
        XCTAssertEqual(events.first?.event.instructor, "M C Ruiz, S P France")
    }

    func testCreditCountEndsTheName() {
        let events = TableReader.read(
            "ECE 30200 Lec 17104-003 MWF 3:30p 4:20p 08/24 - WALC 1018 A R Reibman 3 G")
        XCTAssertEqual(events.first?.event.instructor, "A R Reibman")
    }

    func testInstructorIsNotPartOfIdentity() {
        // A staffing change must read as a change, never as a dropped class.
        let before = ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 1,
                                startSecond: 27000, endSecond: 31500, weekIndex: 0,
                                instructor: "I Lin")
        let after = ClassEvent(course: "ECE 30100", room: "BHEE 170", dayIndex: 1,
                               startSecond: 27000, endSecond: 31500, weekIndex: 0,
                               instructor: "Someone Else")

        let diff = ScheduleDiff.between(current: [before],
                                        incoming: [ParsedEvent(event: after)])
        XCTAssertTrue(diff.changes.isEmpty, "Same meeting, different staff")
    }
}

/// Tokenizing glued text.
///
/// PDF extraction does not reliably put spaces between table columns. A real
/// row arrives as "08/25 -12/10BHEE 170I Lin", where splitting on whitespace
/// yields "12/10BHEE" and the room is simply not there. Every one of these
/// pins a shape the lexer has to recognise without separators.
final class TokenizerTests: XCTestCase {

    func testSplitsColumnsWithNoSpacesBetweenThem() {
        let tokens = TableReader.tokenize("08/25 -12/10BHEE 170I Lin")
        XCTAssertEqual(tokens, ["08/25", "12/10", "BHEE", "170", "I", "Lin"])
    }

    func testKeepsClockTimesWhole() {
        let tokens = TableReader.tokenize("TR7:30a8:45a")
        XCTAssertEqual(tokens, ["TR", "7:30a", "8:45a"])
    }

    func testKeepsCRNsWhole() {
        XCTAssertEqual(TableReader.tokenize("Lec17727-002TR"), ["Lec", "17727-002", "TR"])
    }

    func testSeparatesSubjectFromCourseNumber() {
        XCTAssertEqual(TableReader.tokenize("ECE30100Lec"), ["ECE", "30100", "Lec"])
    }

    func testOrdinarySpacedTextIsUnaffected() {
        XCTAssertEqual(TableReader.tokenize("ECE 30100 Lec"), ["ECE", "30100", "Lec"])
    }

    // MARK: - Glued subjects

    func testSubjectGluedToThePreviousRowsGradeFlagIsRecovered() {
        // "3 G" ends one row and "ECE" starts the next, arriving as "GECE".
        // Structure, not frequency: a real subject never ends with another
        // real subject, so the suffix is the subject.
        let known: Set<String> = ["ECE", "SOC"]
        XCTAssertEqual(TableReader.subject(from: "GECE", known: known), "ECE")
        XCTAssertEqual(TableReader.subject(from: "MdECE", known: known), "ECE")
        XCTAssertEqual(TableReader.subject(from: "ECE", known: known), "ECE")
        XCTAssertEqual(TableReader.subject(from: "SOC", known: known), "SOC",
                       "A genuinely rare subject is still itself")
    }

    func testKnownSubjectsComeFromCleanOccurrences() {
        let tokens = TableReader.tokenize("ECE 30100 Lec 17727-002 GECE 30200 Lec 17104-003")
        XCTAssertTrue(TableReader.knownSubjects(in: tokens).contains("ECE"))
    }

    // MARK: - End to end on glued text

    func testGluedRowYieldsRoomAndInstructor() {
        let glued = "ECE30100Lec17727-002TR7:30a8:45a08/25 -12/10BHEE 170I Lin  3G"
        let events = TableReader.read(glued)

        XCTAssertEqual(events.count, 2, "TR is two meetings")
        XCTAssertEqual(events[0].event.course, "ECE 30100")
        XCTAssertEqual(events[0].event.room, "BHEE 170")
        XCTAssertEqual(events[0].event.instructor, "I Lin")
    }

    func testGluedMultiRowKeepsEachRoomWithItsOwnSection() {
        let glued = """
            ECE30100Lec17727-002TR7:30a8:45a08/25 -12/10BHEE 170I Lin  3G\
            ECE30200Lec17104-003MWF3:30p4:20p08/24 -12/11WALC 1018A R Reibman  3G\
            ECE30864Lab20243-003R9:30a11:20a08/27 -12/10BHEE 206M C Ruiz  1G\
            LabP20239-001M9:30a10:20a08/24 -12/07WALC 2088S P France
            """
        let events = TableReader.read(glued)

        XCTAssertEqual(events.first { $0.event.course == "ECE 30200" }?.event.room, "WALC 1018")

        let monday = events.first { $0.event.course == "ECE 30864L" && $0.event.dayIndex == 0 }
        XCTAssertEqual(monday?.event.room, "WALC 2088",
                       "The LabP keeps its own room, not its lecture's")
    }
}

/// Names carry commas, and commas carry meaning: "M C Ruiz, S P France" is
/// two people. The lexer drops punctuation everywhere else, so this is the
/// one exception and it needs pinning.
final class InstructorPunctuationTests: XCTestCase {

    func testTrailingCommaSurvivesTokenizing() {
        XCTAssertEqual(TableReader.tokenize("M C Ruiz, S P France"),
                       ["M", "C", "Ruiz,", "S", "P", "France"])
    }

    func testTwoInstructorsKeepTheirSeparator() {
        let events = TableReader.read(
            "ECE 30864 Lab 20243-003 R 9:30a 11:20a 08/27 - BHEE 206 M C Ruiz, S P France 1 G")
        XCTAssertEqual(events.first?.event.instructor, "M C Ruiz, S P France")
    }
}

/// The case that defeated counting occurrences: a document where every row is
/// glued, so the artefact "GECE" appears more often than the clean "ECE" it
/// was derived from. Structure survives this; frequency does not.
final class GluedSubjectTests: XCTestCase {

    private let allRowsGlued = """
        ECE30100Lec17727-002TR7:30a8:45a08/25 -12/10BHEE 170I Lin  3G\
        ECE30200Lec17104-003MWF3:30p4:20p08/24 -12/11WALC 1018A R Reibman  3G\
        ECE30864Lab20243-003R9:30a11:20a08/27 -12/10BHEE 206M C Ruiz  1G\
        LabP20239-001M9:30a10:20a08/24 -12/07WALC 2088S P France
        """

    func testEveryCourseResolvesToTheRealSubject() {
        let courses = Set(TableReader.read(allRowsGlued).map(\.event.course))

        XCTAssertTrue(courses.contains("ECE 30200"))
        XCTAssertTrue(courses.contains("ECE 30864L"))
        XCTAssertFalse(courses.contains { $0.hasPrefix("GECE") },
                       "The grade flag must not survive into a course code")
    }

    func testRoomsStayWithTheirOwnSection() {
        let events = TableReader.read(allRowsGlued)

        XCTAssertEqual(events.first { $0.event.course == "ECE 30200" }?.event.room, "WALC 1018")

        let monday = events.first { $0.event.course == "ECE 30864L" && $0.event.dayIndex == 0 }
        XCTAssertEqual(monday?.event.room, "WALC 2088",
                       "The LabP keeps its own room, not its lecture's")
    }

    func testBuildingCodesAreNotMistakenForSubjects() {
        // "BHEE 170" has the shape of a subject and a course number, so a
        // naive scan counts it as one.
        let resolved = TableReader.subject(from: "GECE", known: ["ECE", "BHEE", "WALC"])
        XCTAssertEqual(resolved, "ECE")
    }
}

/// Instructor names sit immediately before the Note column with no separator,
/// and the extractor welds words together. Both show up in the name.
final class InstructorCleanupTests: XCTestCase {

    func testNoteColumnEndsTheName() {
        let events = TableReader.read(
            "ECE 20869 Lec 31418-001 TR 4:30p 5:45p 08/25 - UC 114 S Bagchi Evening Exams Required 3 G")
        XCTAssertEqual(events.first?.event.instructor, "S Bagchi")
    }

    func testGluedInitialAndSurnameAreSeparated() {
        XCTAssertEqual(TableReader.separateGluedWords("PFrance"), "P France")
        XCTAssertEqual(TableReader.separateGluedWords("MIkram"), "M Ikram")
        XCTAssertEqual(TableReader.separateGluedWords("AParks"), "A Parks")
    }

    func testOrdinaryNamesAreUntouched() {
        XCTAssertEqual(TableReader.separateGluedWords("France"), "France")
        XCTAssertEqual(TableReader.separateGluedWords("Lin"), "Lin")
        XCTAssertEqual(TableReader.separateGluedWords("McGrath"), "McGrath")
    }

    func testTwoInstructorsReadCleanlyFromGluedText() {
        let events = TableReader.read(
            "ECE 39401 Lec 33549-020 R 12:30p 1:20p 08/27 - WALC 2088 C J Hack, B AParks 1 G")
        XCTAssertEqual(events.first?.event.instructor, "C J Hack, B A Parks")
    }
}
