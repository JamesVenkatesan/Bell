import CoreLocation

/// Where you are, from inside the widget.
///
/// Widgets can't run a location manager continuously — the extension is woken
/// briefly to build a timeline and then killed. What WidgetKit does provide is
/// `isAuthorizedForWidgetUpdates`: with `NSWidgetWantsLocation` set in the
/// extension's Info.plist, the widget can ask for a fix while it's awake.
///
/// So the ETA is accurate as of the last timeline build, not live to the
/// second. Since timelines rebuild at every class boundary and whenever iOS
/// grants a refresh, in practice it's current within a few minutes — which is
/// the resolution that matters for "can I still make it".
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        manager.isAuthorizedForWidgetUpdates
    }

    /// One fix, with a ceiling so a slow GPS lock can't stall the timeline.
    /// Falls back to whatever iOS has cached, which on campus is usually fine.
    func currentLocation(timeout: TimeInterval = 4) async -> CLLocation? {
        guard isAuthorized else { return nil }

        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -300 {
            return cached
        }

        return await withCheckedContinuation { continuation in
            pending = continuation
            manager.requestLocation()

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.resume(with: self.manager.location)
            }
        }
    }

    private func resume(with location: CLLocation?) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resume(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(with: manager.location)
    }
}

// MARK: - Travel estimates

extension LocationProvider {

    /// Minutes to walk from `location` to a room, or nil when the room has no
    /// coordinate on file. Uses straight-line distance with a detour factor,
    /// because campus paths aren't straight and a raw great-circle number is
    /// optimistic enough to make you late.
    static func walkingMinutes(from location: CLLocation, toRoom room: String) -> Int? {
        guard let target = RoomCoordinates.coordinate(forRoom: room) else { return nil }

        let meters = location.distance(
            from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        // 1.3 accounts for paths, crossings, and doors that aren't where you
        // want them. Below 60 m, treat it as "you're here".
        guard meters > 60 else { return 0 }

        let seconds = (meters * 1.3) / Campus.metersPerSecond + Campus.buildingEntryOverhead
        return Int((seconds / 60).rounded())
    }
}
