import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Question or instruction

/// One text field does both "when's my next class?" and "add a quiz for 302
/// on Friday at 10". Telling them apart has to be cheap and predictable, so
/// it's a rule, not a model call: a question mark or a question word means a
/// question, anything else is something to add.
enum AskIntent: Equatable {
    case question
    case instruction

    private static let questionWords = ["what", "when", "where", "which", "who", "how", "why",
                                        "am", "is", "are", "do", "does", "did", "can", "will", "should", "any"]

    static func classify(_ text: String) -> AskIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("?") { return .question }
        let first = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        let firstWord = first.replacingOccurrences(of: "'s", with: "")
        return questionWords.contains(firstWord) ? .question : .instruction
    }
}

// MARK: - Answers from facts

/// The questions people actually ask a timetable, answered exactly.
///
/// Asked first, before any model, because these answers must be right and a
/// lookup is always right. The model only sees what this doesn't recognise.
enum ScheduleQA {

    static func answer(_ question: String,
                       engine: ScheduleEngine,
                       busy: [ExternalEvent] = [],
                       hidden: Set<String> = [],
                       now: Date) -> String? {
        let q = question.lowercased()
        let calendar = engine.calendar
        let reading = EventTextReader.read(question, courses: engine.timetable.courses, now: now)
        let day = reading.start.map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: now)
        let visible = { (d: Date) in engine.occurrences(on: d).filter { !hidden.contains($0.event.course) } }
        let dayName = describeDay(day, now: now, calendar: calendar)

        // A course by name: "where is 302", "when's ECE 30100 next".
        if let course = reading.course,
           ["where", "when", "next", "what time", "room"].contains(where: q.contains) {
            guard let next = engine.upcomingOccurrences(ofCourse: course, after: now, limit: 1).first else {
                return "\(course) doesn't meet again in the next four weeks."
            }
            return "\(course) next meets \(describeDay(next.start, now: now, calendar: calendar)) at "
                + "\(BriefWriter.clock(next.start))\(room(next))."
        }

        if q.contains("next class") || q.contains("what's next") || q.contains("whats next") {
            guard let next = engine.next(after: now).keeping({ !hidden.contains($0.event.course) }) else {
                return "No classes in the next three weeks."
            }
            return "\(next.event.course) at \(BriefWriter.clock(next.start)) "
                + "\(describeDay(next.start, now: now, calendar: calendar))\(room(next))."
        }

        if q.contains("free") || q.contains("busy") || q.contains("available") {
            if let moment = moment(in: question, reading: reading) {
                if let lesson = visible(day).first(where: { $0.start <= moment && moment < $0.end }) {
                    return "No: \(lesson.event.course) runs \(BriefWriter.clock(lesson.start))–"
                        + "\(BriefWriter.clock(lesson.end))\(room(lesson))."
                }
                if let event = busy.first(where: { $0.occupiesTime && $0.start <= moment && moment < $0.end }) {
                    return "No: \(event.title) is on until \(BriefWriter.clock(event.end))."
                }
                let nextThing = visible(day).first { $0.start > moment }
                return nextThing.map { "Yes, free until \($0.event.course) at \(BriefWriter.clock($0.start))." }
                    ?? "Yes, nothing else is on after that \(dayName)."
            }
            let from = calendar.isDate(day, inSameDayAs: now) ? now : day
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let free = FreeTime.intervals(engine: engine, busy: busy, from: from, to: end)
            guard !free.isEmpty else { return "No free stretch of half an hour or more \(dayName)." }
            let spans = free.map { "\(BriefWriter.clock($0.start))–\(BriefWriter.clock($0.end))" }
            return "Free \(dayName): \(list(spans))."
        }

