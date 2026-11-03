import Foundation

// MARK: - Core model

/// A single recurring meeting in the weekly grid.
struct ClassEvent: Codable, Hashable, Identifiable {
    var id: String { "\(course)-\(weekIndex)-\(dayIndex)-\(startSecond)" }

    /// Course code as shown to the user, e.g. "ECE 30200".
    var course: String
    /// Room / location string, e.g. "WALC 1018". May be empty.
    var room: String
    /// 0 = Monday … 6 = Sunday.
    var dayIndex: Int
    /// Seconds since local midnight.
    var startSecond: Int
    var endSecond: Int
    /// Rotation week for A/B schedules. 0 when the timetable has a single week.
    var weekIndex: Int

    /// Who teaches it, when the source says. Not part of identity: an
    /// instructor change is not a different class, and matching on it would
    /// make every staffing update look like a dropped section.
    var instructor: String? = nil

    var duration: Int { max(0, endSecond - startSecond) }

    var building: String? {
        let head = room.split(separator: " ").first.map(String.init)
        guard let head, !head.isEmpty, !Self.notBuildings.contains(head.uppercased()) else { return nil }
        return head
    }

    /// Room values that say where a class *isn't*. "REMOTE" was being
    /// treated as a building: watched as a geofence, looked up in Apple Maps,
    /// and listed as a building with no position.
    static let notBuildings: Set<String> = ["REMOTE", "ONLINE", "TBA", "TBD", "ARR", "ASYNC", "DIST", "WEB", "VIRTUAL", "ZOOM"]

    /// "ECE 30864L" and "ECE 30864" belong to the same course family, so they
    /// share a color. The trailing L/R/D marks lab, recitation, distance.
    var courseFamily: String {
        var s = course
        if let range = s.range(of: "TA: ") { s.removeSubrange(range) }
        if let last = s.last, "LRD".contains(last), s.dropLast().last?.isNumber == true {
            s = String(s.dropLast())
        }
        return s
    }

    var isTeaching: Bool { course.hasPrefix("TA: ") }

    func start(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(startSecond))
    }

    func end(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(endSecond))
    }
}

/// A one-off dated item: exam, deadline, project demo.
struct TaskEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var course: String?
    var due: Date
    var kind: Kind
    var isDone: Bool = false

    /// Added by Bell without asking. Optional, like the fields below, so a
    /// snapshot written before they existed still decodes: the widget can
    /// read an older snapshot than the app it ships with.
    var addedAutomatically: Bool? = nil
    var location: String? = nil
    var end: Date? = nil
    /// A day with no time: show "Thu", not "Thu 11:59 PM".
    var isAllDay: Bool? = nil
    /// Mirrors a Notion page, so a missing course reads as "Uncategorised"
    /// (Bell looked and found no match) rather than simply blank.
    var fromNotion: Bool? = nil

    var isAutomatic: Bool { addedAutomatically ?? false }
    var allDay: Bool { isAllDay ?? false }

    enum Kind: String, Codable, CaseIterable {
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
}

/// A stretch of the calendar with no classes: fall break, finals, semester end.
struct ScheduleException: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date

    /// Whole days, inclusive. Breaks are stored as dates (Labor Day is
    /// `start == end == 7 Sep 00:00`), so comparing instants matched only
    /// midnight: at 9am on a break the widget showed the normal schedule.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }
}

/// The whole timetable plus everything the widget needs to reason about dates.
struct Timetable: Codable, Hashable {
    var events: [ClassEvent] = []
    var tasks: [TaskEvent] = []
    var exceptions: [ScheduleException] = []

    /// How many weeks the rotation runs for. 1 = every week is the same.
    var weekCount: Int = 1
    /// Anchor for computing which rotation week a date falls in.
    var rotationAnchor: Date = .distantPast
    /// First and last day of term. Outside this range the widget goes quiet.
    var termStart: Date?
    var termEnd: Date?

    var showsWeekends: Bool = false

    /// Single meetings that won't happen: a lecture the professor cancelled,
    /// marked by deleting it from Bell's calendar. Keyed by
    /// `ScheduleEngine.Occurrence.key`.
    var cancelled: Set<String> = []

    var courses: [String] {
        Array(Set(events.map(\.course))).sorted()
    }

    static let empty = Timetable()
}

extension Timetable {
    private enum CodingKeys: String, CodingKey {
        case events, tasks, exceptions, weekCount, rotationAnchor
        case termStart, termEnd, showsWeekends, cancelled
    }

    /// Written by hand so a field added later decodes as its default. The
    /// widget can read a snapshot written by the previous build before the
    /// app has run once; a synthesised decoder would throw on the missing
    /// key and the widget would fall back to the bundled schedule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        events = try c.decodeIfPresent([ClassEvent].self, forKey: .events) ?? []
        tasks = try c.decodeIfPresent([TaskEvent].self, forKey: .tasks) ?? []
        exceptions = try c.decodeIfPresent([ScheduleException].self, forKey: .exceptions) ?? []
        weekCount = try c.decodeIfPresent(Int.self, forKey: .weekCount) ?? 1
        rotationAnchor = try c.decodeIfPresent(Date.self, forKey: .rotationAnchor) ?? .distantPast
        termStart = try c.decodeIfPresent(Date.self, forKey: .termStart)
        termEnd = try c.decodeIfPresent(Date.self, forKey: .termEnd)
        showsWeekends = try c.decodeIfPresent(Bool.self, forKey: .showsWeekends) ?? false
        cancelled = try c.decodeIfPresent(Set<String>.self, forKey: .cancelled) ?? []
    }
}

extension Optional {
    /// `self` if it passes the test, otherwise nil. Reads better than a
    /// `flatMap` with a ternary when filtering "the next class" by visibility.
    func keeping(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
        guard let self, isIncluded(self) else { return nil }
        return self
    }
}
