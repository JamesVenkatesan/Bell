import XCTest
@testable import Bell

// Phase 4: the inbox. Most of these guard the AI Override rule, because an
// automatic add is the one place Bell acts without being asked.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

private let courses = ["ECE 20869", "ECE 30100", "ECE 30200", "ECE 30864", "ECE 30864L", "TA: ECE 36800"]
private let now = date(2026, 11, 2, 9, 0)

// MARK: - Reader

final class EventTextReaderTests: XCTestCase {

    func testReadsAFullAnnouncement() {
        let reading = EventTextReader.read(
            "ECE 30200 Midterm 2 is on November 12, 2026 at 7:00 PM in MSEE 180. Bring a calculator.",
            courses: courses, now: now)

        XCTAssertEqual(reading.start, date(2026, 11, 12, 19, 0))
        XCTAssertTrue(reading.hasTime)
        XCTAssertEqual(reading.location, "MSEE 180")
        XCTAssertEqual(reading.course, "ECE 30200")
        XCTAssertEqual(reading.kind, .exam)
        XCTAssertEqual(reading.keyword, "midterm")
        XCTAssertTrue(reading.title.contains("Midterm 2"))
        XCTAssertFalse(reading.title.contains("November"), "The date is shown as a date, not in the title")
    }

    /// "Due Friday" means by the end of Friday, not at noon, which is where
    /// the date detector puts a bare date.
    func testADeadlineWithoutATimeIsDueAtTheEndOfTheDay() {
        let reading = EventTextReader.read("Lab report due December 3, 2026", courses: courses, now: now)
        XCTAssertFalse(reading.hasTime)
        XCTAssertEqual(reading.start, date(2026, 12, 3, 23, 59))
        XCTAssertEqual(reading.kind, .assignment)
    }

    /// The date detector reads "due Friday 5pm" as a span from now; the
    /// deadline is its end.
    func testDueByATimeIsTheDeadlineNotNow() {
        let reading = EventTextReader.read("Problem set due December 3, 2026 at 5:00 PM",
                                           courses: courses, now: now)
        XCTAssertEqual(reading.start, date(2026, 12, 3, 17, 0))
        XCTAssertTrue(reading.hasTime)
        XCTAssertNil(reading.end, "A deadline is a moment, not a range")
    }

    func testAMeetingWithoutATimeStartsAtTheStartOfTheDay() {
        let reading = EventTextReader.read("Career fair interview December 3, 2026", courses: courses, now: now)
        XCTAssertEqual(reading.start, date(2026, 12, 3))
        XCTAssertEqual(reading.kind, .meeting)
    }

    func testNoDateIsNoDate() {
        let reading = EventTextReader.read("Remember to bring the lab kit", courses: courses, now: now)
        XCTAssertNil(reading.start)
    }

    func testTimeRangeGivesAnEnd() {
        let reading = EventTextReader.read("Review session November 20, 2026 from 6:00 PM to 8:00 PM",
                                           courses: courses, now: now)
        XCTAssertEqual(reading.start, date(2026, 11, 20, 18, 0))
        XCTAssertEqual(reading.end, date(2026, 11, 20, 20, 0))
    }

    /// People say "ECE 302", not "ECE 30200".
    func testCourseFromHowPeopleWriteIt() {
        XCTAssertEqual(EventTextReader.course(in: "ECE 302 quiz", courses: courses), "ECE 30200")
        XCTAssertEqual(EventTextReader.course(in: "ECE30100 hw", courses: courses), "ECE 30100")
        XCTAssertEqual(EventTextReader.course(in: "ECE 30864L report", courses: courses), "ECE 30864L")
        XCTAssertEqual(EventTextReader.course(in: "ECE 308 lab", courses: courses), "ECE 30864",
                       "Lecture over lab when the text doesn't say which")
        XCTAssertEqual(EventTextReader.course(in: "ECE 368 office hours", courses: courses), "TA: ECE 36800")
        XCTAssertNil(EventTextReader.course(in: "MA 26100 exam", courses: courses), "Not a course they take")
    }

    func testLocationNeedsAKnownBuilding() {
        XCTAssertEqual(EventTextReader.location(in: "in UC 114"), "UC 114")
        XCTAssertEqual(EventTextReader.location(in: "meet at WALC"), "WALC")
        XCTAssertNil(EventTextReader.location(in: "ECE 30200 in Room 5"), "ECE is a subject, not a building")
    }

    func testWholeWordsOnly() {
        XCTAssertFalse(EventTextReader.containsWord("final", in: "finally done"))
        XCTAssertFalse(EventTextReader.containsWord("hw", in: "shower thoughts"))
        XCTAssertTrue(EventTextReader.containsWord("office hours", in: "Office Hours moved"))
    }

