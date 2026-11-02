import Foundation
import SwiftUI
import WidgetKit

/// Compatibility surface over the new persistence layer.
///
/// Reads go to `SnapshotCache` (the flat file the widget uses) and small
/// preferences stay in App Group defaults, where the widget can reach them
/// without parsing anything. Writes belong to `BellStore`; this type no longer
/// owns state.
///
/// Kept because the widget and the current views call it in a dozen places.
/// Phase 2 retires it as those screens are rebuilt.
enum SharedStore {

    static var appGroup: String { AppGroup.identifier }
    static var defaults: UserDefaults? { AppGroup.defaults }
    static var hasSharedContainer: Bool { AppGroup.isAvailable }

    // MARK: - Reading

    static func load() -> Timetable { SnapshotCache.read() }

    static func palette() -> [String: Color] { SnapshotCache.palette() }

    static func color(for course: String) -> Color {
        palette()[course] ?? Bell.Surface.scaffold
    }

    // MARK: - Preferences
    //
    // These live in defaults rather than the database because the widget reads
    // them on every timeline entry, and a defaults lookup is free where
    // opening a store is not.

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
