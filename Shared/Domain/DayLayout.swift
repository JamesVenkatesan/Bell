import Foundation

/// A day laid out at true scale.
///
/// The today screen and the widgets both draw the day as a vertical (or, in a
/// widget, horizontal) strip where length is proportional to time. That is
/// the whole point of the view: a ten-minute change and a three-hour gap
/// should look different at a glance, because finding free time is the
/// question a list of equal-height rows can't answer.
///
/// Kept free of SwiftUI so the arithmetic, which is where the bugs would be,
/// can be tested directly. Views ask this type where things go and draw them.
struct DayLayout {

    // MARK: - Output

    struct Block: Identifiable, Hashable {
        var occurrence: ScheduleEngine.Occurrence
        var y: Double
        var height: Double
        /// Side-by-side position for overlapping classes. 0 for the normal
        /// case; 1 and up only when two meetings genuinely collide.
        var lane: Int
        var laneCount: Int

        var id: String { occurrence.id }
    }

    /// An event from another calendar, drawn alongside classes.
    struct BusyBlock: Identifiable, Hashable {
        var event: ExternalEvent
        var y: Double
        var height: Double
        var lane: Int
        var laneCount: Int

        var id: String { event.id }
    }

    struct Gap: Identifiable, Hashable {
        enum Kind: Hashable {
            /// The walk doesn't fit. Drawn as a warning.
            case tight
            /// Long enough to do something with. Named as free time.
            case free
            /// A short change between rooms: shown, but quietly.
            case change
        }

        var start: Date
        var end: Date
        var y: Double
        var height: Double
        var kind: Kind
        var walkMinutes: Int?

        var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
        var id: Date { start }
    }

    let windowStart: Date
    let windowEnd: Date
    let pointsPerMinute: Double
    let blocks: [Block]
    let busyBlocks: [BusyBlock]
    let gaps: [Gap]

    var height: Double { minutes(from: windowStart, to: windowEnd) * pointsPerMinute }

    // MARK: - Tuning
    //
    // Layout constants, not design tokens: they describe how time maps to
    // space, which no other surface shares.

    /// Below this a gap is a room change rather than time you could use.
    static let freeThresholdMinutes = 30

    /// A fifty-minute class needs room for a course code and a room on two
    /// lines. Scale is raised until the shortest class gets that, so true
    /// scale never costs legibility.
    static let minimumBlockHeight: Double = 56

    /// Ceiling on that raise, so one ten-minute meeting can't stretch the
    /// whole day into a scroll marathon.
    static let maximumPointsPerMinute: Double = 2.4

    // MARK: - Building

