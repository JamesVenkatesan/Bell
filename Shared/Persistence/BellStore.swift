import Foundation
import SwiftData
import SwiftUI
import WidgetKit

/// The app's single front door to persistence.
///
/// Everything that changes durable state goes through here, and every write
/// ends by republishing the widget snapshot. That pairing is the point: a
/// write that doesn't refresh the snapshot produces a widget that disagrees
/// with the app, which is the bug class this type exists to make impossible.
///
/// Lives in the app process only. The widget reads `SnapshotCache`.
@MainActor
@Observable
final class BellStore {

    static let shared = BellStore()

    private(set) var timetable: Timetable = .empty
    /// Rebuilt with the timetable on every save, so dismissing an inbox item
    /// redraws the inbox even though the timetable didn't change.
    private(set) var inbox: [InboxEntry] = []
    private(set) var lastError: String?

    let container: ModelContainer

    private var context: ModelContext { container.mainContext }

    // MARK: - Setup

    init(inMemory: Bool = false) {
        let schema = Schema(BellSchema.all)

        let configuration: ModelConfiguration = {
            if inMemory {
                return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            }
            // Living in the App Group means a future extension — a share
            // sheet, a Shortcuts action — can write here too.
            if AppGroup.isAvailable {
                return ModelConfiguration(
                    schema: schema,
                    groupContainer: .identifier(AppGroup.identifier))
            }
            return ModelConfiguration(schema: schema)
        }()

        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // A container that won't open is unrecoverable, but crashing on
            // launch is worse than running on a throwaway store: the user can
            // still re-import, and the error surfaces in Settings.
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            lastError = "Could not open the database: \(error.localizedDescription)"
        }

