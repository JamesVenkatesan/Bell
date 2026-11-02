import Foundation

/// Reads a registrar section table by anchoring on the CRN.
///
/// An earlier version of this located columns geometrically, from the header
/// row's x-positions. That works on paper and failed in practice, because it
/// depended on extracting clean word boxes out of a PDF, and when that went
/// wrong there was no signal — the reader simply found nothing and the import
/// fell through to a much worse path.
///
/// This version needs no geometry at all. A CRN ("17727-002") is unique,
/// unmistakable, and appears exactly once per section, which makes it a far
/// better anchor than a position. The table's column order around it is fixed
/// by the format:
///
///     Subject  Course  Type  CRN  Days  Start  End  Date  Room  Instructor
///
/// so every field can be found by walking outward from the CRN. Lines wrap
/// anywhere they like and it doesn't matter, because the token order survives
/// wrapping even though the line structure doesn't.
///
/// Verified against three real exports with three different wrapping patterns.
enum TableReader {

    /// A parsed section, before it becomes meetings.
    struct Record: Equatable {
        var subject: String?
        var courseNumber: String?
        var type: String?
        var days: String?
        var start: String?
        var end: String?
        var room: String?
        var instructor: String?

        var courseCode: String? {
            guard let subject, let courseNumber else { return nil }
            return "\(subject) \(courseNumber)"
        }
    }

    // MARK: - Patterns

    private static func matches(_ pattern: String, _ token: String) -> Bool {
        token.range(of: pattern, options: [.regularExpression]) != nil
    }

