import XCTest
@testable import Bell

// Notion: reading the schema, mapping columns, turning rows into tasks,
// finding the right API version, and syncing without touching your own tasks.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Plays Notion's side. Records every request so tests can check paths,
/// methods and pinned versions.
private final class StubTransport: NotionTransport, @unchecked Sendable {
    var respond: (URLRequest) -> (Int, Any)
    private(set) var requests: [URLRequest] = []

    init(_ respond: @escaping (URLRequest) -> (Int, Any)) { self.respond = respond }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let (status, body) = respond(request)
        return (try JSONSerialization.data(withJSONObject: body), status)
    }

    var calls: [String] {
        requests.map { "\($0.httpMethod ?? "") \($0.url!.path.replacingOccurrences(of: "/v1/", with: "")) @\($0.value(forHTTPHeaderField: "Notion-Version") ?? "")" }
    }
}

private let dbID = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"

/// The shape of a homework tracker: title, a due date, a course select, a
/// status with a Complete group, and a type select.
private let properties: [String: Any] = [
    "Name": ["id": "title", "name": "Name", "type": "title", "title": [:]],
    "Due": ["id": "d%3Ae", "name": "Due", "type": "date", "date": [:]],
    "Class": ["id": "c1", "name": "Class", "type": "select",
              "select": ["options": [["name": "ECE 302"], ["name": "ECE 30864"]]]],
    "Status": ["id": "s1", "name": "Status", "type": "status",
               "status": ["options": [["id": "o1", "name": "Not started"], ["id": "o2", "name": "Handed in"]],
                          "groups": [["name": "To-do", "option_ids": ["o1"]], ["name": "Complete", "option_ids": ["o2"]]]]],
    "Type": ["id": "t1", "name": "Type", "type": "select",
             "select": ["options": [["name": "Homework"], ["name": "Exam"]]]],
]

private func page(_ id: String, title: String, due: String?, course: String? = nil,
                  status: String? = nil, type: String? = nil) -> [String: Any] {
    var props: [String: Any] = [
        "Name": ["id": "title", "type": "title", "title": [["plain_text": title]]],
        "Due": ["id": "d%3Ae", "type": "date", "date": due.map { ["start": $0] } as Any],
    ]
    props["Class"] = ["id": "c1", "type": "select", "select": course.map { ["name": $0] } as Any]
    props["Status"] = ["id": "s1", "type": "status", "status": status.map { ["name": $0] } as Any]
    props["Type"] = ["id": "t1", "type": "select", "select": type.map { ["name": $0] } as Any]
    return ["object": "page", "id": id, "properties": props]
}

private let courses = ["ECE 20869", "ECE 30100", "ECE 30200", "ECE 30864", "ECE 30864L", "ECE 39401"]

final class NotionSchemaTests: XCTestCase {

    private var schema: [NotionProperty] { NotionProperty.schema(from: ["properties": properties]) }

    func testDatabaseLinkParsing() {
        let hex = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
        // The view ID after ?v= is not the database.
        XCTAssertEqual(NotionDatabaseID.parse("https://www.notion.so/akash/Fall-2026-\(hex)?v=ffffffffffffffffffffffffffffffff&pvs=4"), dbID)
        XCTAssertEqual(NotionDatabaseID.parse(dbID), dbID)
        XCTAssertEqual(NotionDatabaseID.parse("  \(hex.uppercased())\n"), dbID)
        XCTAssertNil(NotionDatabaseID.parse("https://www.notion.so/akash/Fall-2026"))
    }

    func testSchemaReadsTypesAndTheStatusCompleteGroup() {
        XCTAssertEqual(schema.first?.type, "title", "Title listed first")
        let status = schema.first { $0.id == "s1" }
        XCTAssertEqual(status?.completeOptions, ["Handed in"])
        XCTAssertEqual(schema.first { $0.id == "c1" }?.options, ["ECE 302", "ECE 30864"])
    }

    func testSuggestedMappingComesFromTypesNotFixedNames() {
        let m = NotionMapping.suggest(for: schema)
        XCTAssertEqual(m.title, "title")
        XCTAssertEqual(m.due, "d%3Ae", "The only date column")
        XCTAssertEqual(m.course, "c1", "Named Class, not Course, and still found")
        XCTAssertEqual(m.done, "s1")
        XCTAssertEqual(m.kind, "t1")
    }

