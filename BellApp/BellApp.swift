import CoreLocation
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

@main
struct BellApp: App {
    @StateObject private var store = TimetableStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Palette.paper)
                .preferredColorScheme(.dark)
                .onOpenURL { url in store.importTimetable(from: url) }
                .task {
                    await Notifier.requestAuthorization()
                    store.requestLocationAccess()
                    await store.refreshBackgroundWork()
                }
        }
    }
}

/// Owns the timetable in-process and mirrors every change into the App Group
/// so the widget never reads a value the app hasn't committed.
@MainActor
final class TimetableStore: ObservableObject {
    @Published private(set) var timetable: Timetable
    @Published var importError: String?
    private var locationManager: CLLocationManager?

    var engine: ScheduleEngine { ScheduleEngine(timetable: timetable) }
    var palette: [String: Color] { Palette.assign(courses: timetable.courses) }

    init() {
        timetable = SharedStore.load()
    }

    func importTimetable(from url: URL) {
        do {
            var imported = try TimetableImporter.timetable(from: url)
            // Carry across anything the export doesn't know about.
            imported.exceptions = timetable.exceptions
            imported.termStart = timetable.termStart
            imported.termEnd = timetable.termEnd
            imported.rotationAnchor = timetable.rotationAnchor == .distantPast
                ? Calendar.current.startOfDay(for: .now)
                : timetable.rotationAnchor

            try commit(imported)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    func update(_ transform: (inout Timetable) -> Void) {
        var copy = timetable
        transform(&copy)
        try? commit(copy)
    }

    private func commit(_ new: Timetable) throws {
        try SharedStore.save(new)
        timetable = new
        Task { await refreshBackgroundWork() }
    }

    /// The widget can't ask for location itself — extensions have no UI to
    /// prompt from. The app requests it once and the widget inherits the grant.
    func requestLocationAccess() {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        locationManager = manager
    }

    func refreshBackgroundWork() async {
        await Notifier.rescheduleAll(using: engine)
        WidgetCenter.shared.reloadAllTimelines()

        if #available(iOS 16.2, *) {
            let engine = self.engine
            if let current = engine.current() {
                let next = engine.next()
                let leave = next.flatMap { engine.leaveTime(for: $0, comingFrom: current) }
                try? ClassActivityController.start(for: current, next: next, leaveBy: leave)
            } else {
                ClassActivityController.end()
            }
        }
    }
}

extension UTType {
    /// Declare this in Info.plist under `CFBundleDocumentTypes` so `.timetable`
    /// files open straight into the app from Files, Mail, and AirDrop.
    static let timetableExport = UTType(exportedAs: "com.yourteam.bell.timetable")
}
