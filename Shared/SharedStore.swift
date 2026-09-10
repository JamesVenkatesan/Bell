import Foundation
import SwiftUI
import WidgetKit

/// The single place the app writes and the widget reads.
///
/// Widgets run in a separate process with their own sandbox, so anything the
/// widget needs has to live in the App Group container. Timetables are small
/// enough to keep as one JSON file, which keeps reads atomic and avoids a
/// half-written schedule appearing on the home screen.
enum SharedStore {
    static let appGroup = "group.com.yourteam.bell"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var timetableURL: URL? {
        containerURL?.appendingPathComponent("timetable.json")
    }

    // MARK: - Timetable

    /// Reads the App Group copy when one exists, and falls back to the copy
    /// bundled inside the target. The fallback is what makes the widget work
    /// on a free developer account, where App Groups won't provision.
    static func load() -> Timetable {
        if
            let url = timetableURL,
            let data = try? Data(contentsOf: url),
            let table = try? JSONDecoder.bell.decode(Timetable.self, from: data),
            !table.events.isEmpty
        {
            return table
        }

        return BundledTimetable.load() ?? .empty
    }

    /// True when the App Group is actually working. The app uses this to tell
    /// you whether importing a new file will reach the widget, or whether
    /// you're on the bundled-resource path and need to rebuild instead.
    static var hasSharedContainer: Bool {
        containerURL != nil
    }

    static func save(_ timetable: Timetable) throws {
        guard let url = timetableURL else { return }
        let data = try JSONEncoder.bell.encode(timetable)
        try data.write(to: url, options: .atomic)
        cachePalette(for: timetable)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Palette cache

    private static let paletteKey = "palette.assignments"

    static func cachePalette(for timetable: Timetable) {
        let assignments = Palette.assign(courses: timetable.courses)
        let storable = assignments.mapValues(\.storableComponents)
        defaults?.set(storable, forKey: paletteKey)
    }

    static func palette() -> [String: Color] {
        if let raw = defaults?.dictionary(forKey: paletteKey) as? [String: [Double]],
           !raw.isEmpty {
            return raw.mapValues { Color(storableComponents: $0) }
        }
        // No shared container: recompute. Assignment is deterministic, so the
        // app and the widget independently arrive at the same colors.
        return Palette.assign(courses: load().courses)
    }

    static func color(for course: String) -> Color {
        palette()[course] ?? Palette.rail
    }

    // MARK: - Preferences the widget needs

    /// Minutes of head start on the "leave now" alert, on top of walking time.
    static var leaveBuffer: Int {
        get { defaults?.integer(forKey: "prefs.leaveBuffer") ?? 5 }
        set { defaults?.set(newValue, forKey: "prefs.leaveBuffer") }
    }

    static var showsRoomNumbers: Bool {
        get { defaults?.object(forKey: "prefs.showsRooms") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "prefs.showsRooms") }
    }

    /// Courses the user has hidden from widgets — useful for dropping a TA
    /// section or an optional recitation off the home screen.
    static var hiddenCourses: Set<String> {
        get { Set(defaults?.stringArray(forKey: "prefs.hidden") ?? []) }
        set { defaults?.set(Array(newValue), forKey: "prefs.hidden") }
    }
}

extension JSONEncoder {
    static var bell: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bell: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
