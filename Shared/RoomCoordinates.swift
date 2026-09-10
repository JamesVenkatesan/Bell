import CoreLocation

/// Coordinates for your rooms and buildings.
///
/// ─────────────────────────────────────────────────────────────────────
///  HOW TO ADD A COORDINATE
///
///  1. Open Google Maps and find the building.
///  2. Right-click the exact door you use (or long-press on mobile).
///  3. The top of the menu shows something like  40.428954, -86.912041
///     Click it — that copies both numbers to your clipboard.
///  4. Paste into the list below, keeping the format:
///
///         "BHEE": (40.428954, -86.912041),
///
///  5. Rebuild. That's it.
///
///  Entries here override the built-in guesses, so you don't need to
///  delete anything — just add a line and it wins.
/// ─────────────────────────────────────────────────────────────────────
///
/// You can key by building code ("BHEE") or by full room ("BHEE 206").
/// Room entries take priority, which is useful when one building has
/// entrances far apart — Wetherill's north and south doors are a
/// three-minute difference on their own.
enum RoomCoordinates {

    static let overrides: [String: (latitude: Double, longitude: Double)] = [

        // ─── Your buildings ─────────────────────────────────────────────
        // Measured from Google Maps rather than estimated.

        "BHEE": (40.428865428011235, -86.911782029119),    // Electrical Engineering
        "EVER": (40.421639599125740, -86.907188478613890), // Beering / Everett
        "UC":   (40.425935933601075, -86.910104402015360), // University Church
        "WALC": (40.427387021465435, -86.913246414463250), // Wilmeth Active Learning Center
        "WTHR": (40.426716993331720, -86.913110918429550), // Wetherill Chemistry

        // ─── Room-level overrides ───────────────────────────────────────
        // Only worth adding where a room sits far from the building's main
        // door. BHEE 162 is the one to consider: you come out of WTHR 200 at
        // 08:30 and 36200L starts there the same minute, so if 162 is on a
        // different floor or wing, pin it separately and the leave-now alert
        // gets sharper.

        // "BHEE 162": (00.000000, -00.000000),
        // "BHEE 170": (00.000000, -00.000000),
        // "BHEE 206": (00.000000, -00.000000),
        // "WALC 1018": (00.000000, -00.000000),
        // "WALC 2088": (00.000000, -00.000000),
        // "WTHR 200": (00.000000, -00.000000),

        // ─── Home ─────────────────────────────────────────────────────
        // Not required, but if you add it the widget can tell you how
        // long the first walk of the day takes before you leave.

        // "HOME": (40.4250, -86.9200),
    ]

    /// Room string first, then building code. Returns nil when neither is listed.
    static func coordinate(forRoom room: String) -> CLLocationCoordinate2D? {
        let trimmed = room.trimmingCharacters(in: .whitespaces).uppercased()

        if let exact = overrides[trimmed] {
            return CLLocationCoordinate2D(latitude: exact.latitude, longitude: exact.longitude)
        }

        guard let building = trimmed.split(separator: " ").first.map(String.init),
              let match = overrides[building]
        else { return nil }

        return CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude)
    }

    static func coordinate(forBuilding building: String) -> CLLocationCoordinate2D? {
        guard let match = overrides[building.trimmingCharacters(in: .whitespaces).uppercased()]
        else { return nil }
        return CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude)
    }

    /// Rooms in the timetable with no coordinate yet. Surfaced in Settings so
    /// you can see what's still guessed.
    static func missing(from timetable: Timetable) -> [String] {
        let rooms = Set(timetable.events.map(\.room)).filter { !$0.isEmpty }
        return rooms.filter { coordinate(forRoom: $0) == nil }.sorted()
    }
}