    func testWithSeveralDatesTheOneNamedForDeadlinesWins() {
        let s = [NotionProperty(id: "a", name: "Assigned", type: "date"),
                 NotionProperty(id: "b", name: "Deadline", type: "date"),
                 NotionProperty(id: "t", name: "Task", type: "title")]
        XCTAssertEqual(NotionMapping.suggest(for: s).due, "b")
    }

    func testCourseColumnIsFoundByItsOptionsWhateverItsName() {
        let s = [NotionProperty(id: "t", name: "Task", type: "title"),
                 NotionProperty(id: "x", name: "Bucket", type: "select", options: ["MA 26100", "CS 15900"])]
        XCTAssertEqual(NotionMapping.suggest(for: s).course, "x")
    }

    /// The mapping is by property ID, so renaming a column in Notion keeps
    /// working. A hardcoded "Due Date" would have broken here.
    func testRenamedColumnsStillMap() throws {
        let m = NotionMapping.suggest(for: schema)
        var renamed = page("p1", title: "HW 9", due: "2026-11-05", course: "ECE 302")
        var props = renamed["properties"] as! [String: Any]
        props["Deadline (renamed)"] = props.removeValue(forKey: "Due")
        renamed["properties"] = props
        let item = try XCTUnwrap(NotionItem.make(page: renamed, mapping: m, schema: schema))
        XCTAssertEqual(item.due, date(2026, 11, 5))
    }

    func testDeletedColumnsAreDroppedFromTheMapping() {
        var m = NotionMapping.suggest(for: schema)
        m = m.pruned(to: schema.filter { $0.id != "t1" })
        XCTAssertNil(m.kind)
        XCTAssertTrue(m.isUsable)
        XCTAssertFalse(m.pruned(to: schema.filter { $0.id != "d%3Ae" }).isUsable)
    }

    // MARK: Values

    func testDateOnlyIsALocalDayAndDateTimeIsAnInstant() throws {
        let day = try XCTUnwrap(NotionValue.parseDate("2026-11-05"))
        XCTAssertEqual(day.0, date(2026, 11, 5))
        XCTAssertTrue(day.1)
        let instant = try XCTUnwrap(NotionValue.parseDate("2026-11-05T23:59:00.000-05:00"))
        XCTAssertEqual(instant.0, Date(timeIntervalSince1970: 1_793_941_140))
        XCTAssertFalse(instant.1)
        XCTAssertNotNil(NotionValue.parseDate("2026-11-05T14:00:00Z"))
    }

    func testFormulaAndRollupValues() {
        let formula: [String: Any] = ["id": "f", "type": "formula", "formula": ["type": "date", "date": ["start": "2026-11-06"]]]
        XCTAssertEqual(NotionValue.value(formula), .date(date(2026, 11, 6), allDay: true))
        let rollup: [String: Any] = ["id": "r", "type": "rollup", "rollup": ["type": "array", "array": [
            ["type": "title", "title": [["plain_text": "ECE 30200"]]]]]]
        XCTAssertEqual(NotionValue.value(rollup), .text("ECE 30200"))
        let relation: [String: Any] = ["id": "r", "type": "relation", "relation": [["id": "abc"]]]
        XCTAssertEqual(NotionValue.value(relation), .relation(["abc"]))
    }

    // MARK: Rows

    func testRowsBecomeItemsAndRowsWithoutDatesAreSkipped() throws {
        let m = NotionMapping.suggest(for: schema)
        let item = try XCTUnwrap(NotionItem.make(page: page("p1", title: "HW 9", due: "2026-11-05T17:00:00Z",
                                                            course: "ECE 302", status: "Handed in", type: "Homework"),
                                                 mapping: m, schema: schema))
        XCTAssertEqual(item.kind, .assignment)
        XCTAssertTrue(item.isDone, "Handed in is in the Complete group")
        XCTAssertEqual(item.courseText, "ECE 302")
        XCTAssertNil(NotionItem.make(page: page("p2", title: "Someday", due: nil), mapping: m, schema: schema))
        var trashed = page("p3", title: "Gone", due: "2026-11-05")
        trashed["in_trash"] = true
        XCTAssertNil(NotionItem.make(page: trashed, mapping: m, schema: schema))
    }

