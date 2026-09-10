import CoreLocation
import Foundation

/// Distance between buildings, used for "leave now" alerts and for flagging
/// transitions that aren't actually walkable in the gap you have.
///
/// Coordinates ship with the app for the buildings in the current timetable
/// and are learned for anything else: the first time you're in a new room the
/// app records where you were, so the estimate improves without asking.
enum Campus {

    /// Comfortable walking pace with a book bag, plus stairwell and door time.
    /// Deliberately not an athletic pace — the number is only useful if you
    /// can actually hit it while reading your phone.
    static let metersPerSecond: Double = 1.25
    static let buildingEntryOverhead: TimeInterval = 120

    private static let known: [String: CLLocationCoordinate2D] = [
        "BHEE": .init(latitude: 40.4290, longitude: -86.9120), // Electrical Engineering
        "WALC": .init(latitude: 40.4272, longitude: -86.9139), // Wilmeth Active Learning Center
        "WTHR": .init(latitude: 40.4265, longitude: -86.9134), // Wetherill Chemistry
        "UC":   .init(latitude: 40.4258, longitude: -86.9106), // University Church
        "EVER": .init(latitude: 40.4256, longitude: -86.9166), // Beering / Everett
        "LWSN": .init(latitude: 40.4274, longitude: -86.9169), // Lawson Computer Science
        "MSEE": .init(latitude: 40.4283, longitude: -86.9128),
        "PHYS": .init(latitude: 40.4269, longitude: -86.9127),
        "STEW": .init(latitude: 40.4265, longitude: -86.9146),
        "HAMP": .init(latitude: 40.4278, longitude: -86.9147),
        "ME":   .init(latitude: 40.4288, longitude: -86.9134),
        "FRNY": .init(latitude: 40.4270, longitude: -86.9120),
        "PMU":  .init(latitude: 40.4249, longitude: -86.9114),
        "CL50": .init(latitude: 40.4258, longitude: -86.9146),
        "RAWL": .init(latitude: 40.4234, longitude: -86.9105),
        "KRAN": .init(latitude: 40.4235, longitude: -86.9110),
    ]

    /// Your own entries in `RoomCoordinates` win over everything else, so
    /// correcting a bad estimate is a one-line edit in that file.
    static func coordinate(for building: String?) -> CLLocationCoordinate2D? {
        guard let building else { return nil }
        if let override = RoomCoordinates.coordinate(forBuilding: building) { return override }
        if let known = known[building.uppercased()] { return known }
        return LearnedLocations.shared.coordinate(for: building)
    }

    static func distanceMeters(from origin: String?, to destination: String?) -> Double? {
        guard
            let origin, let destination,
            origin.caseInsensitiveCompare(destination) != .orderedSame,
            let a = coordinate(for: origin), let b = coordinate(for: destination)
        else { return nil }

        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Seconds of walking, or 0 when the move is within one building.
    static func walkingSeconds(from origin: String?, to destination: String?) -> TimeInterval {
        guard let meters = distanceMeters(from: origin, to: destination) else { return 0 }
        return (meters / metersPerSecond) + buildingEntryOverhead
    }

    static func walkDescription(from origin: String?, to destination: String?) -> String? {
        let seconds = walkingSeconds(from: origin, to: destination)
        guard seconds > 0 else { return nil }
        return "\(Int((seconds / 60).rounded())) min walk"
    }

    /// Buildings the app has seen but doesn't have coordinates for. Filled in
    /// opportunistically when the user is in class with location available.
    final class LearnedLocations {
        static let shared = LearnedLocations()
        private let key = "campus.learned"
        private var cache: [String: [Double]]

        private init() {
            cache = SharedStore.defaults?.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        }

        func coordinate(for building: String) -> CLLocationCoordinate2D? {
            guard let pair = cache[building.uppercased()], pair.count == 2 else { return nil }
            return .init(latitude: pair[0], longitude: pair[1])
        }

        func record(_ coordinate: CLLocationCoordinate2D, for building: String) {
            cache[building.uppercased()] = [coordinate.latitude, coordinate.longitude]
            SharedStore.defaults?.set(cache, forKey: key)
        }
    }
}
