import Foundation

/// An event from one of the user's other calendars (iCloud, Google, Outlook,
/// anything added in iOS Settings), as Bell sees it.
///
/// A value copied out of EventKit, never the `EKEvent` itself: the domain
/// stays framework-free, and these are held in memory only. Someone else's
/// calendar is not Bell's to persist, and the snapshot the widget reads is
/// already a map of where the user is every hour; it doesn't need their
/// dentist appointments too.
struct ExternalEvent: Hashable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var calendarTitle: String
    var isAllDay: Bool = false
    /// False for events marked "free" in their calendar. Those don't block
    /// time and never clash.
    var isBusy: Bool = true
    /// A campus building code found in `location`, when there is one. Only
    /// then can travel time to or from it be estimated.
    var building: String?

    /// Whether this can take up time in a day view or clash with a class.
    var occupiesTime: Bool { isBusy && !isAllDay && end > start }
}

/// Finds where the timetable and the rest of the user's life collide.
///
/// Two kinds of trouble. An overlap is two places at once. A travel clash is
/// subtler and more common: the events don't overlap, but the gap between
/// them is shorter than the walk, so one of them starts late. That's the
/// case a calendar app can't see, because it doesn't know where WALC is.
enum ConflictDetector {

    struct Conflict: Hashable, Identifiable {
        enum Kind: Hashable {
            /// Minutes the two share.
            case overlap(minutes: Int)
            /// The event ends too close to the class to walk there.
            case cantReachClass(gapMinutes: Int, walkMinutes: Int)
            /// The class ends too close to the event to walk there.
            case cantReachEvent(gapMinutes: Int, walkMinutes: Int)

            var isOverlap: Bool {
                if case .overlap = self { return true }
                return false
            }
        }

        var occurrence: ScheduleEngine.Occurrence
        var event: ExternalEvent
        var kind: Kind

        var id: String { "\(occurrence.id)|\(event.id)" }
    }

    /// - Parameter walkSeconds: building-to-building walking time, 0 when
    ///   either end is unknown or they're the same building.
    static func conflicts(classes: [ScheduleEngine.Occurrence],
                          events: [ExternalEvent],
                          walkSeconds: (String?, String?) -> TimeInterval) -> [Conflict] {
        let relevant = events.filter(\.occupiesTime)
        var found: [Conflict] = []

        // Overlaps: every pair, because a long event can cover several classes.
        for occurrence in classes {
            for event in relevant {
                let shared = min(occurrence.end, event.end).timeIntervalSince(max(occurrence.start, event.start))
                if shared >= 60 {
                    found.append(Conflict(occurrence: occurrence, event: event,
                                          kind: .overlap(minutes: Int((shared / 60).rounded()))))
                }
            }
        }

        // Travel: only between neighbours. If anything sits between an event
        // and a class, you aren't walking from one straight to the other,
        // and the distance between them stops mattering.
        enum Item { case lesson(ScheduleEngine.Occurrence), other(ExternalEvent) }
        let timeline: [(start: Date, end: Date, item: Item)] =
            (classes.map { ($0.start, $0.end, Item.lesson($0)) }
             + relevant.map { ($0.start, $0.end, Item.other($0)) })
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        for (a, b) in zip(timeline, timeline.dropFirst()) {
            let gap = b.start.timeIntervalSince(a.end)
            guard gap >= 0 else { continue }   // overlapping: reported above

            switch (a.item, b.item) {
            case (.other(let event), .lesson(let occurrence)):
                let walk = walkSeconds(event.building, occurrence.event.building)
                if walk > 0, gap < walk {
                    found.append(Conflict(occurrence: occurrence, event: event,
                                          kind: .cantReachClass(gapMinutes: Int(gap / 60),
                                                                walkMinutes: Int((walk / 60).rounded()))))
                }
            case (.lesson(let occurrence), .other(let event)):
                let walk = walkSeconds(occurrence.event.building, event.building)
                if walk > 0, gap < walk {
                    found.append(Conflict(occurrence: occurrence, event: event,
                                          kind: .cantReachEvent(gapMinutes: Int(gap / 60),
                                                                walkMinutes: Int((walk / 60).rounded()))))
                }
            default:
                continue
            }
        }

        return found.sorted { ($0.occurrence.start, $0.event.start) < ($1.occurrence.start, $1.event.start) }
    }
}

extension Campus {
    /// The first token in free text that names a building Bell knows,
    /// so "Office hours, MSEE 180" and "WALC study room" both resolve.
    /// Nil when nothing matches, which is common and fine: an event with no
    /// known place just can't produce a travel clash.
    static func building(in text: String?) -> String? {
        guard let text else { return nil }
        // Only tokens written in capitals. Building codes always are, and
        // upper-casing first turned "meet me at the library" into ME, the
        // mechanical engineering building.
        let tokens = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0 == $0.uppercased() }
        return tokens.first { token in
            token.count >= 2 && token.contains(where: \.isLetter) && coordinate(for: token) != nil
        }
    }
}
