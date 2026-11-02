import CoreLocation
import MapKit
import UserNotifications

/// Bell's background presence: which building you're in, and what that
/// means for attendance and for getting to the next class.
///
/// Built on `CLMonitor`, which keeps watching while the app isn't running
/// and relaunches it in the background on an entry or exit. Events are
/// handled here and then the app goes back to sleep; nothing runs
/// continuously, which is the difference between a geofence and a
/// battery drain.
@MainActor
@Observable
final class LocationServices {

    private(set) var isMonitoring = false
    private(set) var watched: [String] = []
    private(set) var lastEvent: String?

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var serviceSession: CLServiceSession?
    @ObservationIgnored private var events: Task<Void, Never>?

    /// Letters and digits only. "bell.buildings" crashed the app on launch:
    /// CLMonitor rejects the name with an uncaught "Monitor name is not
    /// valid" exception rather than an error, so a bad name is a crash.
    nonisolated static let monitorName = "BellBuildings"

    // MARK: - Lifecycle

    /// Called at every launch, background relaunches included: a monitor
    /// only delivers its events to a process that has opened it by name.
    func start(store: BellStore) async {
        guard Preferences.autoAttendanceEnabled else { await stop(); return }
        if monitor == nil {
            // Held for as long as monitoring is on; it's what tells the
            // system Bell still wants "always" access for this.
            serviceSession = CLServiceSession(authorization: .always)
            let monitor = await CLMonitor(Self.monitorName)
            self.monitor = monitor
            events = Task { [weak self] in
                do {
                    for try await event in await monitor.events {
                        await self?.handle(event, store: store)
                    }
                } catch {}
            }
        }
        await sync(store: store)
        isMonitoring = true
    }

    func stop() async {
        events?.cancel()
        events = nil
        if let monitor {
            for id in await monitor.identifiers { await monitor.remove(id) }
        }
        monitor = nil
        serviceSession = nil
        watched = []
        isMonitoring = false
    }

    /// Brings the watched set in line with the next two days of classes.
    func sync(store: BellStore, now: Date = .now) async {
        guard let monitor else { return }
        let plan = GeofencePlan.regions(engine: store.engine, hidden: Preferences.hiddenCourses, from: now,
                                        home: Campus.coordinate(for: "HOME"),
                                        coordinate: { Campus.coordinate(for: $0) })
        let wanted = Set(plan.map(\.building))
        for id in await monitor.identifiers where !wanted.contains(id) {
            await monitor.remove(id)
        }
        let existing = Set(await monitor.identifiers)
        for region in plan where !existing.contains(region.building) {
            await monitor.add(CLMonitor.CircularGeographicCondition(center: region.center, radius: region.radius),
                              identifier: region.building, assuming: .unsatisfied)
        }
        watched = plan.map(\.building)
    }

    // MARK: - Events

    private func handle(_ event: CLMonitor.Event, store: BellStore) async {
        let building = event.identifier
        switch event.state {
        case .satisfied:
            lastEvent = "Arrived at \(building)"
            arrived(at: building, date: event.date, store: store)
        case .unsatisfied:
            lastEvent = "Left \(building)"
            await left(building, date: event.date, store: store)
        case .unmonitored:
            // Core Location stopped watching and says why in flags rather
            // than an error. Shown in Settings, because every one of these
            // means attendance silently isn't happening.
            lastEvent = "Not watching \(building): " + Self.reason(for: event)
        default:
            break
        }
    }

    static func reason(for event: CLMonitor.Event) -> String {
        if event.authorizationDenied || event.authorizationDeniedGlobally { return "location access is off" }
        if event.authorizationRestricted { return "location is restricted on this device" }
        if event.insufficientlyInUse { return "needs location set to Always" }
        if event.accuracyLimited { return "needs Precise Location" }
        if event.conditionLimitExceeded { return "too many regions" }
        if event.conditionUnsupported { return "not supported here" }
        if event.serviceSessionRequired { return "needs an active location session" }
        if event.persistenceUnavailable { return "can't save its regions (unsigned build?)" }
        if event.authorizationRequestInProgress { return "waiting for permission" }
        return "unknown reason"
    }

    private func arrived(at building: String, date: Date, store: BellStore) {
        let today = store.engine.occurrences(on: date).filter { !Preferences.hiddenCourses.contains($0.event.course) }
        if let occurrence = AttendanceRule.occurrence(enteringBuilding: building, at: date, among: today) {
            store.record(.attended, forCourse: occurrence.event.course, at: occurrence.start, automatic: true)
        }
        // You're here: every alert about getting here is now noise.
        let arriving = today.filter {
            $0.event.building?.caseInsensitiveCompare(building) == .orderedSame && $0.end > date
        }
        Self.cancelEscalation(for: arriving)
    }

