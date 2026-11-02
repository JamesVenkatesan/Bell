import XCTest
@testable import Bell

/// The real registrar PDFs, through the real extraction.
///
/// Every other TableReader test feeds hand-written strings, which assume a
/// row arrives as one run of tokens. Nothing proved PDFKit produces that,
/// and it doesn't: these files emit the table's left and right halves as
/// separate blocks, so a row's room and instructor arrive nowhere near its
/// CRN. This file is the guard against that ever being assumed again.
final class RealPDFTests: XCTestCase {

    private func pages(_ name: String) async throws -> [TextExtraction.Page] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "pdf"),
                                "Fixture \(name).pdf missing: it's gitignored, copy it into BellTests/Fixtures")
        return try await TextExtraction.pages(from: url)
    }

    /// Diagnostic: prints what PDFKit produced and what the reader made of it.
    func testPrintWhatTheReaderSees() async throws {
        for name in ["schedule-print", "schedule-unitime"] {
            let pages = try await pages(name)
            let text = pages.map(\.plainText).joined(separator: "\n")
            print("===== \(name): raw text =====\n\(text)\n===== records =====")
            for record in TableReader.records(in: text) {
                print("\(record.subject ?? "?") \(record.courseNumber ?? "?") \(record.type ?? "?") "
                      + "| days \(record.days ?? "?") \(record.start ?? "?")-\(record.end ?? "?") "
                      + "| room \(record.room ?? "NIL") | instructor \(record.instructor ?? "NIL")")
            }
        }
    }
}


// MARK: - Permanent

extension RealPDFTests {

    private struct Meeting: Hashable, CustomStringConvertible {
        var day: Int, course: String, start: Int, end: Int, room: String, instructor: String?
        var description: String { "\(day) \(course) \(start)-\(end) \(room) \(instructor ?? "nil")" }
    }

    private func m(_ day: Int, _ course: String, _ s: (Int, Int), _ e: (Int, Int), _ room: String,
                   _ instructor: String) -> Meeting {
        Meeting(day: day, course: course, start: s.0 * 3600 + s.1 * 60, end: e.0 * 3600 + e.1 * 60,
                room: room, instructor: instructor)
    }

    private func meetings(_ name: String) async throws -> Set<Meeting> {
        Set(TableReader.read(try await pages(name)).map {
            Meeting(day: $0.event.dayIndex, course: $0.event.course, start: $0.event.startSecond,
                    end: $0.event.endSecond, room: $0.event.room, instructor: $0.event.instructor)
        })
    }

    /// The ten meetings CLAUDE.md lists as the expected result, exactly.
    private var expected: Set<Meeting> {
        [m(0, "ECE 30864L", (9, 30), (10, 20), "WALC 2088", "S P France, M Ikram"),
         m(0, "ECE 30200", (15, 30), (16, 20), "WALC 1018", "A R Reibman"),
         m(1, "ECE 30100", (7, 30), (8, 45), "BHEE 170", "I Lin"),
         m(1, "ECE 20869", (16, 30), (17, 45), "UC 114", "S Bagchi"),
         m(2, "ECE 30200", (15, 30), (16, 20), "WALC 1018", "A R Reibman"),
         m(3, "ECE 30100", (7, 30), (8, 45), "BHEE 170", "I Lin"),
         m(3, "ECE 30864L", (9, 30), (11, 20), "BHEE 206", "M C Ruiz, S P France"),
         m(3, "ECE 39401", (12, 30), (13, 20), "WALC 2088", "C J Hack, B A Parks"),
         m(3, "ECE 20869", (16, 30), (17, 45), "UC 114", "S Bagchi"),
         m(4, "ECE 30200", (15, 30), (16, 20), "WALC 1018", "A R Reibman")]
    }

    func testUniTimePrintGivesTheExpectedTenMeetings() async throws {
        let found = try await meetings("schedule-unitime")
        XCTAssertEqual(found, expected, "Missing: \(expected.subtracting(found)) Extra: \(found.subtracting(expected))")
    }