        if q.contains("due") || q.contains("deadline") || q.contains("homework") || q.contains("exam")
            || q.contains("assignment") {
            let (from, to): (Date, Date) = {
                if reading.start != nil {
                    return (day, calendar.date(byAdding: .day, value: 1, to: day) ?? day)
                }
                // No day named: the week ahead, which is what "what's due?" means.
                return (now, calendar.date(byAdding: .day, value: 7, to: now) ?? now)
            }()
            let due = engine.timetable.tasks.filter { !$0.isDone && $0.due >= from && $0.due < to }
                .sorted { $0.due < $1.due }
            guard !due.isEmpty else {
                return reading.start != nil ? "Nothing due \(dayName)." : "Nothing due in the next week."
            }
            return list(due.map { "\($0.title) \(describeDay($0.due, now: now, calendar: calendar)) at \(BriefWriter.clock($0.due))" })
                + "."
        }

        if q.contains("finish") || q.contains("last class") || q.contains("done for") || q.contains("get out") {
            guard let last = visible(day).last else { return "No classes \(dayName)." }
            return "Your last class \(dayName) is \(last.event.course), done at \(BriefWriter.clock(last.end))."
        }

        if q.contains("first class") || q.contains("how early") || q.contains("start") {
            guard let first = visible(day).first else { return "No classes \(dayName)." }
            return "\(first.event.course) at \(BriefWriter.clock(first.start)) \(dayName)\(room(first))."
        }

        if q.contains("how many") {
            let count = visible(day).count
            return count == 0 ? "No classes \(dayName)." : "\(count) class\(count == 1 ? "" : "es") \(dayName)."
        }

