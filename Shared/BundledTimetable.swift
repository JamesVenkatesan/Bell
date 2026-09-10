import Foundation

/// Lets the widget read your schedule without an App Group.
///
/// App Groups need a paid Apple Developer membership. On a free account the
/// entitlement won't provision, and the widget — which runs in its own sandbox
/// — has no way to see anything the app saved.
///
/// The way around it: ship the timetable *inside the app bundle*. Both the app
/// target and the widget target include `Events.xml` as a resource, so both
/// processes can read the same schedule with no shared container involved.
///
/// The tradeoff is that changing your schedule means replacing the file and
/// rebuilding. For a timetable that changes once a semester that's fine — and
/// on a free account the app expires after seven days anyway, so you're
/// rebuilding regularly regardless.
enum BundledTimetable {

    /// Name of the resource in both targets' Copy Bundle Resources phase.
    static let resourceName = "Events"
    static let resourceExtension = "xml"

    static func load() -> Timetable? {
        guard
            let url = Bundle.main.url(
                forResource: resourceName, withExtension: resourceExtension),
            let data = try? Data(contentsOf: url),
            var table = try? TimetableImporter.timetable(fromPropertyList: data)
        else { return nil }

        applyLocalConfiguration(to: &table)
        return table
    }

    /// Term dates and breaks aren't in the export, so they live here. Edit
    /// these once at the start of each semester.
    ///
    /// Purdue's academic calendar publishes the real dates — replace the
    /// placeholders below with them before you build.
    private static func applyLocalConfiguration(to table: inout Timetable) {
        let calendar = Calendar.current

        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
        }

        // Fall 2026, from the UniTime section table: sections run 08/24
        // through 12/11, with the online SOC section open until 12/12.
        table.termStart = date(2026, 8, 24)
        table.termEnd = date(2026, 12, 12)
        table.rotationAnchor = table.termStart ?? .now

        // These are the usual Purdue pattern but are NOT from your UniTime
        // export, so check them against the published academic calendar and
        // correct any that are wrong. A break listed here silences the widget
        // for those days, so a wrong date is a day you think you're free.
        table.exceptions = [
            ScheduleException(name: "Labor Day",
                              start: date(2026, 9, 7), end: date(2026, 9, 7)),
            ScheduleException(name: "October Break",
                              start: date(2026, 10, 12), end: date(2026, 10, 13)),
            ScheduleException(name: "Thanksgiving Break",
                              start: date(2026, 11, 25), end: date(2026, 11, 28)),
        ]
    }
}
