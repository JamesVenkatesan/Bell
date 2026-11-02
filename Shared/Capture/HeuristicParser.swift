import Foundation

/// A deterministic parser for schedule text.
///
/// This exists for two reasons, and the second is the important one.
///
/// It handles the common case well: registrar exports are regular, and a
/// regular format deserves a parser that gets it exactly right every time
/// rather than one that is usually right.
///
/// More importantly, it gives the language model something to be checked
/// against. A model asked how confident it is will tell you 0.9 regardless, so
/// self-reported confidence is noise. Agreement between two parsers that work
/// in completely different ways is a real signal. Where they agree, a row can
/// be accepted without asking. Where they disagree, that row gets flagged —
/// and those are exactly the rows worth your attention.
enum HeuristicParser {

    static func parse(_ text: String) -> [ParsedEvent] {
        text.split(separator: "\n")
            .flatMap { events(fromLine: String($0)) }
            .deduplicatedByIdentity()
    }

    // MARK: - One line

    static func events(fromLine line: String) -> [ParsedEvent] {
        guard
            let course = courseCode(in: line),
            let times = timePair(in: line),
            case let days = dayIndices(in: line), !days.isEmpty
        else { return [] }

        let room = roomCode(in: line, excluding: course) ?? ""

        return days.map { day in
            ParsedEvent(
                event: ClassEvent(course: course,
                                  room: room,
                                  dayIndex: day,
                                  startSecond: times.start,
                                  endSecond: times.end,
                                  weekIndex: 0),
                confidence: 1,
                uncertainFields: room.isEmpty ? [.room] : [])
        }
    }

    // MARK: - Course code
    //
    // Two to five letters, a space or not, three to five digits, an optional
    // section letter. Matches "ECE 30100", "MA261", "SOC 10000".

    private static let coursePattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,5})\s{0,3}(\d{3,5}[A-Z]?)\b"#)

    static func courseCode(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = coursePattern.firstMatch(in: line, range: range),
              let subject = Range(match.range(at: 1), in: line),
              let number = Range(match.range(at: 2), in: line)
        else { return nil }

        return "\(line[subject]) \(line[number])"
    }

    // MARK: - Room
    //
    // Same shape as a course code, which is the whole difficulty: "BHEE 170"
    // and "ECE 30100" are indistinguishable in isolation. Resolved by taking
    // the *second* such token on the line, since every registrar format in
    // practice puts the course first and the room later.

    private static let roomPattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,5})\s{0,3}(\d{1,4}[A-Z]?)\b(?![:\d])"#)

    /// Day codes are built from the same letters a building code can use, so
    /// "TR 7:30a" matches the room shape exactly: letters, space, digits.
    /// Two guards separate them.
    ///
    /// A number followed by a colon is a clock time, not a room.
    /// A letter group made only of day letters is a day token, not a building
    /// — real codes carry a letter outside that set (WTHR has H, WALC has A).
    private static let dayLetters = Set("MTWRFSU")

    static func isDayTokenNotBuilding(_ letters: String) -> Bool {
        !letters.isEmpty && letters.allSatisfy { dayLetters.contains($0) }
    }


    static func roomCode(in line: String, excluding course: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        let matches = roomPattern.matches(in: line, range: range)

        let candidates: [String] = matches.compactMap { match in
            guard let subject = Range(match.range(at: 1), in: line),
                  let number = Range(match.range(at: 2), in: line)
            else { return nil }

            let letters = String(line[subject])
            guard !isDayTokenNotBuilding(letters) else { return nil }

            return "\(letters) \(line[number])"
        }

        let normalisedCourse = course.replacingOccurrences(of: " ", with: "")
        return candidates.first {
            $0.replacingOccurrences(of: " ", with: "") != normalisedCourse
        }
    }

    // MARK: - Days
    //
    // Registrars use single letters: M T W R F, where R is Thursday because T
    // is taken. "TR" is Tuesday and Thursday. Also handles the spelled forms.

    static func dayIndices(in line: String) -> [Int] {
        let named: [(String, Int)] = [
            ("monday", 0), ("tuesday", 1), ("wednesday", 2),
            ("thursday", 3), ("friday", 4), ("saturday", 5), ("sunday", 6),
        ]

        let lower = line.lowercased()
        let spelled = named.filter { lower.contains($0.0) }.map(\.1)
        if !spelled.isEmpty { return spelled.sorted() }

        // A bare code token: MWF, TR, M. Must be its own word, or "MA261"
        // would read as Monday.
        guard let token = dayToken(in: line) else { return [] }

        let letters: [Character: Int] = ["M": 0, "T": 1, "W": 2, "R": 3, "F": 4, "S": 5, "U": 6]
        return token.compactMap { letters[$0] }.sorted()
    }

    private static let dayTokenPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Z])([MTWRFSU]{1,7})(?![A-Za-z])"#)

    private static func dayToken(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)

        for match in dayTokenPattern.matches(in: line, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: line) else { continue }
            let token = String(line[tokenRange])

            // A single letter is too weak on its own — it catches initials and
            // column headers. Require either several days or a time nearby.
            if token.count == 1 && timePair(in: line) == nil { continue }
            if Set(token).count != token.count { continue }   // "MM" is not a day set

            return token
        }
        return nil
    }

    // MARK: - Times

    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}):(\d{2})\s*([aApP])?\.?[mM]?\.?"#)

    /// The first two times on the line, as seconds since midnight.
    static func timePair(in line: String) -> (start: Int, end: Int)? {
        let range = NSRange(line.startIndex..., in: line)
        let matches = timePattern.matches(in: line, range: range)
        guard matches.count >= 2 else { return nil }

        let times: [Int] = matches.prefix(2).compactMap { match in
            guard let hourRange = Range(match.range(at: 1), in: line),
                  let minuteRange = Range(match.range(at: 2), in: line),
                  var hour = Int(line[hourRange]),
                  let minute = Int(line[minuteRange])
            else { return nil }

            if match.range(at: 3).location != NSNotFound,
               let meridiemRange = Range(match.range(at: 3), in: line) {
                let isPM = line[meridiemRange].lowercased() == "p"
                if isPM && hour != 12 { hour += 12 }
                if !isPM && hour == 12 { hour = 0 }
            }

            return hour * 3600 + minute * 60
        }

        guard times.count == 2 else { return nil }

        var (start, end) = (times[0], times[1])

        // A class that appears to end before it starts is almost always a
        // missing "p" on the end time: "11:30 - 1:20" means 13:20.
        if end <= start, end + 12 * 3600 > start {
            end += 12 * 3600
        }

        guard end > start, end - start <= 8 * 3600 else { return nil }
        return (start, end)
    }
}

private extension Array where Element == ParsedEvent {
    /// Collapses rows that describe the same meeting, keeping the most
    /// confident. Multi-page PDFs repeat a schedule in grid and table form,
    /// so the same class legitimately appears twice.
    func deduplicatedByIdentity() -> [ParsedEvent] {
        var best: [String: ParsedEvent] = [:]

        for parsed in self {
            let key = "\(parsed.event.course)|\(parsed.event.dayIndex)|\(parsed.event.startSecond)"
            if let existing = best[key], existing.confidence >= parsed.confidence { continue }
            best[key] = parsed
        }

        return best.values.sorted {
            ($0.event.dayIndex, $0.event.startSecond) < ($1.event.dayIndex, $1.event.startSecond)
        }
    }
}
