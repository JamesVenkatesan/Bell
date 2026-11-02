import Foundation

/// What would change if an import were applied.
///
/// Import is destructive, and a schedule is something you rely on. Replacing
/// it silently because a photo parsed to *something* is the behaviour that
/// turns a useful feature into one you stop trusting. So every import is
/// computed as a diff first and shown before anything is written.
///
/// Matching is on identity, not position: a meeting is the same meeting if the
/// course, day and start time line up. That means a room change reads as a
/// change rather than as a delete plus an add, which is what you actually want
/// to see on the review screen.
struct ScheduleDiff {

    struct Change: Identifiable, Hashable {
        enum Kind: Hashable {
            case added
            case removed
            case moved(fromDay: Int, fromStart: Int)
            case retimed(fromStart: Int, fromEnd: Int)
            case relocated(from: String)

            var label: String {
                switch self {
                case .added: "New"
                case .removed: "Dropped"
                case .moved: "Different day"
                case .retimed: "Different time"
                case .relocated: "Different room"
                }
            }

            var symbol: String {
                switch self {
                case .added: "plus.circle"
                case .removed: "minus.circle"
                case .moved: "calendar"
                case .retimed: "clock"
                case .relocated: "mappin"
                }
            }

            /// Removals are the ones worth a second look — a parse that misses
            /// a class looks exactly like a class you dropped.
            var warrantsAttention: Bool {
                if case .removed = self { return true }
                return false
            }
        }

        let id = UUID()
        var kind: Kind
        var event: ClassEvent
        /// Carried through from the parser, so a low-confidence row can be
        /// shown as such rather than presented with false certainty.
        var confidence: Double

        /// Accepted by default unless there's a reason to hesitate.
        var isAccepted: Bool
    }

    var changes: [Change]
    /// Meetings that matched exactly. Not shown individually — the count is
    /// the useful part, because "17 unchanged" is what tells you the parse
    /// worked.
    var unchanged: [ClassEvent]

    var isEmpty: Bool { changes.isEmpty }

    var acceptedChanges: [Change] { changes.filter(\.isAccepted) }

    var summary: String {
        guard !changes.isEmpty else { return "No changes" }

        var parts: [String] = []
        let added = changes.filter { if case .added = $0.kind { return true }; return false }.count
        let removed = changes.filter { $0.kind.warrantsAttention }.count
        let modified = changes.count - added - removed

        if added > 0 { parts.append("\(added) new") }
        if modified > 0 { parts.append("\(modified) changed") }
        if removed > 0 { parts.append("\(removed) dropped") }

        return parts.joined(separator: ", ")
    }

    var needsAttention: Bool {
        changes.contains { $0.kind.warrantsAttention || $0.confidence < 0.6 }
    }

    // MARK: - Computing

    static func between(current: [ClassEvent],
                        incoming: [ParsedEvent]) -> ScheduleDiff {
        var changes: [Change] = []
        var unchanged: [ClassEvent] = []

        // Index-based rather than value-based matching. A course can meet
        // twice in one day — a lecture and its lab — and two equal values
        // would otherwise both resolve to the same row, so one real meeting
        // would be reported as removed.
        var claimed = Set<Int>()

        /// First unclaimed current meeting satisfying `test`.
        func claim(_ test: (ClassEvent) -> Bool) -> Int? {
            for index in current.indices where !claimed.contains(index) && test(current[index]) {
                claimed.insert(index)
                return index
            }
            return nil
        }

        for parsed in incoming {
            let event = parsed.event

            // Exact match: nothing to report.
            if claim({ isIdentical($0, event) }) != nil {
                unchanged.append(event)
                continue
            }

            // Same course, day and start: a detail moved.
            if let index = claim({
                $0.course == event.course
                    && $0.dayIndex == event.dayIndex
                    && $0.startSecond == event.startSecond
            }) {
                let old = current[index]
                let kind: Change.Kind = old.room != event.room
                    ? .relocated(from: old.room)
                    : .retimed(fromStart: old.startSecond, fromEnd: old.endSecond)

                changes.append(Change(kind: kind,
                                      event: event,
                                      confidence: parsed.confidence,
                                      isAccepted: true))
                continue
            }

            // Same course and room: it moved in the week.
            if let index = claim({ $0.course == event.course && $0.room == event.room }) {
                let old = current[index]
                let kind: Change.Kind = old.dayIndex != event.dayIndex
                    ? .moved(fromDay: old.dayIndex, fromStart: old.startSecond)
                    : .retimed(fromStart: old.startSecond, fromEnd: old.endSecond)

                changes.append(Change(kind: kind,
                                      event: event,
                                      confidence: parsed.confidence,
                                      isAccepted: true))
                continue
            }

            changes.append(Change(kind: .added,
                                  event: event,
                                  confidence: parsed.confidence,
                                  // A class that isn't real is worse than one
                                  // extra tap, so weak additions start off.
                                  isAccepted: parsed.confidence >= 0.6))
        }

        for index in current.indices where !claimed.contains(index) {
            changes.append(Change(kind: .removed,
                                  event: current[index],
                                  confidence: 1,
                                  // Never drop a class without being told to.
                                  isAccepted: false))
        }

        return ScheduleDiff(changes: changes, unchanged: unchanged)
    }

    private static func isIdentical(_ a: ClassEvent, _ b: ClassEvent) -> Bool {
        a.course == b.course
            && a.room == b.room
            && a.dayIndex == b.dayIndex
            && a.startSecond == b.startSecond
            && a.endSecond == b.endSecond
    }

    /// The schedule that results from accepting the ticked changes. Rejected
    /// removals stay; rejected additions don't appear.
    func resolved(from current: [ClassEvent]) -> [ClassEvent] {
        var result = unchanged

        for change in changes {
            switch change.kind {
            case .removed:
                // Unticked means "don't drop it", so it survives.
                if !change.isAccepted { result.append(change.event) }
            case .added, .moved, .retimed, .relocated:
                if change.isAccepted { result.append(change.event) }
            }
        }

        // A rejected modification means keeping what was there before.
        for change in changes where !change.isAccepted {
            switch change.kind {
            case .moved, .retimed, .relocated:
                if let original = current.first(where: { $0.course == change.event.course }) {
                    result.append(original)
                }
            default:
                break
            }
        }

        return result.sorted { ($0.dayIndex, $0.startSecond) < ($1.dayIndex, $1.startSecond) }
    }
}

/// A meeting as it came out of a parser, with how much the parser trusts it.
struct ParsedEvent: Hashable {
    var event: ClassEvent
    /// 0…1. Driven by whether independent parsers agreed, not by the model's
    /// own opinion of itself — a model's self-reported confidence is close to
    /// useless.
    var confidence: Double
    /// Which fields were uncertain, for the review screen to highlight.
    var uncertainFields: Set<Field>

    enum Field: String, Hashable {
        case course, room, day, startTime, endTime
    }

    init(event: ClassEvent,
         confidence: Double = 1,
         uncertainFields: Set<Field> = []) {
        self.event = event
        self.confidence = confidence
        self.uncertainFields = uncertainFields
    }
}
