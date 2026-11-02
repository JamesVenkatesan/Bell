import Foundation

/// Reads a schedule from a weekly calendar grid.
///
/// This is the weakest source Bell accepts, and the design reflects that
/// honestly rather than hiding it.
///
/// What a grid gives reliably: which day a class is on, because that's a
/// column, and the course and room, because they're written in the cell.
///
/// What it doesn't: exact times. A grid encodes time as *vertical position*,
/// so reading it means mapping pixels to minutes off the hour labels down the
/// side. That lands within a few minutes, not exactly — and a class that
/// starts at 7:30 but is recorded as 7:34 produces a leave-now alert that is
/// quietly four minutes wrong forever.
///
/// So everything from here is marked low confidence, which means the review
/// screen flags it and nothing is auto-accepted. When a section table or a
/// calendar link is available, both are strictly better and the UI says so.
enum GridReader {

    private static let weekdayNames: [(String, Int)] = [
        ("monday", 0), ("tuesday", 1), ("wednesday", 2), ("thursday", 3),
        ("friday", 4), ("saturday", 5), ("sunday", 6),
        ("mon", 0), ("tue", 1), ("wed", 2), ("thu", 3), ("fri", 4), ("sat", 5), ("sun", 6),
    ]

    static func read(_ page: TextExtraction.Page) -> [ParsedEvent] {
        guard let columns = dayColumns(in: page), columns.count >= 2,
              let axis = TimeAxis(page: page)
        else { return [] }

        let headerBottom = columns.map(\.headerBottom).max() ?? 0
        var events: [ParsedEvent] = []

        for column in columns {
            let inColumn = page.fragments
                .filter { column.range.contains($0.midX) && $0.midY > headerBottom }
                .sorted { $0.midY < $1.midY }

            for cell in cells(in: inColumn) {
                guard let course = courseCode(in: cell.map(\.text).joined(separator: " "))
                else { continue }

                let top = cell.map(\.frame.minY).min() ?? 0
                let bottom = cell.map(\.frame.maxY).max() ?? top

                guard let start = axis.time(atY: top) else { continue }
                // The text block is shorter than the class block it sits in,
                // so the end derived from text is a floor, not the answer.
                let textEnd = axis.time(atY: bottom) ?? start
                let end = max(start + 1800, min(textEnd, start + 4 * 3600))

                events.append(ParsedEvent(
                    event: ClassEvent(course: course,
                                      room: roomCode(in: cell, excluding: course) ?? "",
                                      dayIndex: column.day,
                                      startSecond: round(start, to: 300),
                                      endSecond: round(end, to: 300),
                                      weekIndex: 0),
                    // Position-derived timing is an estimate. Never silent.
                    confidence: 0.45,
                    uncertainFields: [.startTime, .endTime]))
            }
        }

        return events
    }

    // MARK: - Day columns

    struct DayColumn {
        var day: Int
        var range: ClosedRange<CGFloat>
        var headerBottom: CGFloat
    }

    static func dayColumns(in page: TextExtraction.Page) -> [DayColumn]? {
        for row in page.rows() {
            let headers: [(fragment: TextExtraction.Fragment, day: Int)] = row.compactMap {
                let text = $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard let match = weekdayNames.first(where: { text == $0.0 }) else { return nil }
                return ($0, match.1)
            }

            guard headers.count >= 3 else { continue }

            let sorted = headers.sorted { $0.fragment.left < $1.fragment.left }
            let bottom = (sorted.map(\.fragment.frame.maxY).max() ?? 0) + 0.002

            return sorted.enumerated().map { index, header in
                let lower = index == 0
                    ? max(0, header.fragment.left - 0.02)
                    : (sorted[index - 1].fragment.frame.maxX + header.fragment.left) / 2
                let upper = index + 1 < sorted.count
                    ? (header.fragment.frame.maxX + sorted[index + 1].fragment.left) / 2
                    : 1

                return DayColumn(day: header.day,
                                 range: lower ... max(lower, upper),
                                 headerBottom: bottom)
            }
        }

        return nil
    }

    // MARK: - Time axis
    //
    // The hour labels down the left edge are the only thing that turns a
    // vertical position into a time. Two labels give a linear mapping; more
    // give a better one, so the fit uses the full span rather than the first
    // pair.

    struct TimeAxis {
        var originY: CGFloat
        var secondsPerUnit: CGFloat
        var originSeconds: Int

