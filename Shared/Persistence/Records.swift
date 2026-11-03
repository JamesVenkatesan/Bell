import Foundation
import SwiftData

// MARK: - Schema
//
// The durable shape of Bell's data. These are records, not the types the UI
// and the scheduling engine work with — those stay as plain value types in
// Models.swift, derived from these on read.
//
// The split is deliberate. Value types are trivially testable and can't be
// mutated behind your back; SwiftData objects are live, tied to a context,
// and unsafe to hand across threads. Keeping the engine on value types means
// the scheduling logic never has to think about persistence at all.
//
// The schema covers what later phases need — attendance history, an inbox
// queue, an import audit trail — so adding those features doesn't mean
// another migration.

@Model
final class StoredCourse {
    /// Stable identity across re-imports. A course is matched on `code`, so
    /// re-importing a schedule updates the existing row rather than
    /// duplicating it.
    @Attribute(.unique) var code: String

    var title: String?
    var instructor: String?
    var credits: Int?

    /// Index into the palette ramp. Assigned once and kept, so a course
    /// doesn't change colour when you add or drop something else.
    var colorIndex: Int

    /// Hidden courses stay in the database but never reach a widget.
    var isHidden: Bool

    var kindRaw: String

    @Relationship(deleteRule: .cascade, inverse: \StoredMeeting.course)
    var meetings: [StoredMeeting]

    init(code: String,
         title: String? = nil,
         instructor: String? = nil,
         credits: Int? = nil,
         colorIndex: Int = 0,
         isHidden: Bool = false,
         kind: CourseKind = .lecture) {
        self.code = code
        self.title = title
        self.instructor = instructor
        self.credits = credits
        self.colorIndex = colorIndex
        self.isHidden = isHidden
        self.kindRaw = kind.rawValue
        self.meetings = []
    }

    var kind: CourseKind {
        get { CourseKind(rawValue: kindRaw) ?? .lecture }
        set { kindRaw = newValue.rawValue }
    }

    /// Lecture and lab sections of the same course share a colour. The
    /// trailing L/R/D marks lab, recitation, distance.
    var family: String {
        var s = code
        if let range = s.range(of: "TA: ") { s.removeSubrange(range) }
        if let last = s.last, "LRD".contains(last), s.dropLast().last?.isNumber == true {
            s = String(s.dropLast())
        }
        return s
    }
}

enum CourseKind: String, Codable, CaseIterable {
    case lecture, lab, recitation, teaching, remote, other

    var symbol: String {
        switch self {
        case .lecture: "person.bubble"
        case .lab: "flask"
        case .recitation: "questionmark.bubble"
        case .teaching: "person.2"
        case .remote: "wifi"
        case .other: "circle"
        }
    }
}

@Model
final class StoredMeeting {
    /// 0 = Monday … 6 = Sunday.
    var dayIndex: Int
    /// Seconds since local midnight.
    var startSecond: Int
    var endSecond: Int
    /// Rotation week for A/B schedules; 0 when there's a single week.
    var weekIndex: Int

    var room: String

    /// Section-level date range from the registrar. A lab that starts two days
    /// after the lecture, or a LabP that ends early, is common enough that
    /// treating every meeting as running the whole term produces wrong answers
    /// in the first and last weeks.
    var activeFrom: Date?
    var activeUntil: Date?

    var course: StoredCourse?

    init(dayIndex: Int,
         startSecond: Int,
         endSecond: Int,
         weekIndex: Int = 0,
         room: String = "",
         activeFrom: Date? = nil,
         activeUntil: Date? = nil) {
        self.dayIndex = dayIndex
        self.startSecond = startSecond
        self.endSecond = endSecond
        self.weekIndex = weekIndex
        self.room = room
        self.activeFrom = activeFrom
        self.activeUntil = activeUntil
    }

    var building: String? {
        let head = room.split(separator: " ").first.map(String.init)
        return head?.isEmpty == false ? head : nil
    }

    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        if let from = activeFrom, day < calendar.startOfDay(for: from) { return false }
        if let until = activeUntil, day > calendar.startOfDay(for: until) { return false }
        return true
    }
}

@Model
final class StoredException {
    var name: String
    var start: Date
    var end: Date