    /// Leaving a building is the moment to check the next walk against the
    /// clock again, from where you actually are rather than from the plan.
    private func left(_ building: String, date: Date, store: BellStore) async {
        guard Preferences.escalationEnabled,
              let next = store.engine.occurrences(on: date)
                .filter({ !Preferences.hiddenCourses.contains($0.event.course) })
                .first(where: { $0.end > date && $0.event.building?.caseInsensitiveCompare(building) != .orderedSame })
        else { return }

        // You've set off: the heads-up and leave-now alerts are behind you.
        let center = UNUserNotificationCenter.current()
        let prefix = Escalation.prefix(for: next)
        center.removePendingNotificationRequests(withIdentifiers: ["\(prefix)-0", "\(prefix)-1"])

        let walk = Int((Campus.walkingSeconds(from: building, to: next.event.building) / 60).rounded())
        if let alert = Escalation.onDeparture(for: next, walkMinutes: walk, at: date) {
            try? await center.add(Self.request(for: alert, room: next.event.room, immediate: true))
        }
    }

    // MARK: - Escalating alerts

    nonisolated static let categoryID = "bell.walk"

    /// The next day's walks as escalating alerts, for the notifier to
    /// schedule. Only when geofencing is on: without arrival events nothing
    /// can cancel them, and "running late" sent to someone already in their
    /// seat is the alert that gets notifications turned off.
    static func escalationRequests(engine: ScheduleEngine, hidden: Set<String>, now: Date = .now)
        -> [UNNotificationRequest] {
        guard Preferences.escalationEnabled, Preferences.autoAttendanceEnabled else { return [] }
        let end = now.addingTimeInterval(24 * 3600)
        var requests: [UNNotificationRequest] = []

        for offset in 0 ..< 2 {
            guard let day = engine.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let classes = engine.occurrences(on: day).filter { !hidden.contains($0.event.course) }
            for (index, occurrence) in classes.enumerated() where occurrence.start > now && occurrence.start < end {
                let from: String? = index > 0 ? classes[index - 1].event.building : "HOME"
                let walk = Int((Campus.walkingSeconds(from: from, to: occurrence.event.building) / 60).rounded())
                for alert in Escalation.plan(for: occurrence, walkMinutes: walk,
                                             bufferMinutes: Preferences.leaveBuffer, now: now) {
                    requests.append(request(for: alert, room: occurrence.event.room, immediate: false))
                }
            }
        }
        return requests
    }

    static func cancelEscalation(for occurrences: [ScheduleEngine.Occurrence]) {
        let ids = occurrences.flatMap { o in
            ["-0", "-1", "-2", "-route"].map { Escalation.prefix(for: o) + $0 }
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func request(for alert: Escalation.Alert, room: String, immediate: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.categoryIdentifier = categoryID
        content.userInfo = ["room": room]
        // Escalation is the point: the heads-up is quiet, the rest break
        // through Focus, because by then it's about to cost you the class.
        content.interruptionLevel = alert.level == .headsUp ? .active : .timeSensitive
        content.sound = alert.level == .headsUp ? nil : .default
        let trigger: UNNotificationTrigger = immediate
            ? UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            : UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: alert.fireAt), repeats: false)
        return UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)
    }

    // MARK: - Learning where buildings are

    /// While the app is open in class, an accurate fix becomes that
    /// building's coordinate. This is what `Campus` always said it did and,
    /// until now, never did: nothing called `record`.
    func learnFromPresence(store: BellStore, now: Date = .now) {
        guard let fix = CLLocationManager().location, now.timeIntervalSince(fix.timestamp) < 120 else { return }
        let today = store.engine.occurrences(on: now)
        if let building = BuildingLocator.buildingToLearn(
            at: now, accuracy: fix.horizontalAccuracy, occurrences: today,
            isKnown: { Campus.coordinate(for: $0) != nil }) {
            Campus.LearnedLocations.shared.record(fix.coordinate, for: building, source: .observed)
        }
    }

    /// Buildings in the timetable that Bell has no position for.
    static func unknownBuildings(in timetable: Timetable) -> [String] {
        Array(Set(timetable.events.compactMap { $0.building?.uppercased() }))
            .filter { Campus.coordinate(for: $0) == nil }
            .sorted()
    }

    /// Asks Apple Maps for each unknown building, keeping only answers that
    /// sit on campus. Needs the network, so it runs only once the user has
    /// agreed (Settings > Location): the query names buildings you have
    /// classes in, which is a small thing to send but still theirs to send.
    func lookUpUnknownBuildings(in timetable: Timetable) async -> [String: Bool] {
        guard Preferences.buildingLookupAllowed else { return [:] }
        let known = Array(Set(timetable.events.compactMap(\.building)))
            .compactMap { Campus.coordinate(for: $0) }
        guard let center = BuildingLocator.campusCenter(known) else { return [:] }

        var outcome: [String: Bool] = [:]
        for building in Self.unknownBuildings(in: timetable) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = BuildingLocator.query(for: building)
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000)
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            let results = items.map { (name: $0.name ?? "", coordinate: $0.location.coordinate) }
            if let found = BuildingLocator.pick(results, near: center) {
                Campus.LearnedLocations.shared.record(found, for: building, source: .lookedUp)
                outcome[building] = true
            } else {
                outcome[building] = false
            }
        }
        return outcome
    }

    /// "I'm at home": the start point for the first walk of the day.
    func setHomeHere() -> Bool {
        guard let fix = CLLocationManager().location, fix.horizontalAccuracy <= 100 else { return false }
        Campus.LearnedLocations.shared.record(fix.coordinate, for: "HOME", source: .observed)
        return true
    }
}