        if !inMemory { LegacyMigration.runIfNeeded(into: self) }
        refresh()
    }

    // MARK: - Reading

    /// Rebuilds the value-type view of the database and republishes the
    /// snapshot. Called after every mutation.
    func refresh() {
        timetable = buildTimetable()
        inbox = buildInbox()
        SnapshotCache.write(timetable)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func buildTimetable() -> Timetable {
        var result = Timetable()

        let courses = (try? context.fetch(FetchDescriptor<StoredCourse>())) ?? []
        result.events = courses.flatMap { course in
            course.meetings.map { meeting in
                ClassEvent(
                    course: course.code,
                    room: meeting.room,
                    dayIndex: meeting.dayIndex,
                    startSecond: meeting.startSecond,
                    endSecond: meeting.endSecond,
                    weekIndex: meeting.weekIndex,
                    instructor: course.instructor)
            }
        }
        .sorted { ($0.dayIndex, $0.startSecond) < ($1.dayIndex, $1.startSecond) }

        let tasks = (try? context.fetch(FetchDescriptor<StoredTask>())) ?? []
        result.tasks = tasks.map {
            // Minting a fresh UUID per read made every task a stranger to the
            // last refresh: a row couldn't be found again to mark done, and
            // SwiftUI rebuilt the whole list on every write.
            if $0.uid == nil { $0.uid = UUID() }
            return TaskEvent(id: $0.uid!,
                      title: $0.title,
                      course: $0.courseCode,
                      due: $0.due,
                      kind: TaskEvent.Kind(rawValue: $0.kindRaw) ?? .other,
                      isDone: $0.isDone,
                      addedAutomatically: $0.addedAutomatically,
                      location: $0.location,
                      end: $0.end,
                      isAllDay: $0.isAllDay,
                      fromNotion: $0.notionPageID == nil ? nil : true)
        }

        let exceptions = (try? context.fetch(FetchDescriptor<StoredException>())) ?? []
        result.exceptions = exceptions.map {
            ScheduleException(name: $0.name, start: $0.start, end: $0.end)
        }

        let cancellations = (try? context.fetch(FetchDescriptor<StoredCancellation>())) ?? []
        result.cancelled = Set(cancellations.map(\.key))

        if let term = currentTerm {
            result.termStart = term.start
            result.termEnd = term.end
            result.weekCount = term.weekCount
            result.showsWeekends = term.showsWeekends
            result.rotationAnchor = term.start
        }

        return result
    }

    /// A fresh engine over the current snapshot. Cheap — the engine is a
    /// struct holding a value type — so views can read it per body pass
    /// without caching.
    var engine: ScheduleEngine { ScheduleEngine(timetable: timetable) }

    var palette: [String: Color] { SnapshotCache.palette() }

    var currentTerm: StoredTerm? {
        (try? context.fetch(FetchDescriptor<StoredTerm>()))?.first
    }

    func course(code: String) -> StoredCourse? {
        let descriptor = FetchDescriptor<StoredCourse>(
            predicate: #Predicate { $0.code == code })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Replacing the schedule
    //
    // Import is destructive by nature, so it keeps a snapshot of what it
    // replaced. `undoLastImport()` restores it.

    func replaceSchedule(with timetable: Timetable,
                         source: CaptureSource,
                         summary: String) {
        let previous = try? JSONEncoder.bell.encode(self.timetable)

        for course in (try? context.fetch(FetchDescriptor<StoredCourse>())) ?? [] {
            context.delete(course)   // cascades to meetings
        }

        // Colours are assigned here, once, and stored. Doing it at render time
        // would mean a course changing colour whenever the course list does.
        let families = Array(Set(timetable.events.map(\.courseFamily))).sorted()
        var familyIndex: [String: Int] = [:]
        for (index, family) in families.enumerated() {
            familyIndex[family] = index
        }

        var created: [String: StoredCourse] = [:]
        for event in timetable.events {
            let stored = created[event.course] ?? {
                let course = StoredCourse(
                    code: event.course,
                    instructor: event.instructor,
                    colorIndex: familyIndex[event.courseFamily] ?? 0,
                    kind: Self.inferKind(from: event))
                context.insert(course)
                created[event.course] = course
                return course
            }()

            if stored.instructor == nil, let instructor = event.instructor {
                stored.instructor = instructor
            }

            let meeting = StoredMeeting(
                dayIndex: event.dayIndex,
                startSecond: event.startSecond,
                endSecond: event.endSecond,
                weekIndex: event.weekIndex,
                room: event.room)
            meeting.course = stored
            context.insert(meeting)
        }

        applyTerm(from: timetable)
        applyExceptions(from: timetable)

        context.insert(ImportRecord(source: source,
                                    summary: summary,
                                    previousSnapshot: previous))
        save()
    }

    private static func inferKind(from event: ClassEvent) -> CourseKind {
        if event.isTeaching { return .teaching }
        if event.room.lowercased().contains("remote")
            || event.room.lowercased().contains("online") { return .remote }
        if event.course.hasSuffix("L") { return .lab }
        if event.course.hasSuffix("R") { return .recitation }
        return .lecture
    }

    private func applyTerm(from timetable: Timetable) {
        guard let start = timetable.termStart, let end = timetable.termEnd else { return }
        if let existing = currentTerm {
            existing.start = start
            existing.end = end
            existing.weekCount = timetable.weekCount
            existing.showsWeekends = timetable.showsWeekends
        } else {
            context.insert(StoredTerm(start: start,
                                      end: end,
                                      weekCount: timetable.weekCount,
                                      showsWeekends: timetable.showsWeekends))
        }
    }

    private func applyExceptions(from timetable: Timetable) {
        for existing in (try? context.fetch(FetchDescriptor<StoredException>())) ?? [] {
            context.delete(existing)
        }
        for exception in timetable.exceptions {
            context.insert(StoredException(name: exception.name,
                                           start: exception.start,
                                           end: exception.end))
        }
    }

    /// Removes every course and meeting, keeping term dates and breaks.
    ///
    /// Snapshots first, like any import, so a clear is as reversible as
    /// anything else. Destructive and instant is fine; destructive and
    /// unrecoverable is not.
    func clearSchedule() {
        let previous = try? JSONEncoder.bell.encode(timetable)

        for course in (try? context.fetch(FetchDescriptor<StoredCourse>())) ?? [] {
            context.delete(course)   // cascades to meetings
        }

        context.insert(ImportRecord(source: .manual,
                                    summary: "Cleared schedule",
                                    previousSnapshot: previous))
        Preferences.hiddenCourses = []
        save()
    }

    /// Replaces the schedule outright, skipping review.
    ///
    /// The diff exists because an import can be wrong in ways you'd want to
    /// catch. When you already know the incoming data is right — a fresh
    /// export replacing a stale schedule — reviewing a list of changes that
    /// are all "yes, obviously" is friction with no safety value.
    func replaceScheduleDirectly(with timetable: Timetable, source: CaptureSource) {
        replaceSchedule(with: timetable,
                        source: source,
                        summary: "Replaced with \(timetable.events.count) meetings")
    }

    func undoLastImport() {
        var descriptor = FetchDescriptor<ImportRecord>(
            sortBy: [SortDescriptor(\.performedAt, order: .reverse)])
        descriptor.fetchLimit = 1

        guard
            let record = (try? context.fetch(descriptor))?.first,
            let data = record.previousSnapshot,
            let restored = try? JSONDecoder.bell.decode(Timetable.self, from: data)
        else { return }

        context.delete(record)
        replaceSchedule(with: restored, source: .manual, summary: "Undid previous import")
    }

    // MARK: - Term and breaks

    func setTerm(start: Date, end: Date) {
        if let term = currentTerm {
            term.start = start
            term.end = end
        } else {
            context.insert(StoredTerm(start: start, end: end))
        }
        save()
    }

    func addException(name: String, start: Date, end: Date) {
        context.insert(StoredException(name: name, start: start, end: end))
        save()
    }

    func removeException(named name: String) {
        for exception in (try? context.fetch(FetchDescriptor<StoredException>())) ?? []
        where exception.name == name {
            context.delete(exception)
        }
        save()
    }

    // MARK: - Courses

    func setHidden(_ hidden: Bool, forCourse code: String) {
        course(code: code)?.isHidden = hidden
        // Mirrored into defaults because the widget reads this on every
        // timeline entry and shouldn't have to parse the snapshot for it.
        var current = Preferences.hiddenCourses
        if hidden { current.insert(code) } else { current.remove(code) }
        Preferences.hiddenCourses = current
        save()
    }

    // MARK: - Inbox

    private func buildInbox() -> [InboxEntry] {
        let descriptor = FetchDescriptor<InboxItem>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).map { item in
            if item.uid == nil { item.uid = UUID() }
            return InboxEntry(
                id: item.uid!,
                title: item.title,
                start: item.proposedDate,
                end: item.proposedEnd,
                hasTime: item.hasTime ?? true,
                location: item.location,
                course: item.courseCode,
                kind: TaskEvent.Kind(rawValue: item.kindRaw ?? "") ?? .other,
                source: item.source,
                confidence: item.confidence,
                state: item.state,
                wasAutoAccepted: item.wasAutoAccepted,
                keyword: item.matchedKeyword,
                caution: item.caution,
                rawText: item.rawText,
                capturedAt: item.capturedAt,
                taskID: item.taskUID)
        }
    }

    @discardableResult
    func addInboxItem(_ result: InboxAgreement.Result,
                      source: CaptureSource,
                      rawText: String) -> UUID {
        let reading = result.reading
        let item = InboxItem(title: reading.title,
                             proposedDate: reading.start,
                             proposedEnd: reading.end,
                             location: reading.location,
                             courseCode: reading.course,
                             source: source,
                             confidence: result.confidence,
                             rawText: rawText)
        item.kindRaw = reading.kind.rawValue
        item.hasTime = reading.hasTime
        item.matchedKeyword = reading.keyword
        item.caution = result.caution
        context.insert(item)
        save()
        return item.uid ?? UUID()
    }

    /// Turns an inbox item into a task. `automatic` is the AI Override path:
    /// recorded on both the item and the task so every screen can label it.
    func accept(inboxID id: UUID, edited: InboxReading? = nil, automatic: Bool = false) {
        guard let item = inboxItem(id: id) else { return }
        if let edited {
            item.title = edited.title
            item.proposedDate = edited.start
            item.proposedEnd = edited.end
            item.hasTime = edited.hasTime
            item.location = edited.location
            item.courseCode = edited.course
            item.kindRaw = edited.kind.rawValue
        }
        guard let due = item.proposedDate else { return }

        let task = StoredTask(title: item.title,
                              courseCode: item.courseCode,
                              due: due,
                              kind: TaskKind(rawValue: item.kindRaw ?? "") ?? .other,
                              notes: item.rawText,
                              origin: item.source)
        task.addedAutomatically = automatic
        task.location = item.location
        task.end = item.proposedEnd
        context.insert(task)

        item.taskUID = task.uid
        item.state = .accepted
        item.wasAutoAccepted = automatic
        save()
    }

    func dismiss(inboxID id: UUID) {
        inboxItem(id: id)?.state = .dismissed
        save()
    }

    /// Takes back an automatic add: the task goes, and the item returns to
    /// review where the user can decide for themselves.
    func undoAutomaticAdd(inboxID id: UUID) {
        guard let item = inboxItem(id: id) else { return }
        if let taskID = item.taskUID, let task = storedTask(id: taskID) {
            context.delete(task)
        }
        item.taskUID = nil
        item.state = .pending
        item.wasAutoAccepted = false
        save()
    }

    func deleteInboxItem(id: UUID) {
        if let item = inboxItem(id: id) { context.delete(item) }
        save()
    }

    private func inboxItem(id: UUID) -> InboxItem? {
        let descriptor = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.uid == id })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Widget taps

    /// Applies what widget buttons queued while the app wasn't running.
    func applyWidgetActions() {
        let actions = WidgetActions.pending()
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
            case .taskDone(let id):
                if let task = storedTask(id: id) { markDone(true, task) }
            case .attendance(let course, let start, let went):
                record(went ? .attended : .missed, forCourse: course, at: start)
            }
        }
        WidgetActions.clear()
        save()
    }

    // MARK: - Cancellations

    /// Marks single meetings as not happening. Idempotent: a key already
    /// cancelled is left alone, so a repeated sync can't pile up rows.
    func cancel(_ occurrences: [ScheduleEngine.Occurrence]) {
        guard !occurrences.isEmpty else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<StoredCancellation>())) ?? []).map(\.key))
        for occurrence in occurrences where !existing.contains(occurrence.key) {
            context.insert(StoredCancellation(key: occurrence.key,
                                              courseCode: occurrence.event.course,
                                              start: occurrence.start))
        }
        save()
    }

    func restore(cancellationKey key: String) {
        let descriptor = FetchDescriptor<StoredCancellation>(predicate: #Predicate { $0.key == key })
        for row in (try? context.fetch(descriptor)) ?? [] { context.delete(row) }
        save()
    }

    /// Upcoming and recent cancellations, for the list in Settings.
    func cancellations() -> [(key: String, course: String, start: Date)] {
        let descriptor = FetchDescriptor<StoredCancellation>(sortBy: [SortDescriptor(\.start)])
        return ((try? context.fetch(descriptor)) ?? []).map { ($0.key, $0.courseCode, $0.start) }
    }

    // MARK: - Tasks

    @discardableResult
    func addTask(title: String,
                 course: String?,
                 due: Date,
                 kind: TaskKind,
                 origin: CaptureSource? = .manual) -> UUID {
        let task = StoredTask(title: title, courseCode: course, due: due, kind: kind, origin: origin)
        context.insert(task)
        save()
        return task.uid ?? UUID()
    }

    func setTaskDone(_ done: Bool, id: UUID) {
        if let task = storedTask(id: id) { markDone(done, task) }
        save()
    }

    /// A Notion row remembers that the tick was yours, so the next sync,
    /// which rewrites everything else from Notion, keeps it.
    private func markDone(_ done: Bool, _ task: StoredTask) {
        task.isDone = done
        if task.notionPageID != nil { task.doneInBell = done }
    }

    // MARK: - Notion

    struct NotionApplied: Equatable {
        var added = 0, updated = 0, removed = 0
    }

    /// Makes Bell's Notion rows match `items` exactly, in one save.
    ///
    /// Notion is the source of truth for these rows, so an item that has
    /// gone from Notion goes from Bell. Only call this with a *complete*
    /// fetch: given a partial one it would delete the rest. Rows without a
    /// page ID are yours and are never read, changed or removed here.
    @discardableResult
    func applyNotion(_ items: [NotionItem]) -> NotionApplied {
        let mirrored = ((try? context.fetch(FetchDescriptor<StoredTask>())) ?? []).filter { $0.notionPageID != nil }
        var existing: [String: StoredTask] = [:]
        for task in mirrored {
            // A duplicate can only come from an interrupted earlier save;
            // keep one, drop the rest.
            if existing[task.notionPageID!] != nil { context.delete(task) } else { existing[task.notionPageID!] = task }
        }

        var result = NotionApplied()
        var seen = Set<String>()
        for item in items where seen.insert(item.pageID).inserted {
            let task: StoredTask
            if let found = existing[item.pageID] {
                task = found
                result.updated += 1
            } else {
                task = StoredTask(title: item.title, due: item.due, origin: .notion)
                task.notionPageID = item.pageID
                context.insert(task)
                result.added += 1
            }
            task.title = item.title
            task.courseCode = item.course
            task.due = item.due
            task.isAllDay = item.isAllDay
            task.end = item.end
            task.kind = TaskKind(rawValue: item.kind.rawValue) ?? .other
            task.isDone = item.isDone || (task.doneInBell ?? false)
        }
        for (pageID, task) in existing where !seen.contains(pageID) {
            context.delete(task)
            result.removed += 1
        }
        save()
        return result
    }

    /// Disconnecting takes Notion's rows with it: they were only ever a
    /// mirror, and a mirror of nothing would go stale silently.
    func removeNotionTasks() {
        for task in (try? context.fetch(FetchDescriptor<StoredTask>())) ?? [] where task.notionPageID != nil {
            context.delete(task)
        }
        save()
    }

    func deleteTask(id: UUID) {
        if let task = storedTask(id: id) { context.delete(task) }
        save()
    }

    private func storedTask(id: UUID) -> StoredTask? {
        let descriptor = FetchDescriptor<StoredTask>(predicate: #Predicate { $0.uid == id })
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Attendance

    func record(_ state: AttendanceState,
                forCourse code: String,
                at date: Date,
                automatic: Bool = false) {
        let key = "\(code)|\(date.timeIntervalSince1970)"
        let descriptor = FetchDescriptor<AttendanceRecord>(
            predicate: #Predicate { $0.key == key })

        if let existing = (try? context.fetch(descriptor))?.first {
            // A geofence never overrules the user. If they marked it
            // themselves, they know something the GPS doesn't.
            if automatic, !existing.wasAutomatic { return }
            existing.state = state
            existing.wasAutomatic = automatic
        } else {
            context.insert(AttendanceRecord(courseCode: code,
                                            date: date,
                                            state: state,
                                            wasAutomatic: automatic))
        }
        WidgetActions.noteMarked(WidgetModel.attendanceKey(course: code, start: date))
        save()
    }

    /// Every recorded meeting of a course, as values the views can hold.
    func attendance(forCourse code: String) -> [AttendanceEntry] {
        let descriptor = FetchDescriptor<AttendanceRecord>(
            predicate: #Predicate { $0.courseCode == code },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).map {
            AttendanceEntry(date: $0.date, state: $0.state, wasAutomatic: $0.wasAutomatic)
        }
    }

    /// Every attendance record, for the weekly review.
    func allAttendance() -> [(course: String, entry: AttendanceEntry)] {
        ((try? context.fetch(FetchDescriptor<AttendanceRecord>())) ?? []).map {
            ($0.courseCode, AttendanceEntry(date: $0.date, state: $0.state, wasAutomatic: $0.wasAutomatic))
        }
    }

    /// Attended over recorded, or nil when nothing has been recorded yet —
    /// which is different from zero and should read differently in the UI.
    func attendanceRate(forCourse code: String) -> Double? {
        let descriptor = FetchDescriptor<AttendanceRecord>(
            predicate: #Predicate { $0.courseCode == code })
        let records = (try? context.fetch(descriptor)) ?? []
        guard !records.isEmpty else { return nil }

        let attended = records.filter { $0.state == .attended }.count
        return Double(attended) / Double(records.count)
    }

    // MARK: - Saving

    private func save() {
        do {
            try context.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

/// A value-type view of one `AttendanceRecord`.
struct AttendanceEntry: Hashable {
    var date: Date
    var state: AttendanceState
    var wasAutomatic: Bool
}

/// A value-type view of one `InboxItem`.
struct InboxEntry: Identifiable, Hashable {
    var id: UUID
    var title: String
    var start: Date?
    var end: Date?
    var hasTime: Bool
    var location: String?
    var course: String?
    var kind: TaskEvent.Kind
    var source: CaptureSource
    var confidence: Double
    var state: InboxState
    var wasAutoAccepted: Bool
    var keyword: String?
    var caution: String?
    var rawText: String?
    var capturedAt: Date
    var taskID: UUID?

    var reading: InboxReading {
        InboxReading(title: title, start: start, end: end, hasTime: hasTime,
                     location: location, course: course, kind: kind, keyword: keyword)
    }
}
