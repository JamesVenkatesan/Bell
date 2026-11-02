import Foundation

/// Reads an iCalendar feed.
///
/// This is the best import path by a wide margin, and worth preferring
/// whenever it exists. UniTime — the system behind Purdue's schedule — exposes
/// a subscribable `.ics` URL from the same page as the printable one. It's
/// structured data straight from the registrar, so there is nothing to OCR,
/// nothing to infer, and no confidence to assign: every row is exact.
///
/// It also keeps working. A subscription re-fetches, so an add or drop and the
/// publication of exam times both arrive on their own.
enum ICSImporter {

    enum ICSError: LocalizedError {
        case notCalendarData
        case noEventsFound

        var errorDescription: String? {
            switch self {
            case .notCalendarData:
                "That link didn't return a calendar. Check it's the iCalendar export URL."
            case .noEventsFound:
                "The calendar loaded but contained no events."
            }
        }
    }

    // MARK: - Entry points

    static func timetable(fromICS text: String) throws -> Timetable {
        guard text.contains("BEGIN:VCALENDAR") else { throw ICSError.notCalendarData }

        let events = components(in: unfold(text))
        guard !events.isEmpty else { throw ICSError.noEventsFound }

        var table = Timetable()
        var earliest: Date?
        var latest: Date?

        for component in events {
            guard let summary = component["SUMMARY"],
                  let start = component.date(for: "DTSTART"),
                  let end = component.date(for: "DTEND")
            else { continue }

            let calendar = Calendar.current
            let startSecond = calendar.secondsSinceMidnight(start)
            let endSecond = calendar.secondsSinceMidnight(end)
            guard endSecond > startSecond else { continue }

            let room = Self.unescape(component["LOCATION"] ?? "")
                .trimmingCharacters(in: .whitespaces)
            let description = component["DESCRIPTION"].map(Self.unescape)
            let course = Self.courseName(from: Self.unescape(summary), sectionType: description)
            let instructor = Self.instructor(organizer: component.parameters["ORGANIZER"],
                                             description: description)

            // Weekly recurrence gives the days; a one-off gives the day it
            // falls on. Either way the weekly grid is what Bell stores.
            let days = component.recurrenceDays
                ?? [(calendar.component(.weekday, from: start) + 5) % 7]

            for day in days {
                table.events.append(
                    ClassEvent(course: course,
                               room: room,
                               dayIndex: day,
                               startSecond: startSecond,
                               endSecond: endSecond,
                               weekIndex: 0,
                               instructor: instructor))
            }

            earliest = min(earliest ?? start, start)
            if let until = component.recurrenceUntil {
                latest = max(latest ?? until, until)
            } else {
                latest = max(latest ?? end, end)
            }
        }

        guard !table.events.isEmpty else { throw ICSError.noEventsFound }

        // Term bounds come free here, which no other import path provides.
        table.termStart = earliest
        table.termEnd = latest
        table.events = dedupe(table.events)

        return table
    }

    static func fetch(from url: URL) async throws -> Timetable {
        // Calendar subscription URLs are commonly handed out as webcal://.
        var request = url
        if request.scheme == "webcal" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            request = components?.url ?? url
        }

