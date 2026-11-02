import CoreLocation
import Foundation

// Phase 6's decisions, apart from Core Location. What to watch, when being
// in a building counts as attending, when to nag and how hard, which search
// result is really the building: each a pure function with tests, so the
// code that runs in the background (where it can't be watched) is the code
// that has been checked.

// MARK: - Which buildings to watch

/// iOS lets an app watch 20 regions. A term's buildings fit, but
/// a week's worth of distinct rooms plus HOME can crowd the limit, so the
/// choice is made by time: the buildings of the classes coming soonest.
enum GeofencePlan {

    struct Region: Equatable {
        var building: String
        var center: CLLocationCoordinate2D
        var radius: CLLocationDistance

        static func == (a: Region, b: Region) -> Bool {
            a.building == b.building && a.radius == b.radius
                && a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
        }
    }

    static let limit = 20

    /// 100 m: Apple's own guidance for reliable region monitoring, and wider
    /// than any building's walls plus indoor GPS error. A tighter circle
    /// misses entries made through the far door.
    static let radius: CLLocationDistance = 100

    static func regions(engine: ScheduleEngine,
                        hidden: Set<String>,
                        from now: Date,
                        days: Int = 2,
                        home: CLLocationCoordinate2D? = nil,
                        coordinate: (String) -> CLLocationCoordinate2D?) -> [Region] {
        var seen: Set<String> = []
        var result: [Region] = []
        // Home first, when known: leaving it is the departure that decides
        // whether the first class of the day is made, so it's the one most
        // worth re-checking live.
        if let home {
            seen.insert("HOME")
            result.append(Region(building: "HOME", center: home, radius: radius))
        }
        for occurrence in engine.occurrences(from: engine.calendar.startOfDay(for: now), forwardDays: days)
        where occurrence.end > now && !hidden.contains(occurrence.event.course) {
            guard let building = occurrence.event.building?.uppercased(), !seen.contains(building),
                  let center = coordinate(building) else { continue }
            seen.insert(building)
            result.append(Region(building: building, center: center, radius: radius))
            if result.count == limit { break }
        }
        return result
    }
}

// MARK: - Attendance from presence

enum AttendanceRule {

    /// Arriving up to 15 minutes early counts, and so does arriving late
    /// until halfway through: past that you were in the building, but
    /// "attended" would be generous, and it's better left for the user.
    static let earlyMinutes: TimeInterval = 15

    /// The class that being in `building` at `date` means attending.
    static func occurrence(enteringBuilding building: String,
                           at date: Date,
                           among occurrences: [ScheduleEngine.Occurrence]) -> ScheduleEngine.Occurrence? {
        occurrences.first { occurrence in
            guard occurrence.event.building?.caseInsensitiveCompare(building) == .orderedSame else { return false }
            let opens = occurrence.start.addingTimeInterval(-earlyMinutes * 60)
            let closes = occurrence.start.addingTimeInterval(max(10 * 60, occurrence.end.timeIntervalSince(occurrence.start) / 2))
            return date >= opens && date <= closes
        }
    }
}

// MARK: - Escalation

/// Alerts that get firmer as the walk becomes impossible, and stop the
/// moment you arrive.
///
/// Three steps, scheduled ahead because the app isn't running when they're
/// due: a heads-up, then "leave now", then the honest number for how late
/// you'll be. Region events make them live: leaving the building you're in
/// re-estimates from where you left, and entering the destination cancels
/// whatever hasn't fired.
enum Escalation {

    enum Level: Int, Comparable {
        case headsUp, leaveNow, late
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Alert: Equatable {
        var id: String
        var fireAt: Date
        var level: Level
        var title: String
        var body: String
    }

    static func prefix(for occurrence: ScheduleEngine.Occurrence) -> String { "esc-\(occurrence.key)" }

    /// Which classes a set of escalation request ids covers.
    static func coveredKeys(_ identifiers: [String]) -> Set<String> {
        Set(identifiers.compactMap { id in
            guard id.hasPrefix("esc-"), let dash = id.lastIndex(of: "-") else { return nil }
            return String(id[id.index(id.startIndex, offsetBy: 4) ..< dash])
        })
    }