    func testKindPrecedence() {
        XCTAssertEqual(EventTextReader.kind(of: "Final exam review session"), .exam)
        XCTAssertEqual(EventTextReader.kind(of: "Project demo due"), .project)
        XCTAssertEqual(EventTextReader.kind(of: "Coffee?"), .other)
    }
}

// MARK: - Agreement

final class InboxAgreementTests: XCTestCase {

    private func reading(_ start: Date?, timed: Bool = true, title: String = "Detector title",
                         keyword: String? = "exam") -> InboxReading {
        InboxReading(title: title, start: start, end: nil, hasTime: timed,
                     location: nil, course: nil, kind: .exam, keyword: keyword)
    }

    func testWithoutTheModelConfidenceReflectsWhatWasFound() {
        XCTAssertEqual(InboxAgreement.merge(detector: reading(now), model: nil).confidence, 0.7)
        XCTAssertEqual(InboxAgreement.merge(detector: reading(now, timed: false), model: nil).confidence, 0.55)
        XCTAssertEqual(InboxAgreement.merge(detector: reading(nil), model: nil).confidence, 0.2)
    }

    func testAgreementIsHighConfidenceAndTakesTheModelsTitle() {
        let result = InboxAgreement.merge(detector: reading(date(2026, 11, 12, 19, 0)),
                                          model: reading(date(2026, 11, 12, 19, 3), title: "ECE 30200 midterm"))
        XCTAssertEqual(result.confidence, 0.95)
        XCTAssertNil(result.caution)
        XCTAssertEqual(result.reading.title, "ECE 30200 midterm")
    }

    /// Two readers that disagree are shown as disagreeing, in words.
    func testDisagreementIsLowConfidenceAndSaysSo() {
        let result = InboxAgreement.merge(detector: reading(date(2026, 11, 12, 19, 0)),
                                          model: reading(date(2026, 11, 13, 19, 0)))
        XCTAssertEqual(result.confidence, 0.45)
        XCTAssertNotNil(result.caution)
        XCTAssertEqual(result.reading.start, date(2026, 11, 12, 19, 0), "Detector's date shown")
    }

    func testADayAgreesWithAnyTimeThatDayAndTheTimeIsKept() {
        let result = InboxAgreement.merge(detector: reading(date(2026, 11, 12), timed: false),
                                          model: reading(date(2026, 11, 12, 14, 0)))
        XCTAssertEqual(result.confidence, 0.95)
        XCTAssertTrue(result.reading.hasTime)
        XCTAssertEqual(result.reading.start, date(2026, 11, 12, 14, 0))
    }

    func testOnlyTheModelSeeingADateIsFlagged() {
        let result = InboxAgreement.merge(detector: reading(nil), model: reading(date(2026, 11, 12, 14, 0)))
        XCTAssertEqual(result.confidence, 0.6)
        XCTAssertNotNil(result.caution)
    }
}

// MARK: - AI Override

final class AIOverrideTests: XCTestCase {

    private func result(keyword: String?, start: Date?, timed: Bool = true,
                        confidence: Double = 0.95, caution: String? = nil) -> InboxAgreement.Result {
        .init(reading: InboxReading(title: "T", start: start, end: nil, hasTime: timed,
                                    location: nil, course: nil, kind: .exam, keyword: keyword),
              confidence: confidence, caution: caution)
    }

    func testTheUsersKeywordsAreRecognised() {
        XCTAssertEqual(AIOverride.keyword(in: "Exam 2 moved"), "exam")
        XCTAssertEqual(AIOverride.keyword(in: "Project deadline"), "deadline")
        XCTAssertEqual(AIOverride.keyword(in: "Interview with Bose"), "interview")
        XCTAssertEqual(AIOverride.keyword(in: "MANDATORY lab safety"), "mandatory")
        XCTAssertEqual(AIOverride.keyword(in: "Final exam schedule"), "exam", "First listed match wins")
        XCTAssertEqual(AIOverride.keyword(in: "Final presentation slots"), "final")
    }

    /// "final" on its own is everywhere in email.
    func testBareFinalIsNotEnough() {
        XCTAssertNil(AIOverride.keyword(in: "Final version of the slides attached"))
        XCTAssertNil(AIOverride.keyword(in: "Finally, the room is booked"))
    }

    func testConfidentFutureKeywordIsAddedAutomatically() {
        XCTAssertEqual(AIOverride.decide(result(keyword: "exam", start: date(2026, 11, 12, 19)), now: now),
                       .add(keyword: "exam"))
    }

    func testNoKeywordMeansReview() {
        XCTAssertEqual(AIOverride.decide(result(keyword: nil, start: date(2026, 11, 12, 19)), now: now), .review)
    }