    /// - Parameters:
    ///   - occurrences: one day's classes, in any order.
    ///   - basePointsPerMinute: the scale to use when every class already fits.
    ///   - walkSeconds: building-to-building walk time. Injected so tests
    ///     don't depend on real campus coordinates.
    ///   - busy: events from other calendars. They take space and lanes
    ///     like classes, and a gap they fill is not free time.
    init(occurrences: [ScheduleEngine.Occurrence],
         busy: [ExternalEvent] = [],
         basePointsPerMinute: Double = 1.1,
         calendar: Calendar = .current,
         walkSeconds: (String?, String?) -> TimeInterval) {

        let sorted = occurrences.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let others = busy.filter(\.occupiesTime).sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        // One timeline of everything that takes time, so window, lanes and
        // gaps all see the same day.
        enum Kind { case lesson(Int), other(Int) }
        struct Item { var start: Date; var end: Date; var building: String?; var kind: Kind }
        let items = (sorted.enumerated().map { Item(start: $1.start, end: $1.end,
                                                    building: $1.event.building, kind: .lesson($0)) }
                     + others.enumerated().map { Item(start: $1.start, end: $1.end,
                                                      building: $1.building, kind: .other($0)) })
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        guard let first = items.first,
              let lastEnd = items.map(\.end).max()
        else {
            windowStart = .distantPast
            windowEnd = .distantPast
            pointsPerMinute = basePointsPerMinute
            blocks = []
            busyBlocks = []
            gaps = []
            return
        }

        // Whole hours either side, so the axis labels land on round numbers
        // and the first class never sits flush against the top edge.
        windowStart = Self.floorHour(first.start, calendar: calendar)
        windowEnd = Self.ceilHour(lastEnd, calendar: calendar)

        // Legibility drives scale for classes only. A five-minute reminder
        // in someone's calendar shouldn't stretch the whole day.
        let shortest = sorted.map { $0.end.timeIntervalSince($0.start) / 60 }.filter { $0 > 0 }.min() ?? 60
        pointsPerMinute = min(Self.maximumPointsPerMinute,
                              max(basePointsPerMinute, Self.minimumBlockHeight / shortest))

        let lanes = Self.assignLanes(items.map { ($0.start, $0.end) })
        let origin = windowStart
        let scale = pointsPerMinute
        func y(_ date: Date) -> Double { Self.minutes(from: origin, to: date) * scale }
        func height(_ a: Date, _ b: Date) -> Double { max(1, Self.minutes(from: a, to: b) * scale) }

        var lessonBlocks: [Block] = []
        var otherBlocks: [BusyBlock] = []
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .lesson(let i):
                let occurrence = sorted[i]
                lessonBlocks.append(Block(occurrence: occurrence, y: y(occurrence.start),
                                          height: height(occurrence.start, occurrence.end),
                                          lane: lanes[index].lane, laneCount: lanes[index].count))
            case .other(let i):
                let event = others[i]
                otherBlocks.append(BusyBlock(event: event, y: y(event.start),
                                             height: height(event.start, event.end),
                                             lane: lanes[index].lane, laneCount: lanes[index].count))
            }
        }
        blocks = lessonBlocks
        busyBlocks = otherBlocks

        // Gaps are measured from the latest end so far, not the previous
        // row's end: with an overlap, the earlier item can finish after the
        // later one, and measuring from the wrong one invents free time.
        var result: [Gap] = []
        var runningEnd = first.end
        var runningLast = first
        for item in items.dropFirst() {
            if item.start > runningEnd {
                let walk = walkSeconds(runningLast.building, item.building)
                let available = item.start.timeIntervalSince(runningEnd)
                let kind: Gap.Kind
                if walk > 0, available < walk {
                    kind = .tight
                } else if available >= Double(Self.freeThresholdMinutes * 60) {
                    kind = .free
                } else {
                    kind = .change
                }
                result.append(Gap(start: runningEnd, end: item.start,
                                  y: y(runningEnd), height: height(runningEnd, item.start),
                                  kind: kind,
                                  walkMinutes: walk > 0 ? Int((walk / 60).rounded()) : nil))
            }
            if item.end >= runningEnd {
                runningEnd = item.end
                runningLast = item
            }
        }
        gaps = result
    }

    // MARK: - Questions views ask

    func y(for date: Date) -> Double {
        Self.minutes(from: windowStart, to: date) * pointsPerMinute
    }

    /// Where the now hairline goes, or nil when now is outside the drawn day.
    /// A line pinned to the top or bottom edge would claim a time it isn't.
    func nowY(at now: Date) -> Double? {
        guard !blocks.isEmpty || !busyBlocks.isEmpty, now >= windowStart, now <= windowEnd else { return nil }
        return y(for: now)
    }

    /// 0…1 position across the window, for the widget's horizontal ribbon.
    func fraction(for date: Date) -> Double {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(windowStart) / span))
    }

    /// One mark per whole hour across the window, inclusive at both ends.
    func hourMarks(calendar: Calendar = .current) -> [Date] {
        guard windowEnd > windowStart else { return [] }
        var marks: [Date] = []
        var cursor = windowStart
        while cursor <= windowEnd {
            marks.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    // MARK: - Helpers

    private static func minutes(from a: Date, to b: Date) -> Double {
        b.timeIntervalSince(a) / 60
    }

    private func minutes(from a: Date, to b: Date) -> Double { Self.minutes(from: a, to: b) }

    static func floorHour(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    static func ceilHour(_ date: Date, calendar: Calendar) -> Date {
        let floor = floorHour(date, calendar: calendar)
        guard floor < date else { return date }
        return calendar.date(byAdding: .hour, value: 1, to: floor) ?? date
    }

    /// Greedy interval colouring. Two clashing classes sit side by side
    /// rather than one hiding the other, because a clash is exactly the thing
    /// that must not be invisible.
    private static func assignLanes(_ sorted: [(start: Date, end: Date)]) -> [(lane: Int, count: Int)] {
        var laneEnds: [Date] = []
        var lanes: [Int] = []
        // Cluster = a run of transitively overlapping classes; every member
        // shares the cluster's lane count so their widths agree.
        var clusterStart = 0
        var clusterEnd = Date.distantPast
        var counts = Array(repeating: 1, count: sorted.count)

        func closeCluster(upTo index: Int) {
            let width = Set(lanes[clusterStart ..< index]).count
            for i in clusterStart ..< index { counts[i] = max(1, width) }
        }

        for (index, occurrence) in sorted.enumerated() {
            if occurrence.start >= clusterEnd, index > 0 {
                closeCluster(upTo: index)
                clusterStart = index
                laneEnds.removeAll()
            }
            if let free = laneEnds.firstIndex(where: { $0 <= occurrence.start }) {
                laneEnds[free] = occurrence.end
                lanes.append(free)
            } else {
                laneEnds.append(occurrence.end)
                lanes.append(laneEnds.count - 1)
            }
            clusterEnd = max(clusterEnd, occurrence.end)
        }
        if !sorted.isEmpty { closeCluster(upTo: sorted.count) }

        return zip(lanes, counts).map { ($0, $1) }
    }
}

// MARK: - Which rows fit

/// Chooses which of a day's classes to show when there's room for only some.
///
/// The naive `prefix(limit)` keeps the *earliest* rows, which by late
/// afternoon are all finished ones — the widget then shows the morning and
/// hides what's still ahead. This keeps everything not yet over, and spends
/// whatever room is left on the most recent finished classes, so the list
/// still reads as a day in progress.
enum RowWindow {
    struct Result: Equatable {
        var rows: [ScheduleEngine.Occurrence]
        /// Finished classes left out above the list.
        var hiddenEarlier: Int
        /// Upcoming classes that didn't fit below.
        var hiddenLater: Int
    }

    static func select(_ day: [ScheduleEngine.Occurrence], now: Date, limit: Int) -> Result {
        guard limit > 0 else {
            let done = day.filter { $0.end <= now }.count
            return Result(rows: [], hiddenEarlier: done, hiddenLater: day.count - done)
        }
        let finished = day.filter { $0.end <= now }
        let remaining = day.filter { $0.end > now }

        let shownRemaining = Array(remaining.prefix(limit))
        let room = limit - shownRemaining.count
        let shownFinished = room > 0 ? Array(finished.suffix(room)) : []

        return Result(rows: shownFinished + shownRemaining,
                      hiddenEarlier: finished.count - shownFinished.count,
                      hiddenLater: remaining.count - shownRemaining.count)
    }
}
