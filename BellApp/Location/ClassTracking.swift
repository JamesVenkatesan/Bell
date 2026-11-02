import AppIntents
import MapKit
import UserNotifications

/// Starting the class Live Activity, from wherever that's allowed.
///
/// ActivityKit only starts an activity from a foreground app or an App
/// Intent; push-to-start would allow more but needs APNs, which a free
/// developer account doesn't have. So there are three ways in, and between
/// them a class is covered without the app having to be open at the start:
/// the app starting it early (up to three hours ahead) whenever it's open,
/// a "Track" action on the leave-now alert, and a Shortcuts automation
/// running `TrackClassIntent` (for example "when I arrive at WALC").
enum ClassTracking {

    @discardableResult
    static func startForNow(now: Date = .now) async -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BellNoActivity") { return false }
        #endif
        let engine = ScheduleEngine(timetable: SnapshotCache.read())
        let hidden = Preferences.hiddenCourses
        guard let occurrence = ActivityPolicy.occurrenceToShow(engine: engine, hidden: hidden, now: now) else {
            await ClassActivityController.end()
            return false
        }
        let today = engine.occurrences(on: now).filter { !hidden.contains($0.event.course) }
        let next = today.first { $0.start >= occurrence.end }
        let leave = next.flatMap { engine.leaveTime(for: $0, comingFrom: occurrence) }
        do {
            try await ClassActivityController.start(for: occurrence, next: next, leaveBy: leave)
            return true
        } catch {
            return false
        }
    }
}

struct TrackClassIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Track my class"
    static let description = IntentDescription(
        "Shows your current class, or the next one in the coming three hours, on the Lock Screen and in the Dynamic Island.")

    func perform() async throws -> some IntentResult {
        await ClassTracking.startForNow()
        return .result()
    }
}

struct BellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TrackClassIntent(),
                    phrases: ["Track my class in \(.applicationName)", "Start \(.applicationName) for class"],
                    shortTitle: "Track class",
                    systemImageName: "graduationcap")
    }
}

/// Handles taps on Bell's notifications, including the actions on the walk
/// alerts: the walking route, and starting the Live Activity.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    static let routeAction = "route"
    static let trackAction = "track"

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: LocationServices.categoryID,
                actions: [
                    UNNotificationAction(identifier: Self.routeAction, title: "Walking route",
                                         options: [.foreground], icon: .init(systemImageName: "figure.walk")),
                    UNNotificationAction(identifier: Self.trackAction, title: "Track class",
                                         options: [.foreground], icon: .init(systemImageName: "graduationcap")),
                ],
                intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let room = response.notification.request.content.userInfo["room"] as? String
        switch response.actionIdentifier {
        case Self.routeAction:
            if let room { await Self.openRoute(to: room) }
            await ClassTracking.startForNow()
        case Self.trackAction, UNNotificationDefaultActionIdentifier:
            // A tap on the alert itself opens Bell, which is exactly the
            // foreground moment ActivityKit needs to start tracking.
            await ClassTracking.startForNow()
        default:
            break
        }
    }

    @MainActor
    private static func openRoute(to room: String) {
        let building = room.split(separator: " ").first.map(String.init)
        guard let coordinate = RoomCoordinates.coordinate(forRoom: room) ?? Campus.coordinate(for: building) else { return }
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                             address: nil)
        item.name = room
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