    init(name: String, start: Date, end: Date) {
        self.name = name
        self.start = start
        self.end = end
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }
}

/// One row. Term bounds and rotation length, which no export carries.
@Model
final class StoredTerm {
    var name: String
    var start: Date
    var end: Date
    var weekCount: Int
    var showsWeekends: Bool

    init(name: String = "Term",
         start: Date,
         end: Date,
         weekCount: Int = 1,
         showsWeekends: Bool = false) {
        self.name = name
        self.start = start
        self.end = end
        self.weekCount = weekCount
        self.showsWeekends = showsWeekends
    }
}

/// Dated one-offs: exams, deadlines, demos. Separate from meetings because
/// they don't recur and don't belong in the weekly grid.
@Model
final class StoredTask {
    /// Stable identity for the value-type mirror. Optional so adding it is a
    /// lightweight migration; `BellStore` fills it in on first read.
    var uid: UUID?
    var title: String
    var courseCode: String?
    var due: Date
    var kindRaw: String
    var isDone: Bool
    var notes: String?

    /// Set when this came from the inbox rather than being typed, so the UI
    /// can show where it came from and you can trust it accordingly.
    var originRaw: String?

    /// True when Bell added this without asking (AI Override). Optional so
    /// the column is a lightweight migration; nil reads as false. Every view
    /// that shows a task shows this, because an automatic add must never be
    /// mistakable for one the user made.
    var addedAutomatically: Bool?

    /// Where and until when, for things that are events rather than
    /// deadlines: an interview, a review session.
    var location: String?
    var end: Date?

    /// The Notion page this mirrors. Set only by the Notion sync, and the
    /// whole of how it tells its own rows from yours: a sync updates and
    /// removes rows with a page ID and never touches a row without one.
    var notionPageID: String?

    /// A deadline with a day but no time ("due Thursday"). Shown without a
    /// clock time instead of an invented "11:59 PM".
    var isAllDay: Bool?

    /// Ticked off in Bell. Kept apart from `isDone` for Notion rows because
    /// Bell never writes back: without it, the next sync would untick
    /// whatever you'd ticked in a widget.
    var doneInBell: Bool?

    init(title: String,
         courseCode: String? = nil,
         due: Date,
         kind: TaskKind = .other,
         isDone: Bool = false,
         notes: String? = nil,
         origin: CaptureSource? = nil) {
        self.title = title
        self.courseCode = courseCode
        self.due = due
        self.kindRaw = kind.rawValue
        self.isDone = isDone
        self.notes = notes
        self.originRaw = origin?.rawValue
        self.uid = UUID()
    }