    static func isCRN(_ t: String) -> Bool { matches(#"^\d{4,6}-\d{2,4}$"#, t) }
    static func isTime(_ t: String) -> Bool { matches(#"^\d{1,2}:\d{2}\s*[aApP]?\.?[mM]?\.?$"#, t) }
    static func isDayToken(_ t: String) -> Bool { matches(#"^[MTWRFSU]{1,7}$"#, t) }
    static func isSubject(_ t: String) -> Bool { matches(#"^[A-Z]{2,5}$"#, t) }
    static func isCourseNumber(_ t: String) -> Bool { matches(#"^\d{3,5}[A-Z]*$"#, t) }
    static func isDate(_ t: String) -> Bool { matches(#"^\d{1,2}/\d{1,2}$"#, t) }

    /// Room numbers are two to four digits. One digit is a credit count, which
    /// otherwise gets mistaken for a room when a line wraps awkwardly.
    static func isRoomNumber(_ t: String) -> Bool { matches(#"^\d{2,4}[A-Z]?$"#, t) }

    private static let dayLetters = Set("MTWRFSU")

    /// A building code carries at least one letter that isn't a day letter.
    /// WTHR has H, WALC has A, UC has C — but TR and MWF have none.
    static func isBuildingCode(_ t: String) -> Bool {
        isSubject(t) && !t.allSatisfy { dayLetters.contains($0) }
    }

    // MARK: - Reading

    static func read(_ text: String) -> [ParsedEvent] {
        records(in: text).flatMap(events(from:))
    }

    static func read(_ pages: [TextExtraction.Page]) -> [ParsedEvent] {
        read(pages.map(\.plainText).joined(separator: "\n"))
    }

    /// Splits text into tokens by shape rather than by whitespace.
    ///
    /// Extracted PDF text glues columns together: a row arrives as
    /// `08/25 -12/10BHEE 170I Lin`, where `12/10BHEE` is a single
    /// whitespace-delimited token and the room is invisible. Splitting on
    /// spaces cannot recover from that, because the spaces aren't there.
    ///
    /// Scanning for known shapes instead — a CRN, a clock time, a date, a run
    /// of letters, a run of digits — works whether or not the source bothered
    /// with separators, and costs nothing when it did.
    static func tokenize(_ text: String) -> [String] {
        let pattern = [
            #"\d{4,6}-\d{2,4}"#,                     // CRN
            #"\d{1,2}:\d{2}\s?[aApP]?\.?[mM]?\.?"#,  // clock time
            #"\d{1,2}/\d{1,2}"#,                     // date
            #"\d+"#,                                 // number
            #"[A-Za-z]+,?"#,                          // letters, keeping a trailing comma
        ].joined(separator: "|")

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let r = Range($0.range, in: text) else { return nil }
            let token = String(text[r]).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }
    }

    /// Subjects seen standing on their own somewhere in the document.
    ///
    /// Used to rescue a subject that arrived glued to the previous row's tail
    /// — "GECE" is the grade-mode flag "G" welded onto "ECE". Knowing that
    /// "ECE" appears cleanly elsewhere makes the split unambiguous, where
    /// guessing from the token alone would not be.
    static func knownSubjects(in tokens: [String]) -> Set<String> {
        var found: Set<String> = []
        for (index, token) in tokens.enumerated() where isSubject(token) {
            if index + 1 < tokens.count, isCourseNumber(tokens[index + 1]) {
                found.insert(token)
            }
        }
        return found
    }

    /// Resolves a subject that may have the previous row's tail welded to it.
    ///
    /// "3G" ending one row and "ECE" starting the next arrive as "GECE" —
    /// four capitals followed by a course number, shape-identical to a real
    /// subject. Counting occurrences doesn't separate them: in a document
    /// where every row is glued, the artefact appears more often than the
    /// clean form it came from.
    ///
    /// What does separate them is structure. A real subject doesn't end with
    /// another real subject, so when a token does, the suffix is the subject
    /// and what precedes it is debris. The strip is capped at two characters,
    /// which covers the flags that actually collide here ("G", "Md") while
    /// leaving genuinely distinct codes alone.
    static func subject(from token: String, known: Set<String>) -> String? {
        let candidates = known.filter {
            $0 != token && token.hasSuffix($0) && token.count - $0.count <= 2
        }

        if let longest = candidates.max(by: { $0.count < $1.count }) { return longest }
        return isSubject(token) ? token : nil
    }

    static func records(in text: String) -> [Record] {
        let tokens = tokenize(text)
        let crnPositions = tokens.indices.filter { isCRN(tokens[$0]) }
        guard !crnPositions.isEmpty else { return [] }

        let subjects = knownSubjects(in: tokens)
        var records: [Record] = []

        for (n, index) in crnPositions.enumerated() {
            // Each record owns the tokens between its CRN and the next one.
            // Without this bound, a backward search runs into the previous
            // row's wrapped tail and reads its room as this row's course.
            let lower = n > 0 ? crnPositions[n - 1] + 1 : 0
            let upper = n + 1 < crnPositions.count ? crnPositions[n + 1] : tokens.count

            var record = Record()
            record.type = index > lower ? tokens[index - 1] : nil

            // Subject and course sit immediately before Type. Looking further
            // back finds the previous section's leftovers.
            var cursor = index - 1
            while cursor > lower, cursor > index - 4 {
                if isCourseNumber(tokens[cursor]), cursor - 1 >= lower,
                   let subject = subject(from: tokens[cursor - 1], known: subjects) {
                    record.courseNumber = tokens[cursor]
                    record.subject = subject
                    break
                }
                cursor -= 1
            }

            let span = Array(tokens[(index + 1) ..< upper])

            // Days is the very next column. Searching wider picks up an
            // instructor's initial — "S L Feld" would read as Saturday.
            record.days = span.prefix(3).first(where: isDayToken)

            let times = span.prefix(8).filter(isTime)
            record.start = times.first
            record.end = times.dropFirst().first

            if let end = record.end, let endIndex = span.firstIndex(of: end) {
                let tail = Array(span[(endIndex + 1)...])
                record.room = room(in: tail, excludingSubject: record.subject)
                record.instructor = instructor(in: tail, room: record.room)
            }

            records.append(record)
        }

        // A lab listed under its lecture repeats neither subject nor number.
        for index in records.indices where records[index].courseNumber == nil && index > 0 {
            records[index].subject = records[index - 1].subject
            records[index].courseNumber = records[index - 1].courseNumber
        }

        return records
    }

    /// Building and room, adjacent if the line held together, split if it
    /// wrapped between them — which happens, so both are handled.
    private static func room(in tokens: [String], excludingSubject subject: String?) -> String? {
        for index in tokens.indices.dropLast() {
            let building = tokens[index]
            let number = tokens[index + 1]
            if isBuildingCode(building), isRoomNumber(number), !isDate(number) {
                return "\(building) \(number)"
            }
        }

        // Wrapped: the building and its number ended up on different lines
        // with the instructor and credits between them.
        for (index, token) in tokens.enumerated()
        where isBuildingCode(token) && token != subject {
            guard let number = tokens[(index + 1)...]
                .first(where: { isRoomNumber($0) && !isDate($0) })
            else { return nil }
            return "\(token) \(number)"
        }

        return nil
    }

    /// The instructor sits between the room and the credit count.
    ///
    /// Best-effort by design. Names are the least regular thing in the table —
    /// initials, commas, multiple staff, occasional absence — so this stops at
    /// the first thing that clearly isn't a name rather than trying to be
    /// clever. A wrong instructor is cosmetic; a wrong room is not, which is
    /// why this gets far less effort than the fields above it.
    static func instructor(in tokens: [String], room: String?) -> String? {
        var start = 0
        if let number = room?.split(separator: " ").last.map(String.init),
           let index = tokens.firstIndex(of: number) {
            start = index + 1
        }

        var parts: [String] = []
        let tail = Array(tokens[min(start, tokens.count)...])
        for (offset, token) in tail.enumerated() {
            // The next row's course ("ECE 20869"). Rows rebuilt from page
            // position end on the grade mode with nothing after it, so the
            // name scan used to carry straight on into the following row
            // and came back as "N Menon ECE".
            if isSubject(token), offset + 1 < tail.count, isCourseNumber(tail[offset + 1]) { break }
            if matches(#"^\d$"#, token) { break }          // credit count
            if isDate(token) || isCRN(token) { break }
            if token == "G" || token == "-" { continue }    // grade mode
            if noteWords.contains(token) { break }          // the Note column
            guard matches(#"^[A-Z][A-Za-z.,'-]*$"#, token) else { break }

            parts.append(separateGluedWords(token))
            if parts.count >= 6 { break }
        }

        let name = parts.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return name.count >= 3 ? name : nil
    }

    /// The Note column follows the instructor with no separator, so these
    /// words mark where a name has ended. A short list beats a clever rule:
    /// the alternative is deciding whether "Evening" is a surname.
    private static let noteWords: Set<String> = [
        "Evening", "Exams", "Required", "Distance", "Online", "Honors",
        "Course", "Contact", "Note", "Credit", "Requires", "Arrange", "Hours",
    ]

    /// Splits words the extractor welded together.
    ///
    /// "S PFrance" is "S P France": the space between an initial and the
    /// surname didn't survive. The seam is always the same shape — a capital
    /// that follows another capital and is itself followed by lower case.
    static func separateGluedWords(_ token: String) -> String {
        var result = ""
        let characters = Array(token)

        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase,
               characters[index - 1].isUppercase,
               index + 1 < characters.count, characters[index + 1].isLowercase {
                result.append(" ")
            }
            result.append(character)
        }

        return result
    }

    // MARK: - Record to meetings

    static func events(from record: Record) -> [ParsedEvent] {
        guard
            let course = record.courseCode,
            let days = record.days,
            let startText = record.start,
            let endText = record.end,
            let start = clockSeconds(startText),
            let end = clockSeconds(endText),
            end > start
        else { return [] }   // online and arranged sections have no meetings

        let dayIndices = Self.dayIndices(days)
        guard !dayIndices.isEmpty else { return [] }

        let code = course + sectionSuffix(record.type ?? "")

        return dayIndices.map { day in
            ParsedEvent(
                event: ClassEvent(course: code,
                                  room: record.room ?? "",
                                  dayIndex: day,
                                  startSecond: start,
                                  endSecond: end,
                                  weekIndex: 0,
                                  instructor: record.instructor),
                // Anchored on a unique key and read in fixed column order.
                // As certain as anything short of the calendar feed.
                confidence: 0.95)
        }
    }

    /// The section type decides the suffix that groups a lab with its lecture.
    static func sectionSuffix(_ type: String) -> String {
        let value = type.lowercased()
        if value.contains("lab") { return "L" }
        if value.contains("rec") { return "R" }
        if value.contains("dist") || value.contains("online") { return "D" }
        return ""
    }

    /// Registrar day letters, where R is Thursday because T is taken.
    static func dayIndices(_ token: String) -> [Int] {
        let map: [Character: Int] = ["M": 0, "T": 1, "W": 2, "R": 3, "F": 4, "S": 5, "U": 6]
        return Set(token.uppercased().compactMap { map[$0] }).sorted()
    }

    /// "7:30a", "3:30p", "15:30", "11:20 AM".
    static func clockSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})\s*([aApP])?"#)
            .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let hourRange = Range(match.range(at: 1), in: trimmed),
              let minuteRange = Range(match.range(at: 2), in: trimmed),
              var hour = Int(trimmed[hourRange]),
              let minute = Int(trimmed[minuteRange]),
              (0 ..< 60).contains(minute)
        else { return nil }

        if match.range(at: 3).location != NSNotFound,
           let meridiemRange = Range(match.range(at: 3), in: trimmed) {
            let isPM = trimmed[meridiemRange].lowercased() == "p"
            if isPM && hour != 12 { hour += 12 }
            if !isPM && hour == 12 { hour = 0 }
        }

        guard (0 ..< 24).contains(hour) else { return nil }
        return hour * 3600 + minute * 60
    }
}
