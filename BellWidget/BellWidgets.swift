import SwiftUI
import WidgetKit

// The nine widgets. What each shows lives in Shared/Widgets, so the app's
// gallery renders the same views; this file only registers them and builds
// their timeline.

struct BellEntry: TimelineEntry {
    var date: Date
    var model: WidgetModel
}

struct BellProvider: TimelineProvider {

    func placeholder(in context: Context) -> BellEntry { entry(at: .now) }

    func getSnapshot(in context: Context, completion: @escaping (BellEntry) -> Void) {
        completion(entry(at: .now))
    }

    /// One entry now, then one at every moment the contents change: class
    /// boundaries, leave-by times, deadlines, midnight. Countdowns between
    /// those tick by themselves through timer text, so nothing polls.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BellEntry>) -> Void) {
        let now = Date.now
        // The widget can't fetch or wake the app. When it finds Notion data
        // older than a few hours it leaves a note, and the app syncs the
        // next time it runs (and asks iOS for a sooner background refresh).
        if Preferences.notionConnected, Preferences.notionRefreshRequested == nil,
           NotionFreshness.isStale(Preferences.notionSyncedAt, now: now, maxAge: NotionFreshness.widgetMaxAge) {
            Preferences.notionRefreshRequested = now
        }
        let timetable = SnapshotCache.read()
        let dates = [now] + WidgetModel.refreshDates(timetable: timetable, hidden: Preferences.hiddenCourses,
                                                     leaveBuffer: Preferences.leaveBuffer, from: now)
        completion(Timeline(entries: dates.map(entry(at:)), policy: .atEnd))
    }

    private func entry(at date: Date) -> BellEntry {
        BellEntry(date: date, model: WidgetModel.build(
            timetable: SnapshotCache.read(),
            palette: SnapshotCache.palette(),
            busy: SnapshotCache.busy(),
            hidden: Preferences.hiddenCourses,
            leaveBuffer: Preferences.leaveBuffer,
            completedTasks: WidgetActions.completedTasks,
            markedAttendance: WidgetActions.markedAttendance,
            notionSyncedAt: Preferences.notionConnected ? Preferences.notionSyncedAt : nil,
            now: date))
    }
}

/// One configuration per kind; the kind decides family, view and ground.
/// A function rather than a parameterised widget, because `Widget` must be
/// creatable with no arguments.
func configuration(_ kind: WidgetKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.kindID, provider: BellProvider()) { entry in
        WidgetBody(kind: kind, model: entry.model)
            .containerBackground(for: .widget) { WidgetGround(kind: kind, model: entry.model) }
    }
    .configurationDisplayName(kind.name)
    .description(kind.question)
    .supportedFamilies([kind.family])
}

struct BellWidgetSmall: Widget { var body: some WidgetConfiguration { configuration(.bell) } }
struct BehindWidgetSmall: Widget { var body: some WidgetConfiguration { configuration(.behind) } }
struct FreeWidgetMedium: Widget { var body: some WidgetConfiguration { configuration(.free) } }
struct DueWidgetMedium: Widget { var body: some WidgetConfiguration { configuration(.due) } }
struct TodayWidgetLarge: Widget { var body: some WidgetConfiguration { configuration(.today) } }
struct WeekWidgetLarge: Widget { var body: some WidgetConfiguration { configuration(.week) } }
struct LeaveWidgetLock: Widget { var body: some WidgetConfiguration { configuration(.leave) } }
struct TermWidgetLock: Widget { var body: some WidgetConfiguration { configuration(.term) } }
struct BellMaxWidgetLarge: Widget { var body: some WidgetConfiguration { configuration(.max) } }

@main
struct BellWidgetBundle: WidgetBundle {
    var body: some Widget {
        BellWidgetSmall()
        BehindWidgetSmall()
        FreeWidgetMedium()
        DueWidgetMedium()
        TodayWidgetLarge()
        WeekWidgetLarge()
        LeaveWidgetLock()
        TermWidgetLock()
        BellMaxWidgetLarge()
        ClassLiveActivity()
    }
}