    /// "Midterm 7:00–9:00 PM" in Notion is a range; its end lets the day
    /// view draw the exam as a block.
    func testATimedRangeKeepsItsEnd() throws {
        let m = NotionMapping.suggest(for: schema)
        var p = page("p1", title: "Midterm 2", due: nil, type: "Exam")
        var props = p["properties"] as! [String: Any]
        props["Due"] = ["id": "d%3Ae", "type": "date",
                        "date": ["start": "2026-11-05T19:00:00-05:00", "end": "2026-11-05T21:00:00-05:00"]]
        p["properties"] = props
        let item = try XCTUnwrap(NotionItem.make(page: p, mapping: m, schema: schema))
        XCTAssertEqual(item.end?.timeIntervalSince(item.due), 2 * 3600)
        XCTAssertEqual(item.kind, .exam)

        // A multi-day all-day range is still a deadline on its first day.
        props["Due"] = ["id": "d%3Ae", "type": "date", "date": ["start": "2026-11-05", "end": "2026-11-07"]]
        p["properties"] = props
        XCTAssertNil(try XCTUnwrap(NotionItem.make(page: p, mapping: m, schema: schema)).end)
    }

    func testDoneFromCheckboxAndFromPlainSelectWords() {
        XCTAssertTrue(NotionItem.isDone(.checkbox(true), property: nil))
        XCTAssertTrue(NotionItem.isDone(.options(["Submitted"]), property: NotionProperty(id: "x", name: "S", type: "select")))
        XCTAssertFalse(NotionItem.isDone(.options(["In progress"]), property: NotionProperty(id: "x", name: "S", type: "select")))
    }

    // MARK: Kind

    func testKindInference() {
        XCTAssertEqual(NotionKind.infer(title: "Chapter 4", type: "Exam"), .exam, "The type column wins")
        XCTAssertEqual(NotionKind.infer(title: "Midterm 2", type: nil), .exam)
        XCTAssertEqual(NotionKind.infer(title: "Quiz 5", type: nil), .quiz)
        XCTAssertEqual(NotionKind.infer(title: "Final project report", type: nil), .project, "Not an exam")
        XCTAssertEqual(NotionKind.infer(title: "Final exam", type: nil), .exam)
        XCTAssertEqual(NotionKind.infer(title: "PSet 3", type: nil), .assignment)
        XCTAssertEqual(NotionKind.infer(title: "Reading: chapter 7", type: nil), .other, "A reading isn't an assignment")
        XCTAssertEqual(NotionKind.infer(title: "Midterm review", type: "Reading"), .other, "The type column says reading")
        XCTAssertEqual(NotionKind.infer(title: "Lab 6 writeup", type: nil), .assignment)
    }

    // MARK: Course

    func testCourseMatching() {
        XCTAssertEqual(NotionCourse.match(courseText: "ECE 302", title: "HW 9", courses: courses), "ECE 30200")
        XCTAssertEqual(NotionCourse.match(courseText: nil, title: "ece302 hw 9", courses: courses), "ECE 30200",
                       "Lower case and squashed, from the title")
        XCTAssertEqual(NotionCourse.match(courseText: "ECE 30864", title: "Lab report", courses: courses), "ECE 30864",
                       "Lecture over lab when the text doesn't say L")
        XCTAssertEqual(NotionCourse.match(courseText: "ECE 30864L", title: "", courses: courses), "ECE 30864L")
    }

    /// Unmatched stays unlinked rather than guessed into a near course.
    func testNoMatchStaysUnlinked() {
        XCTAssertNil(NotionCourse.match(courseText: "Signals", title: "Problem set 4", courses: courses))
        XCTAssertNil(NotionCourse.match(courseText: "MA 26100", title: "HW", courses: courses), "Not one of your courses")
        XCTAssertNil(NotionCourse.match(courseText: "ECE 999", title: "HW", courses: courses))
    }
}

final class NotionClientTests: XCTestCase {

    private let token = "ntn_TESTSECRET_123"

