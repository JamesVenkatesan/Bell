import CoreLocation
import EventKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

@main
struct BellApp: App {
    @State private var store = BellStore.shared
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything can post a notification: the walk alerts' actions
        // are registered with their category, and taps need a handler from
        // the first launch onward.
        NotificationRouter.shared.register()
        #if DEBUG
        // `-BellSeedBundled YES` loads the bundled Events.xml into an empty
        // store, so a fresh simulator can show a real week for screenshots
        // and layout checks without going through an import by hand.
        if UserDefaults.standard.bool(forKey: "BellSeedBundled"),
           BellStore.shared.timetable.events.isEmpty,
           let bundled = BundledTimetable.load() {
            BellStore.shared.replaceSchedule(with: bundled, source: .manual, summary: "Debug seed")
        }
        // `-BellDemoCalendar YES` puts two events into a "Bell demo"
        // calendar today, one overlapping a class and one too far to walk
        // from, so clashes can be checked on a simulator. Never on device
        // data: it only runs in DEBUG and only creates its own calendar.
        // `-BellLocationDemo YES` turns on building monitoring without the
        // Settings toggle, so `xcrun simctl location` can drive real
        // geofence events on a simulator.
        if UserDefaults.standard.bool(forKey: "BellLocationDemo") {
            Preferences.autoAttendanceEnabled = true
        }
        if UserDefaults.standard.bool(forKey: "BellDemoCalendar") {
            Self.seedDemoCalendar()
        }
        #endif
    }

    #if DEBUG
    private static func seedDemoCalendar() {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              !store.calendars(for: .event).contains(where: { $0.title == "Bell demo" }) else { return }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Bell demo"
        calendar.source = store.sources.first { $0.sourceType == .local } ?? store.defaultCalendarForNewEvents?.source
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return }

        let today = Calendar.current.startOfDay(for: .now)
        for (title, location, start, minutes) in [("Coffee with advisor", "MSEE 180", 9 * 60 + 25, 30),
                                                  ("Interview", "Zoom", 13 * 60, 45)] {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.location = location
            event.startDate = today.addingTimeInterval(Double(start * 60))
            event.endDate = event.startDate.addingTimeInterval(Double(minutes * 60))
            try? store.save(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
        Preferences.calendarReadsEnabled = true
        Preferences.calendarWritesEnabled = true
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(session)
                // Follows the system appearance: day by default, night on
                // request. Forced dark was most of why the old look was
                // forgettable, and daylight corridors favour a light ground.
                .tint(Bell.Content.primary)
                .onOpenURL { url in
                    if let key = CalendarPlan.key(url: url, notes: nil) {
                        // A link from one of Bell's calendar events.
                        session.requestedCourse = key.split(separator: "|").first.map(String.init)
                        return
                    }
                    session.importTimetable(from: url, into: store)
                }
                .onChange(of: store.timetable) {
                    session.scheduleCalendarSync(using: store)
                    Task { await session.timetableChanged(store: store) }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    session.scheduleCalendarSync(using: store)
                    session.location.learnFromPresence(store: store)
                    store.applyWidgetActions()
                    Task {
                        await session.location.sync(store: store)
                        await ClassTracking.startForNow()
                    }
                    // New mail, at most every fifteen minutes (the account
                    // throttles itself), through the same inbox pipeline.
                    Task { await session.gmail.check(into: session.inbox, store: store) }
                    // Anything shared into Bell while it was in the background.
                    Task { await session.inbox.drain(CaptureQueue.shared, store: store) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    session.scheduleCalendarSync(using: store)
                }
                .task { await session.didLaunch(using: store) }
        }
        .modelContainer(store.container)
    }
}

/// Everything that isn't durable state: permissions, in-flight imports, the
/// error currently on screen.
///
/// Kept separate from `BellStore` on purpose. The store answers "what is
/// true"; this answers "what is happening". Mixing them is how a store ends up
/// republishing widgets because a file picker opened.
@MainActor
@Observable
final class AppSession {

    var importError: String?
    var isImporting = false

    @ObservationIgnored private var locationManager: CLLocationManager?

