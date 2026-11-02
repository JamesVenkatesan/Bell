import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Agreement

/// Combines the date detector's reading with the model's.
///
/// Same principle as the schedule importer: confidence is how much two
/// readers that fail differently agree, never a model's opinion of itself.
/// The detector is precise about dates and blind to meaning; the model is
/// good at titles and context and sometimes invents a date. Each covers the
/// other's weakness.
enum InboxAgreement {

    struct Result: Equatable {
        var reading: InboxReading
        var confidence: Double
        /// Said to the user, in words, when the readers disagree.
        var caution: String?
    }

    /// - Parameter text: the source. When the detector found no date, a date
    ///   from the model is kept only if the text mentions time at all. Run
    ///   for real, the model gave "Can you send me the slides from lab?"
    ///   today's date, despite being told never to invent one.
    static func merge(detector: InboxReading, model: InboxReading?, text: String? = nil,
                      calendar: Calendar = .current) -> Result {
        var model = model
        if detector.start == nil, let text, !EventTextReader.mentionsTime(text) {
            model?.start = nil
            model?.end = nil
            model?.hasTime = false
        }
        guard let model else {
            let confidence = detector.start == nil ? 0.2 : (detector.hasTime ? 0.7 : 0.55)
            return Result(reading: detector, confidence: confidence, caution: nil)
        }

        var merged = detector
        // The model writes better titles than "first line minus the date",
        // and often finds a place the regex can't.
        if !model.title.trimmingCharacters(in: .whitespaces).isEmpty { merged.title = model.title }
        if merged.location == nil { merged.location = model.location }
        if merged.course == nil { merged.course = model.course }
        if merged.kind == .other { merged.kind = model.kind }

        switch (detector.start, model.start) {
        case let (d?, m?):
            if agree(d, detector.hasTime, m, model.hasTime, calendar: calendar) {
                // Prefer whichever saw a time.
                if !detector.hasTime && model.hasTime {
                    merged.start = m; merged.hasTime = true; merged.end = model.end
                }
                if merged.end == nil { merged.end = model.end }
                return Result(reading: merged, confidence: 0.95, caution: nil)
            }
            return Result(reading: merged, confidence: 0.45,
                          caution: "Bell read two different times here: "
                            + describe(d, detector.hasTime) + " and " + describe(m, model.hasTime)
                            + ". It's showing the first; check it.")
        case let (nil, m?):
            merged.start = m; merged.end = model.end; merged.hasTime = model.hasTime
            return Result(reading: merged, confidence: 0.6,
                          caution: "Only Apple Intelligence found a date in this. Check it.")
        case (_?, nil):
            return Result(reading: merged, confidence: detector.hasTime ? 0.65 : 0.55, caution: nil)
        case (nil, nil):
            return Result(reading: merged, confidence: 0.2, caution: nil)
        }
    }

    /// Same day, and the same time to within five minutes when both have
    /// one. A reading with only a day agrees with any time on that day.
    private static func agree(_ a: Date, _ aTimed: Bool, _ b: Date, _ bTimed: Bool,
                              calendar: Calendar) -> Bool {
        guard calendar.isDate(a, inSameDayAs: b) else { return false }
        guard aTimed && bTimed else { return true }
        return abs(a.timeIntervalSince(b)) <= 5 * 60
    }