        return nil
    }

    /// The instant asked about, if the question names one. "At 3" has no
    /// am or pm, so the reader's time pattern misses it; the date detector
    /// does resolve it (to the afternoon, as people mean), so its hour is
    /// trusted when the question says "at" and a number.
    private static func moment(in question: String, reading: InboxReading) -> Date? {
        if reading.hasTime { return reading.start }
        guard question.range(of: #"\bat \d{1,2}\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: question, range: NSRange(question.startIndex..., in: question))
        else { return nil }
        return match.date
    }

    static func describeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        return "on " + date.formatted(.dateTime.weekday(.wide))
    }

    private static func room(_ occurrence: ScheduleEngine.Occurrence) -> String {
        occurrence.event.room.isEmpty ? "" : " in \(occurrence.event.room)"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    // MARK: - Grounding

    /// Times and course codes any true answer about the coming fortnight
    /// could mention. A model answer outside this vocabulary is rejected.
    static func vocabulary(engine: ScheduleEngine, busy: [ExternalEvent], now: Date)
        -> (times: Set<String>, courses: Set<String>) {
        let start = engine.calendar.date(byAdding: .day, value: -7, to: engine.calendar.startOfDay(for: now)) ?? now
        let occurrences = engine.occurrences(from: start, forwardDays: 22)
        var dates = occurrences.flatMap { [$0.start, $0.end] }
        dates += busy.flatMap { [$0.start, $0.end] }
        dates += engine.timetable.tasks.map(\.due)
        // Rooms share the course-code shape ("BHEE 170"), so they belong in
        // the same vocabulary or any answer naming a room is rejected.
        let courses = engine.timetable.courses.map { $0.replacingOccurrences(of: "TA: ", with: "") }
        let rooms = engine.timetable.events.map(\.room) + busy.compactMap(\.location)
            + engine.timetable.tasks.compactMap(\.location)
        return (Set(dates.map(BriefWriter.digits)), Set(courses + rooms))
    }

    static func isGrounded(_ answer: String, engine: ScheduleEngine, busy: [ExternalEvent], now: Date) -> Bool {
        let vocabulary = vocabulary(engine: engine, busy: busy, now: now)
        let times = matches(#"\b\d{1,2}:\d{2}\b"#, in: answer)
        let codes = matches(#"\b[A-Z]{2,5} \d{3,5}[A-Z]?\b"#, in: answer)
        return times.allSatisfy(vocabulary.times.contains) && codes.allSatisfy(vocabulary.courses.contains)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

// MARK: - Open questions

/// Everything ScheduleQA doesn't recognise goes to the on-device model, which
/// is given tools to look the schedule up rather than the schedule pasted
/// into its prompt. It asks for the days it needs, and every answer is
/// grounded against the real schedule before it's shown.
enum ScheduleChat {

    struct Reply: Equatable {
        var text: String
        var byModel: Bool
    }

    static let fallback = "I can answer questions about your classes, free time and what's due: "
        + "try \"am I free at 2 tomorrow?\" or \"what's due this week?\""

    static func reply(to question: String,
                      engine: ScheduleEngine,
                      busy: [ExternalEvent],
                      hidden: Set<String>,
                      now: Date = .now) async -> Reply {
        if let exact = ScheduleQA.answer(question, engine: engine, busy: busy, hidden: hidden, now: now) {
            return Reply(text: exact, byModel: false)
        }
        #if canImport(FoundationModels)
        guard IntelligentParser.isAvailable else { return Reply(text: fallback, byModel: false) }
        let tools: [any Tool] = [DayTool(engine: engine, busy: busy, hidden: hidden),
                                 TasksTool(tasks: engine.timetable.tasks)]
        let session = LanguageModelSession(tools: tools, instructions: """
            You answer a student's questions about their own schedule. Today is \
            \(now.formatted(.iso8601.year().month().day())), a \(now.formatted(.dateTime.weekday(.wide))). \
            Look things up with the tools; never answer from memory. Reply in one or two \
            plain sentences. If the tools don't contain the answer, say you don't know.
            """)
        guard let response = try? await session.respond(to: question),
              ScheduleQA.isGrounded(response.content, engine: engine, busy: busy, now: now)
        else { return Reply(text: fallback, byModel: false) }
        return Reply(text: response.content.trimmingCharacters(in: .whitespacesAndNewlines), byModel: true)
        #else
        return Reply(text: fallback, byModel: false)
        #endif
    }
}

#if canImport(FoundationModels)
/// One day's classes, other events and free time, as plain lines.
struct DayTool: Tool {
    let name = "day"
    let description = "Get one day's classes, other calendar events and free time."

    @Generable
    struct Arguments {
        @Guide(description: "The date, yyyy-MM-dd")
        var date: String
    }

    let engine: ScheduleEngine
    let busy: [ExternalEvent]
    let hidden: Set<String>

    func call(arguments: Arguments) async throws -> String {
        let parts = arguments.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = engine.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return "Unreadable date." }

        var lines: [String] = []
        if let holiday = engine.exception(on: day) { lines.append("Break: \(holiday.name)") }
        for o in engine.occurrences(on: day) where !hidden.contains(o.event.course) {
            lines.append("Class \(o.event.course) \(BriefWriter.clock(o.start))-\(BriefWriter.clock(o.end)) \(o.event.room)")
        }
        for e in busy where e.occupiesTime && engine.calendar.isDate(e.start, inSameDayAs: day) {
            lines.append("Event \(e.title) \(BriefWriter.clock(e.start))-\(BriefWriter.clock(e.end))")
        }
        let end = engine.calendar.date(byAdding: .day, value: 1, to: day) ?? day
        for f in FreeTime.intervals(engine: engine, busy: busy, from: day, to: end) {
            lines.append("Free \(BriefWriter.clock(f.start))-\(BriefWriter.clock(f.end))")
        }
        return lines.isEmpty ? "Nothing scheduled." : lines.joined(separator: "\n")
    }
}

/// Open work with due dates.
struct TasksTool: Tool {
    let name = "tasks"
    let description = "List the student's open exams, deadlines and other work, with due dates."

    @Generable
    struct Arguments {
        @Guide(description: "Ignored; pass an empty string")
        var unused: String
    }

    let tasks: [TaskEvent]

    func call(arguments: Arguments) async throws -> String {
        let open = tasks.filter { !$0.isDone }.sorted { $0.due < $1.due }
        guard !open.isEmpty else { return "No open work." }
        return open.map {
            "\($0.title) (\($0.kind.rawValue)\($0.course.map { ", \($0)" } ?? "")) due "
                + "\($0.due.formatted(.iso8601.year().month().day())) \(BriefWriter.clock($0.due))"
        }.joined(separator: "\n")
    }
}
#endif
