import Foundation

/// Turns a document into a reviewable diff.
///
/// Four readers, tried in order of how exact they are. The ordering is the
/// whole design: a schedule has a best representation inside it, and finding
/// that is worth far more than parsing a worse one cleverly.
///
///   1. A section table with a header row. Columns are labelled, so reading
///      them is lookup rather than inference. Near-exact.
///   2. A weekly grid. Day and room are reliable; times are read off pixel
///      positions and are approximate, so everything is flagged.
///   3. Line-by-line regex over flattened text, for layouts with no structure
///      to find.
///   4. Apple's on-device model, as a cross-check on 3 rather than a
///      replacement for it.
///
/// A printed schedule usually contains both a grid and a table — the same
/// classes, twice. Reading both and merging produces duplicates and
/// contradictions, so once the table is found the grid is ignored entirely.
enum ScheduleCapture {

    struct Result {
        var diff: ScheduleDiff
        var sourceText: String
        var method: Method
        var usedModel: Bool
        var modelUnavailableReason: String?

        var parsedCount: Int { diff.changes.count + diff.unchanged.count }

        enum Method {
            case calendarFeed
            case sectionTable
            case calendarGrid
            case freeText

            var summary: String {
                switch self {
                case .calendarFeed:
                    "Exact data from your registrar's calendar."
                case .sectionTable:
                    "Read from the section table, where every column is labelled."
                case .calendarGrid:
                    "Read from the weekly grid. Times are estimated from the layout, so check them."
                case .freeText:
                    "Read line by line, with no table structure to work from."
                }
            }

            /// True when the source itself limits accuracy, regardless of how
            /// well the reading went.
            var isApproximate: Bool {
                switch self {
                case .calendarGrid, .freeText: true
                case .calendarFeed, .sectionTable: false
                }
            }

            /// Shown when something strictly better exists.
            var betterAlternative: String? {
                switch self {
                case .calendarGrid:
                    "The section table on page 2, or your calendar link, gives exact times."
                case .freeText:
                    "A PDF of your official schedule, or your calendar link, reads far more reliably."
                case .calendarFeed, .sectionTable:
                    nil
                }
            }
        }
    }

    // MARK: - Entry points

    static func capture(from url: URL,
                        against current: [ClassEvent]) async throws -> Result {
        let pages = try await TextExtraction.pages(from: url)
        return await capture(pages: pages, against: current)
    }

    static func capture(imageData: Data,
                        against current: [ClassEvent]) async throws -> Result {
        let page = try await TextExtraction.fromImageData(imageData)
        return await capture(pages: [page], against: current)
    }

    static func capture(pages: [TextExtraction.Page],
                        against current: [ClassEvent]) async -> Result {
        let text = pages.map(\.plainText).joined(separator: "\n")

        // 1. The section table, found by anchoring on CRNs anywhere in the
        //    flattened text. No geometry involved, so it survives whatever
        //    the extractor does to line structure.
        let tableEvents = TableReader.read(text)
        if !tableEvents.isEmpty {
            return Result(
                diff: ScheduleDiff.between(current: current, incoming: dedupe(tableEvents)),
                sourceText: text,
                method: .sectionTable,
                usedModel: false,
                modelUnavailableReason: nil)
        }

        // 2. The grid.
        let gridEvents = pages.flatMap(GridReader.read)
        if gridEvents.count >= 2 {
            return Result(
                diff: ScheduleDiff.between(current: current, incoming: dedupe(gridEvents)),
                sourceText: text,
                method: .calendarGrid,
                usedModel: false,
                modelUnavailableReason: nil)
        }

        // 3 and 4. No structure to exploit: fall back to reading lines, and
        // use the model as a second opinion on them.
        let deterministic = HeuristicParser.parse(text)
        let intelligent = await IntelligentParser.parse(text)
        let reconciled = reconcile(deterministic: deterministic, intelligent: intelligent)

        return Result(
            diff: ScheduleDiff.between(current: current, incoming: reconciled),
            sourceText: text,
            method: .freeText,
            usedModel: !intelligent.isEmpty,
            modelUnavailableReason: intelligent.isEmpty ? IntelligentParser.unavailableReason : nil)
    }

    static func capture(text: String, against current: [ClassEvent]) async -> Result {
        let deterministic = HeuristicParser.parse(text)
        let intelligent = await IntelligentParser.parse(text)

        return Result(
            diff: ScheduleDiff.between(
                current: current,
                incoming: reconcile(deterministic: deterministic, intelligent: intelligent)),
            sourceText: text,
            method: .freeText,
            usedModel: !intelligent.isEmpty,
            modelUnavailableReason: intelligent.isEmpty ? IntelligentParser.unavailableReason : nil)
    }

    // MARK: - Deduplication

    /// A multi-page export repeats the same class in grid and table form, and
    /// a reader can legitimately emit it twice. Keep the most confident.
    static func dedupe(_ events: [ParsedEvent]) -> [ParsedEvent] {
        var best: [String: ParsedEvent] = [:]

        for parsed in events {
            let key = identity(parsed.event)
            if let existing = best[key], existing.confidence >= parsed.confidence { continue }
            best[key] = parsed
        }

        return best.values.sorted {
            ($0.event.dayIndex, $0.event.startSecond) < ($1.event.dayIndex, $1.event.startSecond)
        }
    }

    private static func identity(_ event: ClassEvent) -> String {
        "\(event.course.uppercased())|\(event.dayIndex)|\(event.startSecond)"
    }

    // MARK: - Reconciliation
    //
    // Only used for the unstructured path. Where the two readers agree, a row
    // is near-certain; where only one found it, it's plausible. Agreement
    // between methods that fail differently is a real measurement, unlike a
    // model's opinion of its own output, which barely varies.

    static func reconcile(deterministic: [ParsedEvent],
                          intelligent: [ParsedEvent]) -> [ParsedEvent] {

        guard !intelligent.isEmpty else {
            return deterministic.map {
                var event = $0
                event.confidence = 0.75
                return event
            }
        }

        var byKey: [String: ParsedEvent] = [:]
        let modelKeys = Set(intelligent.map { identity($0.event) })
        let regexKeys = Set(deterministic.map { identity($0.event) })

        for parsed in deterministic {
            var event = parsed
            let key = identity(parsed.event)

            if modelKeys.contains(key) {
                let twin = intelligent.first { identity($0.event) == key }
                let agreedExactly = twin.map {
                    $0.event.room == parsed.event.room
                        && $0.event.endSecond == parsed.event.endSecond
                } ?? false

                if agreedExactly {
                    event.confidence = 0.98
                } else {
                    // Both saw the meeting but disagree on a detail. The regex
                    // wins on room — a model is likelier to normalise or
                    // invent one — and the row gets flagged either way.
                    event.confidence = 0.7
                    event.uncertainFields = disagreements(parsed.event, twin?.event)
                }
            } else {
                event.confidence = 0.75
            }

            byKey[key] = event
        }

        for parsed in intelligent where !regexKeys.contains(identity(parsed.event)) {
            var event = parsed
            event.confidence = 0.55
            byKey[identity(parsed.event)] = event
        }

        return byKey.values.sorted {
            ($0.event.dayIndex, $0.event.startSecond) < ($1.event.dayIndex, $1.event.startSecond)
        }
    }

    private static func disagreements(_ a: ClassEvent, _ b: ClassEvent?) -> Set<ParsedEvent.Field> {
        guard let b else { return [] }
        var fields: Set<ParsedEvent.Field> = []
        if a.room != b.room { fields.insert(.room) }
        if a.endSecond != b.endSecond { fields.insert(.endTime) }
        return fields
    }
}