    /// The later print adds ECE 36200. Same ten, plus its lecture and lab.
    func testLaterPrintAddsTheMicroprocessorsCourse() async throws {
        let more: Set<Meeting> = [
            m(0, "ECE 36200", (7, 30), (8, 20), "WTHR 200", "Y Kim"),
            m(2, "ECE 36200", (7, 30), (8, 20), "WTHR 200", "Y Kim"),
            m(4, "ECE 36200", (7, 30), (8, 20), "WTHR 200", "Y Kim"),
            m(2, "ECE 36200L", (8, 30), (11, 20), "BHEE 162", "N Menon"),
        ]
        let found = try await meetings("schedule-print")
        let want = expected.union(more)
        XCTAssertEqual(found, want, "Missing: \(want.subtracting(found)) Extra: \(found.subtracting(want))")
    }

    /// SOC 10000DIST is real enrolment with no meeting time. Inventing one
    /// puts a phantom class on the widget.
    func testTheOnlineSectionProducesNoMeetings() async throws {
        for name in ["schedule-print", "schedule-unitime"] {
            let found = try await meetings(name)
            XCTAssertFalse(found.contains { $0.course.hasPrefix("SOC") })
        }
    }

    /// The whole pipeline, not just the reader: the table reader must be the
    /// one that wins, at its confidence, with rooms intact.
    func testCaptureUsesTheTableAndKeepsRooms() async throws {
        let result = await ScheduleCapture.capture(pages: try await pages("schedule-unitime"), against: [])
        let events = result.diff.changes.map(\.event)
        XCTAssertEqual(events.count, 10)
        XCTAssertTrue(events.allSatisfy { !$0.room.isEmpty && $0.instructor != nil }, "\(events)")
    }
}

/// The geometry the fix depends on, on its own.
final class TableLayoutTests: XCTestCase {

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> TextExtraction.Fragment {
        .init(text: text, frame: CGRect(x: x, y: y, width: 0.05, height: 0.008), confidence: 1)
    }

    /// Rows emitted in column blocks, with a wrapped room, come back as one
    /// line per row in reading order.
    func testRowsAreRebuiltFromPosition() {
        let lines = [
            line("Room", x: 0.48, y: 0.565), line("Instructor", x: 0.54, y: 0.565), line("Credit", x: 0.88, y: 0.565),
            line("ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25", x: 0.04, y: 0.578),
            line("ECE 30200 Lec 17104-003 MWF 3:30p 4:20p 08/24", x: 0.04, y: 0.610),
            // The right-hand block, after every left-hand row, as PDFKit emits it.
            line("BHEE", x: 0.484, y: 0.578), line("170", x: 0.484, y: 0.588),
            line("I Lin 3 G", x: 0.539, y: 0.578),
            line("WALC", x: 0.484, y: 0.610), line("1018", x: 0.484, y: 0.619),
            line("A R", x: 0.539, y: 0.610), line("Reibman", x: 0.539, y: 0.619),
            line("3 G", x: 0.885, y: 0.610),
        ]
        XCTAssertEqual(TableLayout.reflow(lines), """
            ECE 30100 Lec 17727-002 TR 7:30a 8:45a 08/25 BHEE 170 I Lin 3 G
            ECE 30200 Lec 17104-003 MWF 3:30p 4:20p 08/24 WALC 1018 A R Reibman 3 G
            """)
    }

    func testNoTableNoReflow() {
        XCTAssertNil(TableLayout.reflow([line("Monday", x: 0.1, y: 0.1), line("ECE 30100 Lec", x: 0.1, y: 0.2)]))
    }
}

final class InstructorBoundaryTests: XCTestCase {

    /// A rebuilt row ends on its grade mode; the next row's course must not
    /// become part of the name.
    func testNameStopsAtTheNextCourse() {
        let tokens = TableReader.tokenize("BHEE 162 N Menon G ECE 39401 Lec")
        XCTAssertEqual(TableReader.instructor(in: tokens, room: "BHEE 162"), "N Menon")
    }
}