    static func plan(for occurrence: ScheduleEngine.Occurrence,
                     walkMinutes: Int,
                     bufferMinutes: Int,
                     now: Date) -> [Alert] {
        guard walkMinutes > 0 else { return [] }
        let walk = TimeInterval(walkMinutes * 60)
        let leave = occurrence.start.addingTimeInterval(-walk - TimeInterval(bufferMinutes * 60))
        let course = occurrence.event.course
        let room = occurrence.event.room.isEmpty ? "" : " in \(occurrence.event.room)"
        let id = prefix(for: occurrence)

        // Two minutes past the last moment you could leave and arrive on
        // time. Was "leave-now plus five", which with the default five
        // minute buffer landed exactly on time, so it never fired.
        let lateCheck = occurrence.start.addingTimeInterval(-walk + 2 * 60)
        let lateBy = Int((lateCheck.addingTimeInterval(walk).timeIntervalSince(occurrence.start) / 60).rounded())

        let alerts = [
            Alert(id: "\(id)-0", fireAt: leave.addingTimeInterval(-10 * 60), level: .headsUp,
                  title: "Leave in 10 minutes",
                  body: "\(course)\(room) at \(BriefWriter.clock(occurrence.start)), a \(walkMinutes) minute walk."),
            Alert(id: "\(id)-1", fireAt: leave, level: .leaveNow,
                  title: "Leave now for \(course)",
                  body: "\(walkMinutes) minute walk\(room.isEmpty ? "" : " to \(occurrence.event.room)"), starting \(BriefWriter.clock(occurrence.start))."),
            // Only worth sending if leaving now would actually make you late;
            // otherwise the buffer absorbs it and it's just noise.
            lateBy > 0 ? Alert(id: "\(id)-2", fireAt: lateCheck, level: .late,
                               title: "Running late for \(course)",
                               body: "Leaving now gets you there about \(lateBy) minute\(lateBy == 1 ? "" : "s") late.")
                       : nil,
        ].compactMap { $0 }

        return alerts.filter { $0.fireAt > now }
    }

    /// Re-estimate on leaving a building, from where you actually left.
    /// Returns an alert to send now when the new estimate makes you late.
    static func onDeparture(for occurrence: ScheduleEngine.Occurrence,
                            walkMinutes: Int,
                            at departure: Date) -> Alert? {
        let arrival = departure.addingTimeInterval(TimeInterval(walkMinutes * 60))
        let late = Int((arrival.timeIntervalSince(occurrence.start) / 60).rounded())
        guard late > 0, departure < occurrence.end else { return nil }
        return Alert(id: "\(prefix(for: occurrence))-route", fireAt: departure, level: .late,
                     title: "About \(late) minute\(late == 1 ? "" : "s") late to \(occurrence.event.course)",
                     body: "\(walkMinutes) minutes from here to \(occurrence.event.room.isEmpty ? "class" : occurrence.event.room). Tap for the walking route.")
    }
}

// MARK: - Finding buildings

enum BuildingLocator {

    /// What to ask Apple Maps. The campus name does the disambiguating:
    /// "EE" alone is everywhere; "EE Purdue University" is one building.
    static func query(for building: String, campus: String = "Purdue University") -> String {
        "\(building) \(campus)"
    }

    /// Middle of the buildings already known, for judging search results.
    static func campusCenter(_ known: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !known.isEmpty else { return nil }
        return CLLocationCoordinate2D(
            latitude: known.map(\.latitude).reduce(0, +) / Double(known.count),
            longitude: known.map(\.longitude).reduce(0, +) / Double(known.count))
    }

    /// The result to trust, or none.
    ///
    /// A search will always return *something*. A result miles from every
    /// other building is a same-named place elsewhere, and a wrong pin is
    /// worse than none: it produces confident walking times to the wrong
    /// building. So: within 2.5 km of campus, and the nearest of those.
    static let maximumDistance: CLLocationDistance = 2500

    static func pick(_ results: [(name: String, coordinate: CLLocationCoordinate2D)],
                     near center: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        guard let center else { return nil }
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return results
            .map { ($0.coordinate, origin.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                                                     longitude: $0.coordinate.longitude))) }
            .filter { $0.1 <= maximumDistance }
            .min { $0.1 < $1.1 }?.0
    }

    /// Whether a location fix taken now should become a building's
    /// coordinate: you're in a class in a building Bell doesn't know, and
    /// the fix is accurate enough to be inside it rather than near it.
    static func buildingToLearn(at date: Date,
                                accuracy: CLLocationAccuracy,
                                occurrences: [ScheduleEngine.Occurrence],
                                isKnown: (String) -> Bool) -> String? {
        guard accuracy > 0, accuracy <= 40,
              let current = occurrences.first(where: {
                  // Ten minutes in, so you're in the room, not still walking up.
                  date >= $0.start.addingTimeInterval(10 * 60) && date < $0.end
              }),
              let building = current.event.building, !isKnown(building)
        else { return nil }
        return building
    }
}

// MARK: - Live Activity

enum ActivityPolicy {

    /// Three hours ahead: long enough that opening Bell over lunch starts the
    /// afternoon class's activity, short enough that it isn't sitting on the
    /// lock screen from breakfast. ActivityKit can't start one later from
    /// the background, so the earliest moment the app is open has to count.
    static let leadTime: TimeInterval = 3 * 3600

    static func occurrenceToShow(engine: ScheduleEngine, hidden: Set<String>, now: Date) -> ScheduleEngine.Occurrence? {
        let today = engine.occurrences(on: now).filter { !hidden.contains($0.event.course) }
        if let current = today.first(where: { $0.start <= now && now < $0.end }) { return current }
        return today.first { $0.start > now && $0.start.timeIntervalSince(now) <= leadTime }
    }
}