    func testClassicPathWhenTheDatabaseAnswersIt() async throws {
        let stub = StubTransport { _ in (200, ["object": "database", "title": [["plain_text": "Fall 2026"]],
                                               "properties": properties, "results": []]) }
        let found = try await NotionClient(token: token, transport: stub).discover(databaseID: dbID)
        XCTAssertEqual(found.source, .classic(databaseID: dbID))
        XCTAssertEqual(found.title, "Fall 2026")
        XCTAssertEqual(stub.calls, ["GET databases/\(dbID) @2022-06-28", "POST databases/\(dbID)/query @2022-06-28"])
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    /// The 2025-09-03 change: a multi-source database refuses the old query.
    func testFallsBackToDataSourcesWhenTheClassicQueryFails() async throws {
        let stub = StubTransport { request in
            let version = request.value(forHTTPHeaderField: "Notion-Version")
            let path = request.url!.path
            if version == NotionAPI.classicVersion {
                if path.hasSuffix("/query") {
                    return (400, ["object": "error", "status": 400, "code": "validation_error",
                                  "message": "Databases with multiple data sources are not supported in this API version."])
                }
                return (200, ["object": "database", "properties": properties])
            }
            if path.hasSuffix("databases/\(dbID)") {
                return (200, ["object": "database", "title": [["plain_text": "Fall 2026"]],
                              "data_sources": [["id": "ds-1", "name": "Tasks"], ["id": "ds-2", "name": "Archive"]]])
            }
            if path.hasSuffix("data_sources/ds-1") { return (200, ["object": "data_source", "properties": properties]) }
            return (200, ["object": "list", "results": [], "has_more": false])
        }
        let found = try await NotionClient(token: token, transport: stub).discover(databaseID: dbID)
        XCTAssertEqual(found.source, .dataSource(id: "ds-1", databaseID: dbID))
        XCTAssertEqual(found.otherSources, ["Archive"])
        XCTAssertEqual(found.schema.count, 5)
        XCTAssertEqual(Array(stub.calls.suffix(3)), ["GET databases/\(dbID) @2025-09-03",
                                                     "GET data_sources/ds-1 @2025-09-03",
                                                     "POST data_sources/ds-1/query @2025-09-03"])
    }

    /// A bad token would fail the same way on both paths; trying the second
    /// would only bury the real problem.
    func testRejectedTokenDoesNotFallBack() async {
        let stub = StubTransport { _ in (401, ["object": "error", "status": 401, "code": "unauthorized", "message": "API token is invalid."]) }
        do {
            _ = try await NotionClient(token: token, transport: stub).discover(databaseID: dbID)
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? NotionError, .unauthorized)
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testNotSharedIsReportedAsSuchAfterBothPaths() async {
        let stub = StubTransport { _ in (404, ["object": "error", "status": 404, "code": "object_not_found", "message": "Could not find database"]) }
        do {
            _ = try await NotionClient(token: token, transport: stub).discover(databaseID: dbID)
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? NotionError, .notShared)
            XCTAssertTrue(error.localizedDescription.contains("Connections"), "Says how to fix it")
        }
    }

    func testPaginationFollowsTheCursorToTheEnd() async throws {
        let stub = StubTransport { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if body["start_cursor"] as? String == "c2" {
                return (200, ["results": [page("p3", title: "C", due: "2026-11-07")], "has_more": false, "next_cursor": NSNull()])
            }
            return (200, ["results": [page("p1", title: "A", due: "2026-11-05"), page("p2", title: "B", due: "2026-11-06")],
                          "has_more": true, "next_cursor": "c2"])
        }
        let pages = try await NotionClient(token: token, transport: stub).allPages(from: .classic(databaseID: dbID))
        XCTAssertEqual(pages.compactMap { $0["id"] as? String }, ["p1", "p2", "p3"])
    }

    /// A failure part-way must throw, not return the first page: the sync
    /// would otherwise delete every task on the pages it didn't reach.
    func testAFailedPageThrowsInsteadOfReturningAPartialList() async {
        let stub = StubTransport { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if body["start_cursor"] != nil { return (500, ["code": "internal_server_error", "message": "Oops"]) }
            return (200, ["results": [page("p1", title: "A", due: "2026-11-05")], "has_more": true, "next_cursor": "c2"])
        }
        do {
            _ = try await NotionClient(token: token, transport: stub).allPages(from: .classic(databaseID: dbID))
            XCTFail("Should throw")
        } catch {}
    }

    /// The token is a real secret: it must never appear in anything Bell
    /// could show or log.
    func testErrorsNeverContainTheToken() async {
        for status in [400, 401, 404, 429, 500] {
            let stub = StubTransport { _ in (status, ["code": "x", "message": "Something about the request"]) }
            do {
                _ = try await NotionClient(token: token, transport: stub).allPages(from: .classic(databaseID: dbID))
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("TESTSECRET"), "HTTP \(status)")
                XCTAssertFalse(String(describing: error).contains("TESTSECRET"), "HTTP \(status)")
            }
        }
    }