    /// A confidently wrong date is worse than no add at all.
    func testDisagreementOrLowConfidenceMeansReview() {
        XCTAssertEqual(AIOverride.decide(result(keyword: "exam", start: date(2026, 11, 12, 19),
                                                caution: "two dates"), now: now), .review)
        XCTAssertEqual(AIOverride.decide(result(keyword: "exam", start: date(2026, 11, 12),
                                                timed: false, confidence: 0.55), now: now), .review)
    }

    func testThingsAlreadyOverAreNotAdded() {
        XCTAssertEqual(AIOverride.decide(result(keyword: "exam", start: date(2026, 11, 1, 19)), now: now), .review)
    }

    func testADayOnlyDeadlineTodayStillCounts() {
        XCTAssertEqual(AIOverride.decide(result(keyword: "deadline", start: date(2026, 11, 2), timed: false,
                                                confidence: 0.7), now: now),
                       .add(keyword: "deadline"))
    }

    func testNoDateNeverAdds() {
        XCTAssertEqual(AIOverride.decide(result(keyword: "exam", start: nil), now: now), .review)
    }
}

// MARK: - Queue

final class CaptureQueueTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCapturesComeBackOldestFirst() throws {
        let queue = CaptureQueue(directory: directory)
        let first = try queue.enqueue(text: "first")
        Thread.sleep(forTimeInterval: 0.01)
        let second = try queue.enqueue(text: "second")
        XCTAssertEqual(queue.pending().map(\.id), [first.id, second.id])
    }

    func testImagesTravelWithTheirCapture() throws {
        let queue = CaptureQueue(directory: directory)
        let capture = try queue.enqueue(imageData: Data([1, 2, 3]), text: "caption", source: "screenshot")
        let read = try XCTUnwrap(queue.pending().first)
        XCTAssertEqual(read.kind, .image)
        XCTAssertEqual(queue.imageData(for: read), Data([1, 2, 3]))

        queue.remove(capture)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                      "The image goes too, or the App Group fills with orphans")
    }

    func testAFileThatIsntACaptureIsIgnored() throws {
        let queue = CaptureQueue(directory: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("junk.json"))
        XCTAssertTrue(queue.pending().isEmpty)
    }
}

// MARK: - Store and processor

@MainActor
final class InboxStoreTests: XCTestCase {

    private func sample(start: Date? = date(2026, 11, 12, 19)) -> InboxAgreement.Result {
        .init(reading: InboxReading(title: "Midterm 2", start: start, end: date(2026, 11, 12, 21),
                                    hasTime: true, location: "MSEE 180", course: "ECE 30200",
                                    kind: .exam, keyword: "midterm"),
              confidence: 0.95, caution: nil)
    }

    func testAcceptCreatesATaskTheUserMade() throws {
        let store = BellStore(inMemory: true)
        let id = store.addInboxItem(sample(), source: .screenshot, rawText: "raw")
        XCTAssertEqual(store.inbox.first?.state, .pending)

        store.accept(inboxID: id)
        let task = try XCTUnwrap(store.timetable.tasks.first)
        XCTAssertEqual(task.title, "Midterm 2")
        XCTAssertEqual(task.location, "MSEE 180")
        XCTAssertEqual(task.end, date(2026, 11, 12, 21))
        XCTAssertEqual(task.kind, .exam)
        XCTAssertFalse(task.isAutomatic)
        XCTAssertEqual(store.inbox.first?.state, .accepted)
    }

    /// The labelling rule: automatic adds are marked on both sides.
    func testAutomaticAddIsMarkedEverywhere() throws {
        let store = BellStore(inMemory: true)
        let id = store.addInboxItem(sample(), source: .shareSheet, rawText: "raw")
        store.accept(inboxID: id, automatic: true)

        XCTAssertTrue(try XCTUnwrap(store.timetable.tasks.first).isAutomatic)
        XCTAssertTrue(try XCTUnwrap(store.inbox.first).wasAutoAccepted)
    }

    func testUndoingAnAutomaticAddRemovesExactlyThatTask() {
        let store = BellStore(inMemory: true)
        let mine = store.addTask(title: "Mine", course: nil, due: date(2026, 11, 20), kind: .other)
        let id = store.addInboxItem(sample(), source: .shareSheet, rawText: "raw")
        store.accept(inboxID: id, automatic: true)

        store.undoAutomaticAdd(inboxID: id)
        XCTAssertEqual(store.timetable.tasks.map(\.id), [mine])
        XCTAssertEqual(store.inbox.first?.state, .pending, "Back in review for the user to decide")
    }

    func testCantAcceptWithoutADate() {
        let store = BellStore(inMemory: true)
        let id = store.addInboxItem(sample(start: nil), source: .shareSheet, rawText: "raw")
        store.accept(inboxID: id)
        XCTAssertTrue(store.timetable.tasks.isEmpty)
        XCTAssertEqual(store.inbox.first?.state, .pending)
    }