        let (data, response) = try await URLSession.shared.data(from: request)

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ICSError.notCalendarData
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ICSError.notCalendarData
        }

        return try timetable(fromICS: text)
    }

    // MARK: - Summary cleanup
    //
    // UniTime summaries look like "ECE 30100 Lec" or "ECE 36200 Lab". The
    // section type is dropped into the suffix convention Bell already uses, so
    // a lab shares its lecture's colour.

    /// Two summary shapes exist. Hand-made and older feeds say
    /// "ECE 36200 Lec". Purdue's UniTime feed says "CS 15900 12941-LE5":
    /// subject, number, then CRN and section, with the section's type in
    /// DESCRIPTION ("Lecture", "Laboratory"). Read naively, the second shape
    /// became a course called "CS 15900 12941-LE5", which matched nothing a
    /// PDF import produced and broke colour sharing between lecture and lab.
    static func courseName(from summary: String, sectionType: String? = nil) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespaces)

        if let match = trimmed.firstMatch(of: /^([A-Z]{2,5}) (\d{3,5}[A-Z]*) \d{4,6}-\S+$/) {
            return "\(match.1) \(match.2)" + suffix(forType: sectionType)
        }

        let suffixes: [(String, String)] = [
            (" LabP", "L"), (" Lab", "L"), (" Rec", "R"),
            (" Lec", ""), (" Dist", "D"), (" Online", "D"),
        ]

        for (needle, replacement) in suffixes
        where trimmed.lowercased().hasSuffix(needle.lowercased()) {
            let base = String(trimmed.dropLast(needle.count))
                .trimmingCharacters(in: .whitespaces)
            return base + replacement
        }

        return trimmed
    }

    /// The suffix Bell uses for a section type, so a lab from a feed and a
    /// lab from a PDF end up as the same course code.
    static func suffix(forType type: String?) -> String {
        switch type?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "laboratory", "lab", "laboratory preparation", "labp": "L"
        case "recitation", "rec": "R"
        case "distance", "distance learning", "online": "D"
        default: ""
        }
    }

    /// The section types UniTime writes into DESCRIPTION. Anything else there
    /// is treated as a possible instructor name.
    private static let sectionTypes: Set<String> = [
        "lecture", "laboratory", "lab", "recitation", "studio", "distance", "online",
        "laboratory preparation", "practice study observation", "seminar", "clinic",
        "individual study", "lecture and laboratory", "experiential", "research",
    ]

    /// Who teaches it, in the same "E S A Diyab" form the PDF table uses.
    ///
    /// UniTime's feed puts the instructor in ORGANIZER's CN parameter, as
    /// "Last, First Middle (Instr)", not in DESCRIPTION (which holds the
    /// section type). DESCRIPTION is still checked, for feeds that do put a
    /// name there, but only when it isn't one of the known section types.
    static func instructor(organizer: String?, description: String?) -> String? {
        if let organizer,
           let cn = organizer.firstMatch(of: /CN="([^"]+)"/)?.1 ?? organizer.firstMatch(of: /CN=([^;:]+)/)?.1 {
            return displayName(String(cn))
        }
        if let description, !description.isEmpty, description.count < 60,
           !sectionTypes.contains(description.trimmingCharacters(in: .whitespaces).lowercased()),
           description.first?.isUppercase == true, !description.contains(where: \.isNumber) {
            return displayName(description)
        }
        return nil
    }

    /// "Diyab, Eman Samy Ahmed (Instr)" becomes "E S A Diyab". Names without
    /// a comma are kept as written.
    static func displayName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return cleaned }
        let initials = parts[1].split(separator: " ").compactMap(\.first).map(String.init)
        return (initials + [parts[0]]).joined(separator: " ")
    }

    /// iCalendar escapes commas, semicolons and newlines in text values.
    /// Unescaped, a two-room location read "LMBS 3261A\\, LMBS 3261B".
    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func dedupe(_ events: [ClassEvent]) -> [ClassEvent] {
        var seen = Set<String>()
        return events.filter { event in
            let key = "\(event.course)|\(event.dayIndex)|\(event.startSecond)|\(event.room)"
            return seen.insert(key).inserted
        }
        .sorted { ($0.dayIndex, $0.startSecond) < ($1.dayIndex, $1.startSecond) }
    }

    // MARK: - Parsing

    /// iCalendar wraps long lines at 75 octets and continues them with a
    /// leading space. Unfolding first means every property is on one line and
    /// nothing else has to think about it.
    private static func unfold(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func components(in text: String) -> [Component] {
        var results: [Component] = []
        var current: Component?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)

            if line.hasPrefix("BEGIN:VEVENT") {
                current = Component()
            } else if line.hasPrefix("END:VEVENT") {
                if let component = current { results.append(component) }
                current = nil
            } else if current != nil, let colon = line.firstIndex(of: ":") {
                // "DTSTART;TZID=America/Indiana/Indianapolis:20260824T073000"
                let rawKey = String(line[line.startIndex ..< colon])
                let value = String(line[line.index(after: colon)...])
                let key = rawKey.split(separator: ";").first.map(String.init) ?? rawKey

                current?.properties[key] = value
                current?.parameters[key] = rawKey
            }
        }

        return results
    }

    private struct Component {
        var properties: [String: String] = [:]
        var parameters: [String: String] = [:]

        subscript(key: String) -> String? { properties[key] }

        func date(for key: String) -> Date? {
            guard let value = properties[key] else { return nil }
            return ICSImporter.parseDate(value, parameter: parameters[key] ?? "")
        }

        /// BYDAY from an RRULE, mapped to Bell's Monday-zero indices.
        var recurrenceDays: [Int]? {
            guard let rule = properties["RRULE"] else { return nil }

            let parts = rule.split(separator: ";").reduce(into: [String: String]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }

            guard let byDay = parts["BYDAY"] else { return nil }

            let map: [String: Int] = ["MO": 0, "TU": 1, "WE": 2, "TH": 3,
                                      "FR": 4, "SA": 5, "SU": 6]

            let days = byDay.split(separator: ",").compactMap { token -> Int? in
                // Tokens can carry an ordinal, like "2TU" for the second
                // Tuesday. Class schedules don't use those, but stripping is
                // cheap insurance against a feed that does.
                let letters = String(token.suffix(2)).uppercased()
                return map[letters]
            }

            return days.isEmpty ? nil : days.sorted()
        }

        var recurrenceUntil: Date? {
            guard let rule = properties["RRULE"],
                  let range = rule.range(of: "UNTIL=")
            else { return nil }

            let value = rule[range.upperBound...]
                .prefix { $0 != ";" }
            return ICSImporter.parseDate(String(value), parameter: "")
        }
    }

    /// Handles the three forms that appear in practice: UTC with a trailing Z,
    /// floating local time, and date-only.
    static func parseDate(_ value: String, parameter: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let range = parameter.range(of: "TZID=") {
            let identifier = String(parameter[range.upperBound...])
                .prefix { $0 != ";" }
            formatter.timeZone = TimeZone(identifier: String(identifier)) ?? .current
        } else {
            formatter.timeZone = value.hasSuffix("Z") ? TimeZone(identifier: "UTC") : .current
        }

        for format in ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }

        return nil
    }
}

private extension Calendar {
    func secondsSinceMidnight(_ date: Date) -> Int {
        let parts = dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60
    }
}
