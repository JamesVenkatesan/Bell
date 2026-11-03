import Foundation

// What a Notion database looks like to Bell, and how its rows become tasks.
//
// Nothing here knows the user's column names. A database has whatever
// columns its owner happened to make, so Bell reads the schema, suggests
// which column is which from the types, and lets the user correct it once.
// The mapping is stored by property *ID*, not name: Notion keeps a
// property's ID when it's renamed, so renaming "Due" to "Deadline" in
// Notion doesn't silently break the sync.

// MARK: - Schema

struct NotionProperty: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Notion's type name: title, date, select, status, checkbox, relation…
    var type: String
    /// Option names, for select, multi-select and status.
    var options: [String] = []
    /// For status: the options in Notion's "Complete" group, which is how a
    /// status column says done whatever its options are called.
    var completeOptions: [String] = []

    var typeLabel: String {
        switch type {
        case "rich_text": "Text"
        case "multi_select": "Multi-select"
        case "unique_id": "ID"
        case "last_edited_time": "Last edited"
        case "created_time": "Created"
        case "phone_number": "Phone"
        default: type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    /// The schema from a database (2022-06-28) or data source (2025-09-03)
    /// object; both keep it under "properties", keyed by name.
    static func schema(from object: [String: Any]) -> [NotionProperty] {
        guard let properties = object["properties"] as? [String: Any] else { return [] }
        return properties.compactMap { name, value -> NotionProperty? in
            guard let body = value as? [String: Any], let id = body["id"] as? String,
                  let type = body["type"] as? String else { return nil }
            var property = NotionProperty(id: id, name: (body["name"] as? String) ?? name, type: type)
            let config = body[type] as? [String: Any]
            let options = (config?["options"] as? [[String: Any]]) ?? []
            property.options = options.compactMap { $0["name"] as? String }
            if type == "status" {
                let ids = Dictionary(options.compactMap { o in (o["id"] as? String).map { ($0, o["name"] as? String ?? "") } },
                                     uniquingKeysWith: { a, _ in a })
                let groups = (config?["groups"] as? [[String: Any]]) ?? []
                let complete = groups.filter { ($0["name"] as? String)?.lowercased() == "complete" }
                property.completeOptions = complete.flatMap { ($0["option_ids"] as? [String]) ?? [] }.compactMap { ids[$0] }
            }
            return property
        }
        // Title first, then by name: the order the settings screen lists them.
        .sorted { ($0.type == "title" ? 0 : 1, $0.name.lowercased()) < ($1.type == "title" ? 0 : 1, $1.name.lowercased()) }
    }

    static func title(from object: [String: Any]) -> String {
        NotionValue.plainText(object["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Which column is which

struct NotionMapping: Codable, Equatable {
    var title: String?
    var due: String?
    var course: String?
    var done: String?
    var kind: String?

    enum Role: String, CaseIterable, Identifiable {
        case title, due, course, done, kind
        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: "Title"
            case .due: "Due date"
            case .course: "Course"
            case .done: "Done"
            case .kind: "Type"
            }
        }

        var isRequired: Bool { self == .title || self == .due }

        /// Types that can play the role. Formulas and rollups are allowed
        /// wherever their result might be the right kind; the value reader
        /// copes with whatever they turn out to hold.
        var types: Set<String> {
            switch self {
            case .title: ["title", "rich_text", "formula"]
            case .due: ["date", "formula", "rollup"]
            case .course: ["select", "multi_select", "rich_text", "relation", "rollup", "formula", "title"]
            case .done: ["checkbox", "status", "select", "formula"]
            case .kind: ["select", "multi_select", "status", "rich_text", "formula"]
            }
        }
    }

    subscript(role: Role) -> String? {
        get {
            switch role {
            case .title: title
            case .due: due
            case .course: course
            case .done: done
            case .kind: kind
            }
        }
        set {
            switch role {
            case .title: title = newValue
            case .due: due = newValue
            case .course: course = newValue
            case .done: done = newValue
            case .kind: kind = newValue
            }
        }
    }

    var isUsable: Bool { title != nil && due != nil }

    /// A first guess from types, then names. The guess only has to be right
    /// often; the user sees it and can change any of it.
    static func suggest(for schema: [NotionProperty]) -> NotionMapping {
        func named(_ words: [String], in candidates: [NotionProperty]) -> NotionProperty? {
            candidates.first { p in words.contains { p.name.lowercased().contains($0) } }
        }
        func ofType(_ types: Set<String>) -> [NotionProperty] { schema.filter { types.contains($0.type) } }

        var mapping = NotionMapping()
        mapping.title = schema.first { $0.type == "title" }?.id

        // The only date column is the due date. With several ("Created",
        // "Due", "Assigned"), the one whose name says so.
        let dates = ofType(["date"])
        mapping.due = (dates.count == 1 ? dates.first : named(["due", "deadline", "date", "when"], in: dates))?.id
            ?? named(["due", "deadline"], in: ofType(["formula", "rollup"]))?.id

        mapping.done = (named(["done", "complete", "submitted", "finished", "turned in"], in: ofType(["checkbox"]))
            ?? ofType(["status"]).first
            ?? (ofType(["checkbox"]).count == 1 ? ofType(["checkbox"]).first : nil))?.id

        let courseCandidates = ofType(["select", "multi_select", "relation", "rich_text", "rollup"])
        mapping.course = (named(["course", "class", "subject", "module"], in: courseCandidates)
            // A select whose options look like course codes is a course
            // column, whatever it's called.
            ?? courseCandidates.first { p in p.options.contains { NotionCourse.looksLikeCode($0) } })?.id

        let kindCandidates = ofType(["select", "multi_select", "status"]).filter { $0.id != mapping.course && $0.id != mapping.done }
        mapping.kind = (named(["type", "kind", "category", "tag"], in: kindCandidates)
            ?? kindCandidates.first { p in p.options.contains { NotionKind.infer(title: "", type: $0) != .other } })?.id
        return mapping
    }

    /// Drops roles whose property no longer exists, so a deleted column
    /// shows as unmapped in settings instead of failing every sync.
    func pruned(to schema: [NotionProperty]) -> NotionMapping {
        let ids = Set(schema.map(\.id))
        var copy = self
        for role in Role.allCases where copy[role].map({ !ids.contains($0) }) ?? false { copy[role] = nil }
        return copy
    }
}

// MARK: - Values

/// One cell, reduced to the handful of shapes Bell can use.
enum NotionValue: Equatable {
    case text(String)
    case date(Date, allDay: Bool)
    case checkbox(Bool)
    case options([String])
    case relation([String])
    case number(Double)
    case empty

    /// A page's cells, keyed by property ID. Pages key properties by name,
    /// with the ID inside; the ID is what survives a rename.
    static func cells(of page: [String: Any], calendar: Calendar = .current) -> [String: NotionValue] {
        guard let properties = page["properties"] as? [String: Any] else { return [:] }
        var cells: [String: NotionValue] = [:]
        for (_, raw) in properties {
            guard let body = raw as? [String: Any], let id = body["id"] as? String else { continue }
            cells[id] = value(body, calendar: calendar)
        }
        return cells
    }

    static func value(_ body: [String: Any], calendar: Calendar = .current) -> NotionValue {
        guard let type = body["type"] as? String else { return .empty }
        let content = body[type]
        switch type {
        case "title", "rich_text":
            let text = plainText(content)
            return text.isEmpty ? .empty : .text(text)
        case "date", "created_time", "last_edited_time":
            if let string = content as? String { return parseDate(string, calendar: calendar).map { .date($0.0, allDay: $0.1) } ?? .empty }
            guard let start = (content as? [String: Any])?["start"] as? String,
                  let parsed = parseDate(start, calendar: calendar) else { return .empty }
            return .date(parsed.0, allDay: parsed.1)
        case "checkbox":
            return .checkbox(content as? Bool ?? false)
        case "select", "status":
            return ((content as? [String: Any])?["name"] as? String).map { .options([$0]) } ?? .empty
        case "multi_select":
            let names = ((content as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return names.isEmpty ? .empty : .options(names)
        case "relation":
            let ids = ((content as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            return ids.isEmpty ? .empty : .relation(ids)
        case "number":
            return (content as? Double).map { .number($0) } ?? (content as? Int).map { .number(Double($0)) } ?? .empty
        case "url", "email", "phone_number":
            return (content as? String).map { .text($0) } ?? .empty
        case "people":
            let names = ((content as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return names.isEmpty ? .empty : .text(names.joined(separator: ", "))
        case "unique_id":
            guard let id = content as? [String: Any], let number = id["number"] as? Int else { return .empty }
            return .text("\(id["prefix"] as? String ?? "")\(number)")
        case "formula", "rollup":
            // Both wrap another value under their own "type". A rollup of an
            // array flattens to the text of each element.
            guard let inner = content as? [String: Any] else { return .empty }
            if let innerType = inner["type"] as? String, innerType == "array" {
                let parts = ((inner["array"] as? [[String: Any]]) ?? []).map { value($0, calendar: calendar) }
                if let date = parts.first(where: { if case .date = $0 { true } else { false } }) { return date }
                let texts = parts.flatMap { part -> [String] in
                    switch part {
                    case .text(let t): [t]
                    case .options(let o): o
                    default: []
                    }
                }
                return texts.isEmpty ? .empty : .text(texts.joined(separator: ", "))
            }
            if let innerType = inner["type"] as? String {
                switch innerType {
                case "string": return (inner["string"] as? String).map { $0.isEmpty ? .empty : .text($0) } ?? .empty
                case "boolean": return .checkbox(inner["boolean"] as? Bool ?? false)
                case "number": return (inner["number"] as? Double).map { .number($0) } ?? .empty
                default: return value(inner, calendar: calendar)
                }
            }
            return .empty
        default:
            return .empty
        }
    }

    /// The end of a date range, keyed by property ID. Kept apart from the
    /// cell values because only the due column's end is ever used: it's
    /// how an exam "7:00–9:00 PM" becomes a block that takes time on the
    /// day's timeline instead of a single instant.
    static func ends(of page: [String: Any], calendar: Calendar = .current) -> [String: Date] {
        guard let properties = page["properties"] as? [String: Any] else { return [:] }
        var ends: [String: Date] = [:]
        for case let body as [String: Any] in properties.values {
            guard let id = body["id"] as? String, body["type"] as? String == "date",
                  let end = (body["date"] as? [String: Any])?["end"] as? String,
                  let parsed = parseDate(end, calendar: calendar) else { continue }
            ends[id] = parsed.0
        }
        return ends
    }

    /// Notion's rich text is an array of runs; the words are in plain_text.
    static func plainText(_ content: Any?) -> String {
        ((content as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// "2026-11-05" is a day: local midnight, flagged all-day, so a
    /// homework due "Thursday" is due on the Thursday the user means
    /// wherever they are. Anything with a time is an instant.
    static func parseDate(_ string: String, calendar: Calendar = .current) -> (Date, Bool)? {
        if string.count == 10 {
            let parts = string.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])).map { ($0, true) }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return (date, false) }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string).map { ($0, false) }
    }

    var text: String? {
        switch self {
        case .text(let t): t
        case .options(let o): o.joined(separator: ", ")
        case .number(let n): n.formatted()
        default: nil
        }
    }
}

// MARK: - Rows

/// One Notion row, ready to become a task.
struct NotionItem: Equatable {
    var pageID: String
    var title: String
    var due: Date
    var isAllDay: Bool
    /// The end of a timed range ("7:00–9:00 PM"), when the row has one.
    var end: Date? = nil
    var kind: TaskEvent.Kind
    var isDone: Bool
    /// What the course column said, before matching.
    var courseText: String?
    /// Pages a course relation points at; their titles are fetched later.
    var courseRelations: [String] = []
    /// The matched Bell course, or nil when nothing matched.
    var course: String?

    /// A row with no title or no due date can't be a deadline. Such rows
    /// are skipped, which also means clearing a due date in Notion removes
    /// the task from Bell: there's nothing left for Bell to remind you of.
    static func make(page: [String: Any], mapping: NotionMapping, schema: [NotionProperty],
                     calendar: Calendar = .current) -> NotionItem? {
        guard let pageID = page["id"] as? String,
              let titleID = mapping.title, let dueID = mapping.due else { return nil }
        if (page["in_trash"] as? Bool) == true || (page["archived"] as? Bool) == true { return nil }
        let cells = NotionValue.cells(of: page, calendar: calendar)

        guard let title = cells[titleID]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              case .date(let due, let allDay)? = cells[dueID] else { return nil }

        var courseText: String?
        var relations: [String] = []
        if let courseID = mapping.course {
            switch cells[courseID] {
            case .relation(let ids)?: relations = ids
            case let value?: courseText = value.text
            case nil: break
            }
        }

        let kindText = mapping.kind.flatMap { cells[$0]?.text }
        let done = mapping.done.map { id in
            isDone(cells[id], property: schema.first { $0.id == id })
        } ?? false

        // An end only counts for a timed range that ends after it starts;
        // a multi-day all-day range is still a deadline on its first day.
        let end = allDay ? nil : NotionValue.ends(of: page, calendar: calendar)[dueID].flatMap { $0 > due ? $0 : nil }
        return NotionItem(pageID: pageID, title: title, due: due, isAllDay: allDay, end: end,
                          kind: NotionKind.infer(title: title, type: kindText),
                          isDone: done, courseText: courseText, courseRelations: relations)
    }

    /// A checkbox is done when ticked. A status is done when its option is
    /// in Notion's Complete group, whatever the user named it. A plain
    /// select has no groups, so its option has to say so in words.
    static func isDone(_ value: NotionValue?, property: NotionProperty?) -> Bool {
        switch value {
        case .checkbox(let ticked)?: return ticked
        case .options(let names)?:
            if let complete = property?.completeOptions, !complete.isEmpty {
                return names.contains { complete.contains($0) }
            }
            return names.contains { name in
                ["done", "complete", "completed", "submitted", "finished", "turned in", "graded"]
                    .contains(name.lowercased().trimmingCharacters(in: .whitespaces))
            }
        default: return false
        }
    }
}

// MARK: - What kind of work

enum NotionKind {
    /// The type column first, if it says something, then the title.
    ///
    /// Uses the inbox's word list so a "midterm" is an exam wherever it came
    /// from, plus the words people use in a homework tracker that rarely
    /// appear in an email.
    static func infer(title: String, type: String?) -> TaskEvent.Kind {
        if let type, !type.isEmpty {
            let fromType = classify(type)
            if fromType != .other || isReading(type) { return fromType }
        }
        return classify(title)
    }

    private static func classify(_ text: String) -> TaskEvent.Kind {
        // "Final project" is a project; the inbox reader, which puts exams
        // first so "final exam review" stays an exam, would call it an exam.
        if EventTextReader.containsWord("final project", in: text) { return .project }
        if isReading(text) { return .other }
        for word in ["problem set", "pset", "worksheet", "essay", "paper", "write-up", "writeup", "prelab", "postlab"]
        where EventTextReader.containsWord(word, in: text) {
            if EventTextReader.kind(of: text) == .exam { return .exam }
            return .assignment
        }
        let kind = EventTextReader.kind(of: text)
        // "Session" and "meeting" make sense in mail; in a homework list a
        // row is work to hand in unless it says otherwise.
        return kind == .meeting ? .other : kind
    }

    private static func isReading(_ text: String) -> Bool {
        ["reading", "read", "readings", "watch", "lecture video"].contains { EventTextReader.containsWord($0, in: text) }
            && EventTextReader.kind(of: text) == .other
    }
}

// MARK: - Which course

enum NotionCourse {
    /// A Bell course, from what the course column or the title says. Only a
    /// course code that matches one of the user's own courses counts: a
    /// row that matches nothing stays unlinked rather than being guessed
    /// into the nearest course.
    static func match(courseText: String?, title: String, courses: [String]) -> String? {
        for text in [courseText, title].compactMap({ $0 }) {
            // Upper-cased because people type "ece 302" in their own notes.
            if let course = EventTextReader.course(in: text.uppercased(), courses: courses) { return course }
        }
        return nil
    }

    static func looksLikeCode(_ text: String) -> Bool {
        text.range(of: #"^\s*[A-Za-z]{2,5}\s?\d{3,5}[A-Za-z]?\b"#, options: .regularExpression) != nil
    }
}

// MARK: - Finding the database

enum NotionDatabaseID {
    /// The database's ID from whatever the user pastes: the share link
    /// (`notion.so/ws/Fall-2026-<32 hex>?v=<view id>`), a dashed UUID, or the
    /// bare 32 characters. The view ID after `?v=` is not the database, so
    /// only the path is read.
    static func parse(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.split(separator: "?").first.map(String.init) ?? trimmed
        let compact = path.replacingOccurrences(of: "-", with: "")
        guard let range = compact.range(of: #"[0-9a-fA-F]{32}(?![0-9a-fA-F])"#,
                                        options: [.regularExpression, .backwards]) else { return nil }
        let hex = compact[range].lowercased()
        // Notion accepts either form; the dashed one matches what its own
        // API returns, which keeps comparisons simple.
        let parts = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        return parts.map { length in
            let end = hex.index(index, offsetBy: length)
            defer { index = end }
            return String(hex[index ..< end])
        }.joined(separator: "-")
    }
}