    func testDismissIsReflectedImmediately() {
        let store = BellStore(inMemory: true)
        let id = store.addInboxItem(sample(), source: .shareSheet, rawText: "raw")
        store.dismiss(inboxID: id)
        XCTAssertEqual(store.inbox.first?.state, .dismissed)
    }

    // Detector only, so the answer doesn't depend on whether the Mac running
    // the simulator has Apple Intelligence (it often does). This is also
    // exactly what a device without it gets.

    private func processor() -> InboxProcessor {
        let processor = InboxProcessor()
        processor.usesModel = false
        return processor
    }

    func testProcessorAddsAnInterviewAutomatically() async throws {
        let store = BellStore(inMemory: true)
        let processor = processor()
        await processor.process(text: "Interview with Bose on March 3, 2027 at 2:00 PM in MSEE 180",
                                source: .shareSheet, store: store, now: now)

        let task = try XCTUnwrap(store.timetable.tasks.first)
        XCTAssertTrue(task.isAutomatic)
        XCTAssertEqual(task.due, date(2027, 3, 3, 14, 0))
        XCTAssertEqual(processor.justAutoAdded.count, 1)
    }

    func testProcessorLeavesOrdinaryThingsForReview() async {
        let store = BellStore(inMemory: true)
        await processor().process(text: "Coffee on March 3, 2027 at 2:00 PM",
                                       source: .shareSheet, store: store, now: now)
        XCTAssertTrue(store.timetable.tasks.isEmpty)
        XCTAssertEqual(store.inbox.first?.state, .pending)
    }

    func testDrainEmptiesTheQueueIntoTheInbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = CaptureQueue(directory: directory)
        try queue.enqueue(text: "Coffee on March 3, 2027 at 2:00 PM")

        let store = BellStore(inMemory: true)
        await processor().drain(queue, store: store)
        XCTAssertEqual(store.inbox.count, 1)
        XCTAssertTrue(queue.pending().isEmpty)
    }
}

// MARK: - Compatibility

final class InboxCompatibilityTests: XCTestCase {

    /// The widget may read a snapshot from before tasks had these fields.
    func testOldTaskDecodes() throws {
        let old = #"{"events":[],"tasks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"HW","due":"2026-11-12T19:00:00Z","kind":"assignment","isDone":false}],"exceptions":[],"weekCount":1,"rotationAnchor":"2026-08-24T00:00:00Z","showsWeekends":false}"#
        let table = try JSONDecoder.bell.decode(Timetable.self, from: Data(old.utf8))
        XCTAssertEqual(table.tasks.count, 1)
        XCTAssertFalse(table.tasks[0].isAutomatic)
    }

    func testDeclaresPhotoAccessAndEmbedsTheShareExtension() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertFalse((info["NSPhotoLibraryUsageDescription"] as? String ?? "").isEmpty,
                       "Asking for Photos without this string crashes")
        let plugins = try FileManager.default.contentsOfDirectory(atPath: Bundle.main.builtInPlugInsPath ?? "")
        XCTAssertTrue(plugins.contains("BellShare.appex"))
    }
}

@MainActor
final class UndatedCaptureTests: XCTestCase {

    /// Run with the real on-device model when the Mac has one. It invented
    /// today's date for this sentence; the item must arrive undated.
    func testUndatedTextStaysUndatedEvenWithTheModel() async throws {
        let store = BellStore(inMemory: true)
        let id = await InboxProcessor().process(text: "Can you send me the slides from lab?",
                                                source: .shareSheet, store: store, now: now)
        XCTAssertNotNil(id)
        let entry = try XCTUnwrap(store.inbox.first)
        XCTAssertEqual(entry.state, .pending, "Still lands in review, where a date can be added")
        XCTAssertNil(entry.start)
    }

    func testAModelDateForTextWithoutTimeWordsIsDropped() {
        let none = InboxReading(title: "Slides", start: nil, end: nil, hasTime: false,
                                location: nil, course: nil, kind: .other, keyword: nil)
        var invented = none
        invented.start = now
        invented.hasTime = true

        let result = InboxAgreement.merge(detector: none, model: invented,
                                          text: "Can you send me the slides from lab?")
        XCTAssertNil(result.reading.start)

        let kept = InboxAgreement.merge(detector: none, model: invented, text: "Slides by Friday please")
        XCTAssertNotNil(kept.reading.start, "\"Friday\" is a time word: the model may have read it right")
    }

    func testTimeWords() {
        XCTAssertTrue(EventTextReader.mentionsTime("see you tmrw at 3pm"))
        XCTAssertTrue(EventTextReader.mentionsTime("exam moved to 11/12"))
        XCTAssertTrue(EventTextReader.mentionsTime("Thursday works"))
        XCTAssertFalse(EventTextReader.mentionsTime("Can you send me the slides from lab?"))
        XCTAssertFalse(EventTextReader.mentionsTime("Room 2088"))
    }
}