    let calendar = CalendarSync()
    let inbox = InboxProcessor()
    let location = LocationServices()
    let gmail = GmailAccount()
    @ObservationIgnored private var pendingSync: Task<Void, Never>?

    /// Classes the last sync found deleted from the calendar and recorded as
    /// cancelled. Shown once on the Today screen with an undo, because a
    /// class disappearing because of something done in another app should
    /// never be silent.
    var recentCancellations: [ScheduleEngine.Occurrence] = []

    /// Set when a calendar event's link opens the app; the root view pushes
    /// that course and clears it.
    var requestedCourse: String?

    // MARK: - Import

    func importTimetable(from url: URL, into store: BellStore) {
        do {
            var imported = try TimetableImporter.timetable(from: url)

            // The export carries no term dates or breaks, so anything already
            // configured is carried across rather than wiped.
            imported.exceptions = store.timetable.exceptions
            imported.termStart = store.timetable.termStart
            imported.termEnd = store.timetable.termEnd

            let summary = "\(imported.events.count) meetings, "
                + "\(Set(imported.events.map(\.course)).count) courses"

            store.replaceSchedule(with: imported, source: .manual, summary: summary)
            importError = nil
            Haptic.confirm.play()

            Task { await refreshBackgroundWork(using: store) }
        } catch {
            importError = error.localizedDescription
            Haptic.reject.play()
        }
    }

    // MARK: - Permissions

    /// The widget can't prompt for location — extensions have no UI to prompt
    /// from. The app asks once and the widget inherits the grant.
    func requestLocationAccess() {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        locationManager = manager
    }

    // MARK: - Launch

    /// Everything a cold start does, in one place.
    ///
    /// The calendar sync is here explicitly because nothing else triggers it
    /// on launch: `scenePhase` is already active when the view first appears,
    /// so its `onChange` never fires, and the timetable hasn't changed. Until
    /// this existed, other calendars only showed up after the first edit.
    func didLaunch(using store: BellStore) async {
        // First, before anything that can wait on the user: awaiting a
        // permission prompt suspends until it's answered, and the day view
        // sat without the user's other calendars behind the alert.
        syncCalendar(using: store)
        store.applyWidgetActions()
        await inbox.drain(CaptureQueue.shared, store: store)
        await location.start(store: store)

        #if DEBUG
        // `-BellDemoInbox YES` runs three sample messages through the real
        // pipeline once: one the AI Override takes, one for review, one with
        // no date. For checking the inbox on a simulator.
        if UserDefaults.standard.bool(forKey: "BellDemoInbox"), store.inbox.isEmpty {
            let soon = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
            let day = soon.formatted(.dateTime.month(.wide).day().year())
            for text in ["Reminder: ECE 302 midterm 2 is on \(day) at 7:00 PM in MSEE 180.",
                         "Want to grab coffee \(day) at 3:30 PM at the PMU?",
                         "Can you send me the slides from lab?"] {
                await inbox.process(text: text, source: .shareSheet, store: store)
            }
        }
        #endif

        // A cold permission prompt on first launch, before the app has shown
        // what it does, is the one most often declined. Onboarding asks with
        // an explanation instead; this only covers people already past it.
        // DEBUG `-BellNoPrompts YES`: screenshots without a permission
        // alert covering the middle of every one.
        let skipsPrompts = UserDefaults.standard.bool(forKey: "BellNoPrompts") && _isDebugAssertConfiguration()
        if !skipsPrompts, !OnboardingGate.shouldPresent(
            hasCompleted: Preferences.hasCompletedOnboarding,
            hasSchedule: !store.timetable.events.isEmpty) {
            await Notifier.requestAuthorization()
            requestLocationAccess()
        }
        await refreshBackgroundWork(using: store)
    }

    // MARK: - Location

    /// New rooms after an import: look them up if the user has allowed it,
    /// then watch the right buildings.
    func timetableChanged(store: BellStore) async {
        if Preferences.buildingLookupAllowed,
           !LocationServices.unknownBuildings(in: store.timetable).isEmpty {
            _ = await location.lookUpUnknownBuildings(in: store.timetable)
        }
        await location.sync(store: store)
    }

    // MARK: - Asking and telling