    func testVersionsArePinnedNotFloating() {
        XCTAssertEqual(NotionAPI.classicVersion, "2022-06-28")
        XCTAssertEqual(NotionAPI.dataSourceVersion, "2025-09-03")
        let request = NotionClient(token: token).request("GET", "databases/x", version: NotionAPI.classicVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2022-06-28")
    }
}

@MainActor
final class NotionSyncTests: XCTestCase {

    private func item(_ id: String, _ title: String, due: Date = date(2026, 11, 5), done: Bool = false,
                      course: String? = "ECE 30200") -> NotionItem {
        NotionItem(pageID: id, title: title, due: due, isAllDay: true, kind: .assignment, isDone: done, course: course)
    }

    func testAddsUpdatesAndRemovesOnlyNotionRows() {
        let store = BellStore(inMemory: true)
        store.addTask(title: "Mine", course: nil, due: date(2026, 11, 6), kind: .assignment)

        XCTAssertEqual(store.applyNotion([item("p1", "HW 9"), item("p2", "HW 10")]),
                       .init(added: 2, updated: 0, removed: 0))
        XCTAssertEqual(store.timetable.tasks.count, 3)

        // p2 disappears from Notion; p1 is renamed.
        XCTAssertEqual(store.applyNotion([item("p1", "HW 9 (revised)")]), .init(added: 0, updated: 1, removed: 1))
        XCTAssertEqual(Set(store.timetable.tasks.map(\.title)), ["Mine", "HW 9 (revised)"],
                       "Your own task survives every sync")

        // Even an empty Notion leaves your own task alone.
        store.applyNotion([])
        XCTAssertEqual(store.timetable.tasks.map(\.title), ["Mine"])
    }

    func testNotionRowsAreMarkedAndAllDayIsKept() throws {
        let store = BellStore(inMemory: true)
        store.applyNotion([item("p1", "HW 9", course: nil)])
        let task = try XCTUnwrap(store.timetable.tasks.first)
        XCTAssertEqual(task.fromNotion, true)
        XCTAssertTrue(task.allDay)
        XCTAssertNil(task.course, "Unmatched stays unlinked")
    }

    /// Ticked in a widget, then synced: Notion still says not done, but
    /// Bell never writes back, so the tick must survive.
    func testATickInBellSurvivesTheNextSync() throws {
        let store = BellStore(inMemory: true)
        store.applyNotion([item("p1", "HW 9")])
        let id = try XCTUnwrap(store.timetable.tasks.first?.id)
        WidgetActions.clear()
        WidgetActions.append(.taskDone(id))
        store.applyWidgetActions()
        store.applyNotion([item("p1", "HW 9", done: false)])
        XCTAssertEqual(store.timetable.tasks.first?.isDone, true)
    }

    func testDoneInNotionIsDoneInBell() {
        let store = BellStore(inMemory: true)
        store.applyNotion([item("p1", "HW 9", done: true)])
        XCTAssertEqual(store.timetable.tasks.first?.isDone, true)
    }

    func testDisconnectingRemovesNotionRowsOnly() {
        let store = BellStore(inMemory: true)
        store.addTask(title: "Mine", course: nil, due: date(2026, 11, 6), kind: .assignment)
        store.applyNotion([item("p1", "HW 9")])
        store.removeNotionTasks()
        XCTAssertEqual(store.timetable.tasks.map(\.title), ["Mine"])
    }
}

final class NotionFreshnessTests: XCTestCase {

    func testStaleness() {
        let now = date(2026, 11, 2, 12)
        XCTAssertTrue(NotionFreshness.isStale(nil, now: now, maxAge: 3600), "Never synced is stale")
        XCTAssertFalse(NotionFreshness.isStale(now.addingTimeInterval(-1800), now: now, maxAge: 3600))
        XCTAssertTrue(NotionFreshness.isStale(now.addingTimeInterval(-5 * 3600), now: now, maxAge: NotionFreshness.widgetMaxAge))
    }

    func testMorningRefreshIsTheNextEarlyMorning() {
        XCTAssertEqual(NotionFreshness.nextMorning(after: date(2026, 11, 2, 3)), date(2026, 11, 2, 5))
        XCTAssertEqual(NotionFreshness.nextMorning(after: date(2026, 11, 2, 9)), date(2026, 11, 3, 5))
    }
}
