import AlarmKit
import CoreLocation
import SwiftUI

/// The wake-up alarm, through AlarmKit.
///
/// A real alarm, not a notification: it sounds through silent mode and Focus,
/// which is the whole point of something meant to get you out of bed. One
/// alarm at a time, for the next day with a class, replaced whenever the
/// timetable, the routine length or the starting point changes.
///
/// "Adaptive" has a limit worth stating: the time is computed when Bell runs
/// (opening it, or a background refresh iOS chooses to grant), and an alarm,
/// once scheduled, can't recompute itself at 5am. In practice Bell runs the
/// evening before, which is when the walk from home is known anyway.
@MainActor
enum WakeAlarm {

    struct Metadata: AlarmMetadata {
        var course: String
    }

    static var isAuthorized: Bool {
        AlarmManager.shared.authorizationState == .authorized
    }

    static func requestAuthorization() async -> Bool {
        (try? await AlarmManager.shared.requestAuthorization()) == .authorized
    }

    /// The plan for the next day that has a class, from tomorrow onward (or
    /// today, if its alarm time hasn't passed).
    static func nextPlan(engine: ScheduleEngine, hidden: Set<String>, now: Date = .now) -> WakePlan? {
        let (walk, source) = walkFromStart(engine: engine, hidden: hidden, now: now)
        for offset in 0 ..< 14 {
            guard let day = engine.calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let firstRoom = engine.occurrences(on: day).first { !hidden.contains($0.event.course) }?.event.room
            let minutes = firstRoom.flatMap { walk?($0) }
            if let plan = WakePlan.make(day: day, engine: engine, hidden: hidden,
                                        walkMinutes: minutes, walkSource: source,
                                        routineMinutes: Preferences.morningRoutineMinutes,
                                        bufferMinutes: Preferences.leaveBuffer),
               plan.wakeAt > now {
                return plan
            }
        }
        return nil
    }

    /// Home first (you wake up there), then wherever the phone last was.
    private static func walkFromStart(engine: ScheduleEngine, hidden: Set<String>, now: Date)
        -> (((String) -> Int?)?, WakePlan.WalkSource) {
        if let home = Campus.coordinate(for: "HOME") {
            let origin = CLLocation(latitude: home.latitude, longitude: home.longitude)
            return ({ LocationProvider.walkingMinutes(from: origin, toRoom: $0) }, .home)
        }
        if let last = CLLocationManager().location, last.timestamp.timeIntervalSince(now) > -12 * 3600 {
            return ({ LocationProvider.walkingMinutes(from: last, toRoom: $0) }, .lastLocation)
        }
        return (nil, .estimate)
    }

    /// Replaces the scheduled alarm with one for `plan`, or clears it.
    static func apply(_ plan: WakePlan?) async {
        if let id = Preferences.wakeAlarmID {
            try? AlarmManager.shared.cancel(id: id)
            Preferences.wakeAlarmID = nil
        }
        guard Preferences.wakeAlarmEnabled, isAuthorized, let plan else { return }

        let alert = AlarmPresentation.Alert(
            title: "\(plan.firstClass.event.course) at \(BriefWriter.clock(plan.firstClass.start))",
            stopButton: AlarmButton(text: "Up", textColor: Bell.Content.primary, systemImageName: "sun.max"))
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                         metadata: Metadata(course: plan.firstClass.event.course),
                                         tintColor: Bell.Signal.inferred)
        let id = UUID()
        do {
            _ = try await AlarmManager.shared.schedule(
                id: id,
                configuration: .alarm(schedule: .fixed(plan.wakeAt), attributes: attributes))
            Preferences.wakeAlarmID = id
        } catch {
            Preferences.wakeAlarmID = nil
        }
    }
}
