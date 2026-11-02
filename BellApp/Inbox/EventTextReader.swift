import Foundation

/// What one captured piece of text appears to describe.
struct InboxReading: Equatable {
    var title: String
    var start: Date?
    var end: Date?
    /// False when only a day was found. Then `start` is the start of that
    /// day (or 23:59 for a deadline), and the UI shows a date, not a time.
    var hasTime: Bool
    var location: String?
    var course: String?
    var kind: TaskEvent.Kind
    /// The AI Override word found in the text, if any.
    var keyword: String?
}

/// The non-AI reader: Foundation's own date detector plus Bell's knowledge
/// of its courses and buildings.
///
/// It runs on every capture whether or not Apple Intelligence is available,
/// and its answer is what the model is checked against. Two readers that
/// fail differently agreeing is worth more than either one's confidence in
/// itself.
enum EventTextReader {

    static func read(_ text: String, courses: [String], now: Date = .now,
                     calendar: Calendar = .current) -> InboxReading {
        let kind = kind(of: text)
        let (start, end, hasTime, dateRange) = when(in: text, kind: kind, calendar: calendar)
        let course = course(in: text, courses: courses)
        return InboxReading(
            title: title(from: text, removing: dateRange, course: course, kind: kind),
            start: start,
            end: end,
            hasTime: hasTime,
            location: location(in: text),
            course: course,
            kind: kind,
            keyword: AIOverride.keyword(in: text))
    }

    // MARK: - When

    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}(:\d{2})?\s*(a\.?m\.?|p\.?m\.?)|\d{1,2}:\d{2}|noon|midnight)\b"#,
        options: .caseInsensitive)

    private static func when(in text: String, kind: TaskEvent.Kind,
                             calendar: Calendar) -> (Date?, Date?, Bool, Range<String.Index>?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let detected = match.date,
              let range = Range(match.range, in: text)
        else { return (nil, nil, false, nil) }

        let matched = String(text[range])
        let hasTime = timePattern.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)) != nil

        // "due December 3" comes back as a span from now until December 3:
        // `date` is today and the deadline is the end. Read naively, every
        // "due ..." message was dated today, and with a keyword in it,
        // auto-added as due today.
        let lead = matched.lowercased()
        var date = detected
        if match.duration > 0,
           ["due", "by", "until", "before", "no later than"].contains(where: { lead.hasPrefix($0) }) {
            date = date.addingTimeInterval(match.duration)
            if !hasTime {
                let day = calendar.startOfDay(for: date)
                return (calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day) ?? day, nil, false, range)
            }
            return (date, nil, true, range)
        }

        if !hasTime {
            // "Due Friday" means by the end of Friday, not at noon, which is
            // where the detector puts a bare date.
            let day = calendar.startOfDay(for: date)
            let start = kind == .assignment || kind == .project
                ? calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day) ?? day
                : day
            return (start, nil, false, range)
        }

        let end = match.duration > 0 ? date.addingTimeInterval(match.duration) : nil
        return (date, end, true, range)
    }

    private static let datePhrase = try! NSRegularExpression(pattern:
        #"\b(today|tonight|tomorrow|tmrw|tmr|tmw|tonite|yesterday|next week|this week|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?|noon|midnight|\d{1,2}[/.-]\d{1,2}|\d{1,2}(:\d{2})?\s*(am|pm)|\d{1,2}:\d{2})\b"#,
        options: .caseInsensitive)

    /// Whether the text says anything about *when* at all. A date the model
    /// produced for text that doesn't is invented, whatever its confidence.
    static func mentionsTime(_ text: String) -> Bool {
        datePhrase.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - What

    /// Ordered: the first family that matches wins, so "final exam review
    /// session" is an exam, and "exam room booking meeting" is too.
    private static let kinds: [(TaskEvent.Kind, [String])] = [
        (.exam, ["exam", "midterm", "final"]),
        (.quiz, ["quiz"]),
        (.project, ["project", "demo", "presentation"]),
        (.assignment, ["deadline", "due", "submit", "submission", "homework", "hw", "assignment", "report", "lab report"]),
        (.meeting, ["interview", "meeting", "office hours", "appointment", "session"]),
    ]

    static func kind(of text: String) -> TaskEvent.Kind {
        for (kind, words) in kinds where words.contains(where: { containsWord($0, in: text) }) {
            return kind
        }
        return .other
    }

    /// Whole words only: "final" must not match "finally", "hw" must not
    /// match "shower".
    static func containsWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: #"\b\#(escaped)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Which course

    private static let codePattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,5})\s?(\d{3,5})([A-Z]?)\b"#)

    /// A course the user actually takes, from how people write it: the full
    /// "ECE 30200", the squashed "ECE30200", or the three-digit "ECE 302"
    /// that the five-digit renumbering didn't change in anyone's speech.
    static func course(in text: String, courses: [String]) -> String? {
        let matches = codePattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let subjectRange = Range(match.range(at: 1), in: text),
                  let numberRange = Range(match.range(at: 2), in: text) else { continue }
            let subject = String(text[subjectRange])
            let number = String(text[numberRange])
            let suffix = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""

            let candidates = courses.filter { course in
                let parts = course.replacingOccurrences(of: "TA: ", with: "").split(separator: " ")
                guard parts.count == 2, parts[0] == subject else { return false }
                return parts[1].hasPrefix(number)
            }
            // Prefer the exact section ("30864L" when the text says L), then
            // the lecture over its lab when the text doesn't say.
            if let exact = candidates.first(where: { $0.hasSuffix(number + suffix) && !suffix.isEmpty }) {
                return exact
            }
            if let lecture = candidates.sorted(by: { $0.count < $1.count }).first {
                return lecture
            }
        }
        return nil
    }

    // MARK: - Where

    private static let roomPattern = try! NSRegularExpression(pattern: #"\b([A-Z]{2,5})\s?(\d{1,4}[A-Z]?)\b"#)

    /// "MSEE 180" when a known building is followed by a room number, else
    /// the building alone, else nil. Course codes share the shape, so the
    /// building must be one Bell has coordinates for.
    static func location(in text: String) -> String? {
        for match in roomPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let b = Range(match.range(at: 1), in: text),
                  let r = Range(match.range(at: 2), in: text) else { continue }
            let building = String(text[b])
            if Campus.coordinate(for: building) != nil {
                return "\(building) \(text[r])"
            }
        }
        return Campus.building(in: text)
    }

    // MARK: - Title

    /// The first real line, without the date phrase that's now shown as a
    /// date. Short, because it becomes a row title.
    static func title(from text: String, removing dateRange: Range<String.Index>?,
                      course: String?, kind: TaskEvent.Kind) -> String {
        var source = text
        if let dateRange { source.replaceSubrange(dateRange, with: " ") }

        let line = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 3 } ?? ""

        var cleaned = line.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // A date pulled from the middle leaves "Midterm on  in EE 129" or a
        // dangling "at".
        cleaned = cleaned.replacingOccurrences(of: #"\s+(on|at|by|from)\s*$"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))

        if cleaned.count > 70 {
            cleaned = String(cleaned.prefix(67)).trimmingCharacters(in: .whitespaces) + "…"
        }
        if cleaned.isEmpty {
            return [course, kind == .other ? nil : kind.rawValue.capitalized]
                .compactMap { $0 }.joined(separator: " ").ifEmpty("Untitled")
        }
        return cleaned
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