    private static func describe(_ date: Date, _ timed: Bool) -> String {
        timed ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
              : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - AI Override

/// The rule for adding something without asking.
///
/// The user asked for exams, deadlines, interviews, finals and mandatory
/// things to go straight in. The cost asymmetry is real: missing an exam is
/// much worse than an extra row. But an automatic add is only allowed when
/// Bell is sure of *when*, since a confidently wrong date is the one mistake
/// worse than none; everything else waits in review, keyword or not.
enum AIOverride {

    /// The user's list, plus "midterm" (an exam by another name).
    static let keywords = ["exam", "midterm", "final", "finals", "deadline", "interview", "mandatory"]

    /// Agreement between both readers, or a detector reading with a time
    /// that the model didn't contradict.
    static let confidenceFloor = 0.65

    /// The first keyword present as a whole word. "final" alone is too
    /// common ("final version", "final reminder") to act on, so it counts
    /// only next to something that makes it an assessment.
    static func keyword(in text: String) -> String? {
        for word in keywords where EventTextReader.containsWord(word, in: text) {
            if word == "final" {
                let assessment = ["exam", "test", "project", "presentation", "paper"]
                    .contains { EventTextReader.containsWord("final \($0)", in: text) }
                if !assessment { continue }
            }
            return word
        }
        return nil
    }

    enum Decision: Equatable {
        case add(keyword: String)
        case review
    }

    static func decide(_ result: InboxAgreement.Result, now: Date, calendar: Calendar = .current) -> Decision {
        guard let keyword = result.reading.keyword,
              let start = result.reading.start,
              result.confidence >= confidenceFloor,
              result.caution == nil
        else { return .review }

        // Already over: nothing to protect the user from missing.
        let stillAhead = result.reading.hasTime
            ? start > now
            : calendar.startOfDay(for: start) >= calendar.startOfDay(for: now)
        return stillAhead ? .add(keyword: keyword) : .review
    }
}

// MARK: - Model

/// Asks the on-device model to read a captured message.
///
/// Today's date goes in the prompt because "Friday" and "tomorrow" mean
/// nothing without it, and a model that guesses the current date guesses
/// wrong.
enum InboxModelReader {

    static func read(_ text: String, courses: [String], now: Date = .now) async -> InboxReading? {
        #if canImport(FoundationModels)
        guard IntelligentParser.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions(courses: courses))
        let prompt = """
            Today is \(now.formatted(.iso8601.year().month().day())), a \(now.formatted(.dateTime.weekday(.wide))).

            Text:
            \(String(text.prefix(2400)))
            """
        guard let response = try? await session.respond(to: prompt, generating: InboxDraft.self) else {
            return nil
        }
        return response.content.reading(courses: courses)
        #else
        return nil
        #endif
    }

    private static func instructions(courses: [String]) -> String {
        """
        You read a message, email or screenshot a student saved, and extract \
        the one dated thing it is about: an exam, a deadline, an interview, \
        a meeting.

        Rules:
        - Report the date as yyyy-MM-dd and times in 24-hour HH:mm.
        - Leave a field empty when the text does not say it. Never guess a \
        date or a time that isn't written; an empty field is correct.
        - The title is short, like "ECE 30200 midterm" or "Interview with Bose".
        - The student's courses are: \(courses.joined(separator: ", ")).
        """
    }
}

#if canImport(FoundationModels)
@Generable
struct InboxDraft {
    @Guide(description: "Short title, under 60 characters")
    var title: String

    @Guide(description: "Date as yyyy-MM-dd, or empty if no date is written")
    var date: String

    @Guide(description: "Start time, 24-hour HH:mm, or empty")
    var startTime: String

    @Guide(description: "End time, 24-hour HH:mm, or empty")
    var endTime: String

    @Guide(description: "Place, such as a room like MSEE 180, or empty")
    var location: String

    @Guide(description: "Course code from the student's list, or empty")
    var course: String

    @Guide(description: "One of: exam, quiz, assignment, project, meeting, other")
    var kind: String

    /// Anything that doesn't parse is dropped rather than guessed.
    func reading(courses: [String], calendar: Calendar = .current) -> InboxReading {
        var start: Date?
        var end: Date?
        var hasTime = false

        let dayParts = date.split(separator: "-").compactMap { Int($0) }
        if dayParts.count == 3,
           let day = calendar.date(from: DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2])) {
            if let s = Self.minutes(startTime) {
                start = calendar.date(byAdding: .minute, value: s, to: day)
                hasTime = true
                if let e = Self.minutes(endTime), e > s {
                    end = calendar.date(byAdding: .minute, value: e, to: day)
                }
            } else {
                start = day
            }
        }

        let trimmedCourse = course.trimmingCharacters(in: .whitespaces)
        return InboxReading(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: start,
            end: end,
            hasTime: hasTime,
            location: location.isEmpty ? nil : location,
            // Only courses the student actually takes: the model is told
            // the list, but a hallucinated code must not slip through.
            course: courses.contains(trimmedCourse) ? trimmedCourse : nil,
            kind: TaskEvent.Kind(rawValue: kind.lowercased()) ?? .other,
            keyword: nil)
    }

    private static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0 ..< 24).contains(parts[0]), (0 ..< 60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
#endif
