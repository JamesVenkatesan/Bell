import CoreLocation
import SwiftUI
import WidgetKit

struct ScheduleEntry: TimelineEntry {
    var date: Date
    /// The whole day, including finished classes, so the widget can show them
    /// dimmed rather than dropping them. Seeing what you've already done is
    /// most of what makes a schedule feel like a schedule.
    var today: [ScheduleEngine.Occurrence]
    var current: ScheduleEngine.Occurrence?
    var next: ScheduleEngine.Occurrence?
    var leaveBy: Date?
    var walkNote: String?
    /// Minutes from where you actually are to the next class, when location is
    /// available and the room has a coordinate on file.
    var etaMinutes: Int?
    var quietReason: String?
    var palette: [String: Color]

    var upcoming: [ScheduleEngine.Occurrence] {
        today.filter { $0.end > date }
    }

    var finished: [ScheduleEngine.Occurrence] {
        today.filter { $0.end <= date }
    }

    static let placeholder = ScheduleEntry(
        date: .now, today: [], current: nil, next: nil,
        leaveBy: nil, walkNote: nil, etaMinutes: nil,
        quietReason: nil, palette: [:])
}

struct ScheduleProvider: TimelineProvider {

    func placeholder(in context: Context) -> ScheduleEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        Task { completion(await entry(at: .now, location: nil)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        Task {
            // One location fix for the whole timeline. Asking per-entry would
            // be both slower and pointless — you can't be in two places at the
            // times these entries describe.
            let location = await LocationProvider.shared.currentLocation()

            let engine = ScheduleEngine(timetable: SharedStore.load())
            let now = Date.now

            // Refresh at the moments the display actually changes: each class
            // start and end, each leave-by threshold, and midnight.
            let points = Array(engine.refreshPoints(from: now, days: 2).prefix(40))

            // First pass gives us the leave-by moments, which depend on live
            // location and so can't be known before the entries are built.
            var dates = [now] + points
            var entries: [ScheduleEntry] = []
            for date in dates {
                entries.append(await entry(at: date, location: location))
            }

            // Second pass: add an entry at each leave-by instant so the badge
            // flips to "Leave now" exactly then, instead of whenever the next
            // class boundary happens to come round.
            let leavePoints = Set(entries.compactMap(\.leaveBy)).filter { $0 > now }
            if !leavePoints.isEmpty {
                dates = (Set(dates).union(leavePoints)).sorted()
                entries = []
                for date in dates {
                    entries.append(await entry(at: date, location: location))
                }
            }

            // Ask for an earlier wake than the next boundary when we have
            // location, so the ETA doesn't sit still for hours.
            let boundary = points.first ?? now.addingTimeInterval(3600)
            let reload = location == nil
                ? boundary
                : min(boundary, now.addingTimeInterval(900))

            completion(Timeline(entries: entries, policy: .after(reload)))
        }
    }

    private func entry(at date: Date, location: CLLocation?) async -> ScheduleEntry {
        let timetable = SharedStore.load()
        let engine = ScheduleEngine(timetable: timetable)
        let palette = SharedStore.palette()
        let hidden = SharedStore.hiddenCourses

        guard !timetable.events.isEmpty else {
            return ScheduleEntry(
                date: date, today: [], current: nil, next: nil,
                leaveBy: nil, walkNote: nil, etaMinutes: nil,
                quietReason: "Import your timetable to get started", palette: palette)
        }

        let quiet: String? = {
            if let holiday = engine.exception(on: date) { return holiday.name }
            if !engine.isInTerm(date) { return "Out of term" }
            return nil
        }()

        let today = engine.occurrences(on: date)
            .filter { !hidden.contains($0.event.course) }

        let current = today.first { $0.status(at: date) == .inProgress }
        let next = engine.next(after: date).keeping { !hidden.contains($0.event.course) }

        var leaveBy: Date?
        var walkNote: String?
        var eta: Int?

        if let next {
            leaveBy = engine.leaveTime(for: next, comingFrom: current)?
                .addingTimeInterval(-Double(SharedStore.leaveBuffer * 60))
            walkNote = Campus.walkDescription(
                from: current?.event.building, to: next.event.building)

            // Live position beats the building-to-building estimate whenever
            // we have it, because it accounts for you not being where the
            // timetable assumes you are.
            if let location {
                eta = LocationProvider.walkingMinutes(from: location, toRoom: next.event.room)
                if let eta {
                    leaveBy = next.start.addingTimeInterval(
                        -Double((eta + SharedStore.leaveBuffer) * 60))
                    walkNote = eta == 0 ? "You're there" : "\(eta) min away"
                }
            }
        }

        return ScheduleEntry(
            date: date, today: today, current: current, next: next,
            leaveBy: leaveBy, walkNote: walkNote, etaMinutes: eta,
            quietReason: quiet, palette: palette)
    }
}

extension Optional {
    func keeping(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
        guard let self, isIncluded(self) else { return nil }
        return self
    }
}