    /// The conversation in the ask sheet. Kept for the session only: it's a
    /// record of where the user is, and nothing needs it tomorrow.
    var conversation: [ChatTurn] = []

    struct ChatTurn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String?
        var byModel = false
    }

    func ask(_ question: String, store: BellStore) async {
        let turn = ChatTurn(question: question)
        conversation.append(turn)
        let reply = await ScheduleChat.reply(to: question, engine: store.engine,
                                             busy: calendar.external, hidden: Preferences.hiddenCourses)
        if let index = conversation.firstIndex(where: { $0.id == turn.id }) {
            conversation[index].answer = reply.text
            conversation[index].byModel = reply.byModel
        }
    }

    /// "Add a quiz for 302 on Friday at 10". Typed by the user, so it's
    /// theirs: added straight away when it has a date, never marked as
    /// automatic, and sent to the inbox to finish when it hasn't.
    enum TellResult: Equatable { case added(title: String, due: Date, inboxID: UUID), needsDetails }

    func tell(_ text: String, store: BellStore) async -> TellResult {
        guard let id = await inbox.process(text: text, source: .manual, store: store),
              let entry = store.inbox.first(where: { $0.id == id }) else { return .needsDetails }
        if entry.state == .pending, let start = entry.start {
            store.accept(inboxID: id)
            return .added(title: entry.title, due: start, inboxID: id)
        }
        if entry.state == .accepted, let start = entry.start {
            // The keyword rule fired, but the user typed this: it's theirs,
            // not Bell's. Re-accept as user-made so it isn't badged.
            store.undoAutomaticAdd(inboxID: id)
            store.accept(inboxID: id)
            return .added(title: entry.title, due: start, inboxID: id)
        }
        return .needsDetails
    }

    // MARK: - Calendar

    /// Debounced, because one import changes the timetable, which syncs,
    /// which changes the calendar, which posts a change notification. Each
    /// pass is cheap and converges, but collapsing a burst into one pass
    /// keeps a single edit from becoming four rounds of EventKit traffic.
    func scheduleCalendarSync(using store: BellStore) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.syncCalendar(using: store)
        }
    }

    func syncCalendar(using store: BellStore) {
        calendar.refreshAccess()
        let engine = store.engine
        let report = calendar.sync(engine: engine, hidden: Preferences.hiddenCourses)

        if let keys = report?.cancelledKeys, !keys.isEmpty {
            let wanted = Set(keys)
            let start = engine.calendar.startOfDay(for: .now)
            let cancelled = engine.occurrences(from: start, forwardDays: CalendarPlan.horizonDays)
                .filter { wanted.contains($0.key) }
            store.cancel(cancelled)
            recentCancellations = cancelled
            Haptic.warn.play()
        }

        calendar.loadExternal()
        calendar.publishBusyTimes()
    }

    func undoRecentCancellations(using store: BellStore) {
        for occurrence in recentCancellations {
            store.restore(cancellationKey: occurrence.key)
        }
        recentCancellations = []
        Haptic.confirm.play()
    }

    // MARK: - Background work

    func refreshBackgroundWork(using store: BellStore) async {
        let engine = ScheduleEngine(timetable: store.timetable)

        let hidden = Preferences.hiddenCourses
        await WakeAlarm.apply(WakeAlarm.nextPlan(engine: engine, hidden: hidden))
        let escalation = LocationServices.escalationRequests(engine: engine, hidden: hidden)
        await Notifier.rescheduleAll(
            using: engine,
            extra: escalation + Briefing.notificationRequests(engine: engine, busy: calendar.external, hidden: hidden),
            coveredKeys: Escalation.coveredKeys(escalation.map(\.identifier)))
        WidgetCenter.shared.reloadAllTimelines()

        // Starts early (up to three hours ahead) as well as during a class,
        // because this may be the last time the app runs before it begins.
        await ClassTracking.startForNow()
    }
}

extension UTType {
    /// Declared in Info.plist under `UTExportedTypeDeclarations`, so
    /// `.timetable` files open straight into the app from Files and AirDrop.
    static let timetableExport = UTType(exportedAs: "com.yourteam.bell.timetable")
}
