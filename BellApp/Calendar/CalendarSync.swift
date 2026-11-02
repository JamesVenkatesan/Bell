import EventKit
import WidgetKit
import SwiftUI

/// Bell's side of the system calendar.
///
/// Writes the timetable into one calendar so classes appear wherever the
/// iPhone's calendars are shown, and reads the user's other calendars so
/// Bell can see clashes. No API keys and no network of its own: if a Google
/// or Outlook account is added in iOS Settings, EventKit already has it.
///
/// All judgement lives in `CalendarReconciler`. This type only translates
/// between EventKit objects and those plain values, so that the part that
/// could delete someone's events is the part with tests.
@MainActor
@Observable
final class CalendarSync {

    enum Access: Equatable {
        case notDetermined, granted, writeOnly, denied
    }

    struct Report: Equatable {
        var created = 0
        var updated = 0
        var deleted = 0
        var cancelledKeys: [String] = []
        var suspectedReset = false
        var at = Date.now
    }

    private(set) var access: Access = .notDetermined
    private(set) var external: [ExternalEvent] = []
    private(set) var lastReport: Report?
    private(set) var lastError: String?

    @ObservationIgnored let store = EKEventStore()

    init() { refreshAccess() }

    // MARK: - Access

    func refreshAccess() {
        access = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Full access, not write-only: reading the other calendars is half the
    /// feature, and write-only can't see even Bell's own events to update
    /// them, so it would duplicate on every sync.
    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refreshAccess()
    }

    // MARK: - Calendars

