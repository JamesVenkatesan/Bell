import Foundation

/// Small settings both processes read.
///
/// These live in App Group defaults rather than the database because the
/// widget reads them on every timeline entry, and a defaults lookup is free
/// where opening a store is not. Writes still come from the app only.
///
/// Replaces the old `SharedStore` shim. The keys are unchanged, so values set
/// before the rename carry straight across.
enum Preferences {

    private static var defaults: UserDefaults? { AppGroup.defaults }

    /// Minutes of head start on the leave-now alert, on top of walking time.
    static var leaveBuffer: Int {
        get { defaults?.object(forKey: "prefs.leaveBuffer") as? Int ?? 5 }
        set { defaults?.set(newValue, forKey: "prefs.leaveBuffer") }
    }

    static var showsRoomNumbers: Bool {
        get { defaults?.object(forKey: "prefs.showsRooms") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "prefs.showsRooms") }
    }

    /// Mirrored from `StoredCourse.isHidden` by `BellStore.setHidden`.
    static var hiddenCourses: Set<String> {
        get { Set(defaults?.stringArray(forKey: "prefs.hidden") ?? []) }
        set { defaults?.set(Array(newValue), forKey: "prefs.hidden") }
    }

    /// Set at the end of onboarding. Defaults to false so a fresh install
    /// sees the introduction.
    static var hasCompletedOnboarding: Bool {
        get { defaults?.bool(forKey: "prefs.onboarded") ?? false }
        set { defaults?.set(newValue, forKey: "prefs.onboarded") }
    }

    // MARK: Mornings

    /// Minutes between waking and leaving: shower, breakfast, the lot.
    static var morningRoutineMinutes: Int {
        get { defaults?.object(forKey: "wake.routine") as? Int ?? 45 }
        set { defaults?.set(newValue, forKey: "wake.routine") }
    }

    /// Schedule a real alarm for the first class. Off until asked for: an
    /// app setting alarms on its own would be a rude surprise.
    static var wakeAlarmEnabled: Bool {
        get { defaults?.bool(forKey: "wake.enabled") ?? false }
        set { defaults?.set(newValue, forKey: "wake.enabled") }
    }

    static var wakeAlarmID: UUID? {
        get { defaults?.string(forKey: "wake.id").flatMap(UUID.init(uuidString:)) }
        set { defaults?.set(newValue?.uuidString, forKey: "wake.id") }
    }

    /// The morning brief and the Sunday review as notifications.
    static var briefNotificationsEnabled: Bool {
        get { defaults?.object(forKey: "brief.notify") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "brief.notify") }
    }

    // MARK: Location

    /// Watch class buildings and mark attendance on arrival. Needs "always"
    /// location, so it's asked for only when switched on.
    static var autoAttendanceEnabled: Bool {
        get { defaults?.bool(forKey: "location.attendance") ?? false }
        set { defaults?.set(newValue, forKey: "location.attendance") }
    }

    /// Heads-up, leave-now and running-late alerts that stop on arrival.
    static var escalationEnabled: Bool {
        get { defaults?.bool(forKey: "location.escalation") ?? false }
        set { defaults?.set(newValue, forKey: "location.escalation") }
    }

    /// The user agreed to Apple Maps lookups for unknown buildings.
    static var buildingLookupAllowed: Bool {
        get { defaults?.bool(forKey: "location.lookup") ?? false }
        set { defaults?.set(newValue, forKey: "location.lookup") }
    }

    // MARK: Calendar

    /// Write classes into a system calendar. Off until the user turns it on:
    /// putting events into someone's calendar is not a default.
    static var calendarWritesEnabled: Bool {
        get { defaults?.bool(forKey: "calendar.writes") ?? false }
        set { defaults?.set(newValue, forKey: "calendar.writes") }
    }

    /// Read the user's other calendars for the day view and clashes.
    static var calendarReadsEnabled: Bool {
        get { defaults?.bool(forKey: "calendar.reads") ?? false }
        set { defaults?.set(newValue, forKey: "calendar.reads") }
    }

    /// The calendar Bell writes to.
    static var calendarIdentifier: String? {
        get { defaults?.string(forKey: "calendar.target") }
        set { defaults?.set(newValue, forKey: "calendar.target") }
    }

    /// Keys of the events Bell last saw in its calendar. How a deletion by
    /// the user is told apart from an event that was never written.
    static var calendarLedger: [String] {
        get { defaults?.stringArray(forKey: "calendar.ledger") ?? [] }
        set { defaults?.set(newValue, forKey: "calendar.ledger") }
    }

    /// Calendars the user said don't count as busy (a shared family
    /// calendar, holidays, a colleague's).
    static var excludedCalendarIDs: Set<String> {
        get { Set(defaults?.stringArray(forKey: "calendar.excluded") ?? []) }
        set { defaults?.set(Array(newValue), forKey: "calendar.excluded") }
    }

    // MARK: Notion

    /// Whether a Notion database is connected. Mirrored here (the token
    /// itself is in the Keychain, which the widget can't and shouldn't read)
    /// so the widget knows whether "nothing due" means nothing due or
    /// nothing synced.
    static var notionConnected: Bool {
        get { defaults?.bool(forKey: "notion.connected") ?? false }
        set { defaults?.set(newValue, forKey: "notion.connected") }
    }

    /// The last complete, successful sync. Shown wherever Notion data is,
    /// so nothing implies it's live.
    static var notionSyncedAt: Date? {
        get { defaults?.object(forKey: "notion.syncedAt") as? Date }
        set { defaults?.set(newValue, forKey: "notion.syncedAt") }
    }

    /// Set by the widget when it builds a timeline from Notion data older
    /// than `NotionFreshness.widgetMaxAge`. The one write the widget makes
    /// here: it can't fetch (no network in a timeline build) or wake the
    /// app, so it leaves a note the app acts on the next time it runs.
    static var notionRefreshRequested: Date? {
        get { defaults?.object(forKey: "notion.refreshRequested") as? Date }
        set { defaults?.set(newValue, forKey: "notion.refreshRequested") }
    }

    /// Raw store for things that aren't preferences but need the same reach,
    /// such as learned building positions.
    static var store: UserDefaults? { defaults }
}
