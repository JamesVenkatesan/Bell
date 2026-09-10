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

    var duration: Int { max(0, endSecond - startSecond) }

    var building: String? {
        let head = room.split(separator: " ").first.map(String.init)
        return head?.isEmpty == false ? head : nil
    }

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

    enum Kind: String, Codable, CaseIterable {
        case exam, assignment, quiz, project, other

        var symbol: String {
            switch self {
            case .exam: "pencil.and.list.clipboard"
            case .assignment: "doc.text"
            case .quiz: "questionmark.square"
            case .project: "hammer"
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

    func contains(_ date: Date) -> Bool {
        (start ... end).contains(date)
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

    var courses: [String] {
        Array(Set(events.map(\.course))).sorted()
    }

    static let empty = Timetable()
}