    /// Calendars that can be written to, for the "where" picker. Bell's own
    /// is first when it exists.
    var writableCalendars: [EKCalendar] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.calendarIdentifier == Preferences.calendarIdentifier ? 0 : 1, $0.title)
                    < ($1.calendarIdentifier == Preferences.calendarIdentifier ? 0 : 1, $1.title) }
    }

    /// Every event calendar, for choosing which ones count as busy.
    ///
    /// Includes the write target: when that's an existing calendar the user
    /// chose, their own events in it still need to count. Bell's events are
    /// filtered out by key when reading, not by calendar.
    var readableCalendars: [EKCalendar] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// The calendar Bell writes to, creating "Bell" if none is chosen yet.
    ///
    /// Created in iCloud when there is one, so it reaches the user's Mac and
    /// iCloud.com too; otherwise on the device. A Google or Exchange account
    /// can't be given a new calendar from iOS, so for those the user picks an
    /// existing calendar instead (Settings > Calendar > Write to).
    func targetCalendar() throws -> EKCalendar {
        if let id = Preferences.calendarIdentifier,
           let existing = store.calendar(withIdentifier: id),
           existing.allowsContentModifications {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Bell"
        calendar.cgColor = UIColor(Bell.Signal.inferred).cgColor
        calendar.source = store.sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
        try store.saveCalendar(calendar, commit: true)
        Preferences.calendarIdentifier = calendar.calendarIdentifier
        // A new calendar has none of the old ledger's events in it, so the
        // old ledger would read every class as deleted. Start clean.
        Preferences.calendarLedger = []
        return calendar
    }

    func chooseTarget(_ calendar: EKCalendar) {
        guard calendar.calendarIdentifier != Preferences.calendarIdentifier else { return }
        Preferences.calendarIdentifier = calendar.calendarIdentifier
        Preferences.calendarLedger = []
    }

    // MARK: - Writing

    /// Brings the target calendar in line with the timetable. Returns the
    /// keys the user deleted, for the caller to record as cancellations.
    @discardableResult
    func sync(engine: ScheduleEngine, hidden: Set<String>, now: Date = .now) -> Report? {
        guard access == .granted, Preferences.calendarWritesEnabled else { return nil }

        do {
            let calendar = try targetCalendar()
            let desired = CalendarPlan.desired(engine: engine, from: now, hidden: hidden)
            let windowStart = engine.calendar.startOfDay(for: now)
            let windowEnd = engine.calendar.date(byAdding: .day, value: CalendarPlan.horizonDays,
                                                 to: windowStart) ?? now

            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd,
                                                     calendars: [calendar])
            let events = store.events(matching: predicate)
            let byID = Dictionary(events.map { ($0.calendarItemIdentifier, $0) },
                                  uniquingKeysWith: { first, _ in first })
            let existing = events.map {
                CalendarReconciler.Existing(identifier: $0.calendarItemIdentifier,
                                            key: CalendarPlan.key(url: $0.url, notes: $0.notes),
                                            title: $0.title ?? "",
                                            location: $0.location ?? "",
                                            start: $0.startDate,
                                            end: $0.endDate)
            }

            let plan = CalendarReconciler.reconcile(desired: desired, existing: existing,
                                                    ledger: Set(Preferences.calendarLedger))

            for planned in plan.create {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                apply(planned, to: event)
                try store.save(event, span: .thisEvent, commit: false)
            }
            for update in plan.update {
                guard let event = byID[update.identifier] else { continue }
                apply(update.planned, to: event)
                try store.save(event, span: .thisEvent, commit: false)
            }
            for identifier in plan.delete {
                guard let event = byID[identifier] else { continue }
                try store.remove(event, span: .thisEvent, commit: false)
            }
            if !plan.isEmpty { try store.commit() }

            Preferences.calendarLedger = Array(plan.ledger)
            let report = Report(created: plan.create.count,
                                updated: plan.update.count,
                                deleted: plan.delete.count,
                                cancelledKeys: plan.cancelled,
                                suspectedReset: plan.suspectedReset)
            lastReport = report
            lastError = nil
            return report
        } catch {
            store.reset()
            lastError = error.localizedDescription
            return nil
        }
    }

    private func apply(_ planned: CalendarPlan.Planned, to event: EKEvent) {
        event.title = planned.title
        event.startDate = planned.start
        event.endDate = planned.end
        event.notes = planned.notes
        event.url = CalendarPlan.url(for: planned.key)
        event.availability = .busy

        // A structured location with real coordinates is what lets Calendar
        // show a map and its own "time to leave", for free.
        let location = EKStructuredLocation(title: planned.location)
        let building = planned.location.split(separator: " ").first.map(String.init)
        if let coordinate = RoomCoordinates.coordinate(forRoom: planned.location)
            ?? Campus.coordinate(for: building) {
            location.geoLocation = CLLocation(latitude: coordinate.latitude,
                                              longitude: coordinate.longitude)
        }
        event.structuredLocation = planned.location.isEmpty ? nil : location
        event.location = planned.location
    }

    /// Removes every event Bell wrote, leaving the calendar itself (it may be
    /// one the user chose, with their own events in it).
    func removeAll() {
        guard access == .granted,
              let id = Preferences.calendarIdentifier,
              let calendar = store.calendar(withIdentifier: id) else { return }
        let start = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
        let end = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        for event in store.events(matching: predicate)
        where CalendarPlan.key(url: event.url, notes: event.notes) != nil {
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
        Preferences.calendarLedger = []
    }

    // MARK: - Reading

    /// The user's other events from a week back to the sync horizon, for
    /// the day view and for clash detection.
    func loadExternal(now: Date = .now) {
        guard access == .granted, Preferences.calendarReadsEnabled else {
            external = []
            return
        }
        let calendars = readableCalendars
            .filter { !Preferences.excludedCalendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { external = []; return }

        let start = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now)) ?? now
        let end = Calendar.current.date(byAdding: .day, value: CalendarPlan.horizonDays, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)

        external = store.events(matching: predicate)
            // Bell's events in a calendar the user also reads would clash
            // with themselves.
            .filter { CalendarPlan.key(url: $0.url, notes: $0.notes) == nil }
            .map { event in
                ExternalEvent(id: "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))",
                              title: event.title ?? "Busy",
                              start: event.startDate,
                              end: event.endDate,
                              location: event.location,
                              calendarTitle: event.calendar.title,
                              isAllDay: event.isAllDay,
                              isBusy: event.availability != .free,
                              building: Campus.building(in: event.location))
            }
    }

    /// Busy times only, for the Free widget. See `SnapshotCache.writeBusy`.
    func publishBusyTimes() {
        SnapshotCache.writeBusy(external.filter(\.occupiesTime).map { DateInterval(start: $0.start, end: $0.end) })
        WidgetCenter.shared.reloadAllTimelines()
    }

    func external(on day: Date) -> [ExternalEvent] {
        let calendar = Calendar.current
        return external.filter { $0.occupiesTime && calendar.isDate($0.start, inSameDayAs: day) }
    }
}