    var kind: TaskKind {
        get { TaskKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

enum TaskKind: String, Codable, CaseIterable {
    case exam, assignment, quiz, project, meeting, other

    var symbol: String {
        switch self {
        case .exam: "pencil.and.list.clipboard"
        case .assignment: "doc.text"
        case .quiz: "questionmark.square"
        case .project: "hammer"
        case .meeting: "person.2"
        case .other: "flag"
        }
    }
}

/// Where a captured item came from. Used by the inbox and for provenance on
/// anything the AI proposed.
enum CaptureSource: String, Codable, CaseIterable {
    case shareSheet, screenshot, photo, pdf, calendar, email, manual, subscription, notion

    var label: String {
        switch self {
        case .shareSheet: "Shared"
        case .screenshot: "Screenshot"
        case .photo: "Photo"
        case .pdf: "PDF"
        case .calendar: "Calendar"
        case .email: "Email"
        case .manual: "Added by you"
        case .subscription: "Subscribed schedule"
        case .notion: "Notion"
        }
    }
}

/// Attendance, one row per occurrence. Lets Bell answer "how many 7:30s have
/// I actually made" without any manual bookkeeping.
@Model
final class AttendanceRecord {
    /// Occurrence identity: course code plus the exact start instant.
    @Attribute(.unique) var key: String
    var courseCode: String
    var date: Date
    var stateRaw: String
    /// True when a geofence marked it rather than you tapping.
    var wasAutomatic: Bool

    init(courseCode: String, date: Date, state: AttendanceState, wasAutomatic: Bool = false) {
        self.key = "\(courseCode)|\(date.timeIntervalSince1970)"
        self.courseCode = courseCode
        self.date = date
        self.stateRaw = state.rawValue
        self.wasAutomatic = wasAutomatic
    }

    var state: AttendanceState {
        get { AttendanceState(rawValue: stateRaw) ?? .unknown }
        set { stateRaw = newValue.rawValue }
    }
}

enum AttendanceState: String, Codable, CaseIterable {
    case attended, missed, excused, unknown
}

/// Something Bell noticed and wants you to confirm. Phase 4 fills this; the
/// schema is here now so that phase doesn't need a migration.
@Model
final class InboxItem {
    /// Stable identity for the value-type mirror; filled on first read.
    var uid: UUID?
    /// The task this became, once accepted, so an automatic add can be
    /// undone by removing exactly that task.
    var taskUID: UUID?
    /// Keywords that made this important ("exam", "interview"), kept so the
    /// UI can say *why* Bell acted on it.
    var matchedKeyword: String?
    /// Set when the two readers disagreed, in words.
    var caution: String?
    var kindRaw: String?
    /// False when only a day was read; nil (older rows) reads as true.
    var hasTime: Bool?

    var title: String
    var detail: String?
    var proposedDate: Date?
    var proposedEnd: Date?
    var location: String?
    var courseCode: String?

    var sourceRaw: String
    var capturedAt: Date

    /// 0…1, from the model. Low confidence means it gets shown but never
    /// auto-accepted.
    var confidence: Double

    /// True when this matched the important-keyword rules and was added
    /// without asking. The UI labels these so an automatic add is never
    /// mistaken for one you made.
    var wasAutoAccepted: Bool

    var stateRaw: String

    /// The original text, kept so you can see what the extraction was based on.
    var rawText: String?

    init(title: String,
         detail: String? = nil,
         proposedDate: Date? = nil,
         proposedEnd: Date? = nil,
         location: String? = nil,
         courseCode: String? = nil,
         source: CaptureSource,
         confidence: Double = 0.5,
         wasAutoAccepted: Bool = false,
         state: InboxState = .pending,
         rawText: String? = nil) {
        self.title = title
        self.detail = detail
        self.proposedDate = proposedDate
        self.proposedEnd = proposedEnd
        self.location = location
        self.courseCode = courseCode
        self.sourceRaw = source.rawValue
        self.capturedAt = .now
        self.confidence = confidence
        self.wasAutoAccepted = wasAutoAccepted
        self.stateRaw = state.rawValue
        self.rawText = rawText
        self.uid = UUID()
    }

    var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var state: InboxState {
        get { InboxState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

enum InboxState: String, Codable, CaseIterable {
    case pending, accepted, dismissed
}

/// An audit trail of schedule imports, so the diff-and-confirm screen can show
/// what changed and you can undo an import that got it wrong.
@Model
final class ImportRecord {
    var performedAt: Date
    var sourceRaw: String
    var summary: String
    /// JSON snapshot of the schedule as it was *before* this import.
    var previousSnapshot: Data?

    init(source: CaptureSource, summary: String, previousSnapshot: Data? = nil) {
        self.performedAt = .now
        self.sourceRaw = source.rawValue
        self.summary = summary
        self.previousSnapshot = previousSnapshot
    }

    var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}

/// One meeting that won't happen, though the weekly pattern says it will.
/// Created when you delete a single class from Bell's calendar, which is the
/// gesture people already use for "that lecture's cancelled".
@Model
final class StoredCancellation {
    @Attribute(.unique) var key: String
    var courseCode: String
    var start: Date
    var createdAt: Date

    init(key: String, courseCode: String, start: Date) {
        self.key = key
        self.courseCode = courseCode
        self.start = start
        self.createdAt = .now
    }
}

// MARK: - Schema registration

enum BellSchema {
    static let all: [any PersistentModel.Type] = [
        StoredCourse.self,
        StoredMeeting.self,
        StoredException.self,
        StoredTerm.self,
        StoredTask.self,
        AttendanceRecord.self,
        InboxItem.self,
        ImportRecord.self,
        StoredCancellation.self,
    ]
}
