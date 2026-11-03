import Foundation

/// When Notion data counts as stale, decided in one place for the app and
/// the widget.
///
/// There is no way to make iOS run Bell at a chosen time. A background
/// refresh is a request the system grants when it judges the phone's
/// battery, network and the user's habits allow, often but never certainly.
/// So the honest design is several chances to sync plus saying, wherever
/// Notion data appears, how old it is.
enum NotionFreshness {
    /// Opening the app syncs if the last sync is older than this.
    static let foregroundMaxAge: TimeInterval = 60 * 60
    /// A widget finding data older than this asks the app to sync next time
    /// it runs, and says how old the data is.
    static let widgetMaxAge: TimeInterval = 4 * 3600
    /// The hour the morning refresh is asked for: before a first class, with
    /// time to spare for iOS running it late.
    static let morningHour = 5

    static func isStale(_ syncedAt: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let syncedAt else { return true }
        return now.timeIntervalSince(syncedAt) > maxAge
    }

    /// The next early morning after `now`, for the background refresh
    /// request. Tomorrow's if this morning's has passed.
    static func nextMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