        init?(page: TextExtraction.Page) {
            let labels: [(y: CGFloat, seconds: Int)] = page.fragments.compactMap {
                guard let seconds = TimeAxis.hourLabel($0.text) else { return nil }
                // Axis labels hug the left edge; a time inside a cell doesn't.
                guard $0.left < 0.18 else { return nil }
                return ($0.midY, seconds)
            }
            .sorted { $0.y < $1.y }

            guard let first = labels.first, let last = labels.last,
                  labels.count >= 2, last.y > first.y, last.seconds > first.seconds
            else { return nil }

            originY = first.y
            originSeconds = first.seconds
            secondsPerUnit = CGFloat(last.seconds - first.seconds) / (last.y - first.y)
        }

        func time(atY y: CGFloat) -> Int? {
            let seconds = CGFloat(originSeconds) + (y - originY) * secondsPerUnit
            guard seconds >= 0, seconds < 24 * 3600 else { return nil }
            return Int(seconds)
        }

        /// "7am", "12pm", "15:00", "7 AM".
        static func hourLabel(_ text: String) -> Int? {
            let trimmed = text.lowercased().replacingOccurrences(of: " ", with: "")

            let pattern = try! NSRegularExpression(pattern: #"^(\d{1,2})(?::(\d{2}))?(am|pm)?$"#)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            guard let match = pattern.firstMatch(in: trimmed, range: range),
                  let hourRange = Range(match.range(at: 1), in: trimmed),
                  var hour = Int(trimmed[hourRange])
            else { return nil }

            var minute = 0
            if match.range(at: 2).location != NSNotFound,
               let minuteRange = Range(match.range(at: 2), in: trimmed) {
                minute = Int(trimmed[minuteRange]) ?? 0
            }

            if match.range(at: 3).location != NSNotFound,
               let meridiemRange = Range(match.range(at: 3), in: trimmed) {
                let isPM = trimmed[meridiemRange] == "pm"
                if isPM && hour != 12 { hour += 12 }
                if !isPM && hour == 12 { hour = 0 }
            } else if hour > 23 {
                return nil
            }

            return hour * 3600 + minute * 60
        }
    }

    // MARK: - Cells

    /// A new cell starts wherever a course code appears. Within a grid cell
    /// the course is always the first line, so this splits stacked classes in
    /// one column without needing a gap threshold that varies by zoom level.
    private static func cells(in column: [TextExtraction.Fragment]) -> [[TextExtraction.Fragment]] {
        var cells: [[TextExtraction.Fragment]] = []

        for fragment in column {
            if courseCode(in: fragment.text) != nil {
                cells.append([fragment])
            } else if !cells.isEmpty {
                cells[cells.count - 1].append(fragment)
            }
        }

        return cells
    }

    // MARK: - Codes
    //
    // Whitespace is `\s{0,3}`, not `\s?`. Extracted text routinely separates
    // tokens with two spaces, and a single-space pattern silently matches
    // nothing at all.

    private static let codePattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,5})\s{0,3}(\d{3,5}[A-Z]*)\b"#)

    static func courseCode(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = codePattern.firstMatch(in: text, range: range),
              let subject = Range(match.range(at: 1), in: text),
              let number = Range(match.range(at: 2), in: text)
        else { return nil }

        return "\(text[subject]) \(text[number])"
    }

    private static let roomPattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,5})\s{0,3}(\d{1,4}[A-Z]?)\b(?![:\d])"#)

    /// See HeuristicParser: a letter group made only of day letters is a day
    /// token, and a number followed by a colon is a time.
    private static let dayLetters = Set("MTWRFSU")

    static func roomCode(in cell: [TextExtraction.Fragment], excluding course: String) -> String? {
        let normalisedCourse = course.replacingOccurrences(of: " ", with: "")

        for fragment in cell {
            let text = fragment.text
            let range = NSRange(text.startIndex..., in: text)

            for match in roomPattern.matches(in: text, range: range) {
                guard let subject = Range(match.range(at: 1), in: text),
                      let number = Range(match.range(at: 2), in: text)
                else { continue }

                let letters = String(text[subject])
                if letters.allSatisfy({ dayLetters.contains($0) }) { continue }

                let candidate = "\(letters) \(text[number])"
                if candidate.replacingOccurrences(of: " ", with: "") != normalisedCourse {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func round(_ seconds: Int, to interval: Int) -> Int {
        Int((Double(seconds) / Double(interval)).rounded()) * interval
    }
}
