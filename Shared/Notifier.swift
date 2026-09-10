import UserNotifications

/// Alerts that are worth the interruption.
///
/// The rule: notify when the information changes what you'd do in the next few
/// minutes. A reminder that class starts at 7:30 every single Monday is noise.
/// A reminder that this particular walk is 11 minutes and you have 10 is not.
enum Notifier {

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .timeSensitive])
    }

    /// Rebuilt from scratch whenever the timetable changes. iOS caps pending
    /// requests at 64, so we schedule a rolling window rather than the term.
    static func rescheduleAll(using engine: ScheduleEngine) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        var requests: [UNNotificationRequest] = []
        let buffer = TimeInterval(SharedStore.leaveBuffer * 60)

        for offset in 0 ..< 7 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: .now)
            else { continue }

            let today = engine.occurrences(on: day)

            for (index, occurrence) in today.enumerated() {
                let previous = index > 0 ? today[index - 1] : nil

                // First class of the day: a plain start reminder.
                // Later classes: only if the walk is genuinely tight.
                let fireDate: Date
                let body: String

                if let previous, engine.isTightTransition(from: previous, to: occurrence) {
                    let walk = Campus.walkingSeconds(
                        from: previous.event.building, to: occurrence.event.building)
                    fireDate = previous.end.addingTimeInterval(-60)
                    body = "\(previous.event.building ?? "here") to \(occurrence.event.room) is "
                        + "\(Int((walk / 60).rounded())) min and you have "
                        + "\(Int(occurrence.start.timeIntervalSince(previous.end) / 60))."
                } else if index == 0 {
                    let walk = Campus.walkingSeconds(from: nil, to: occurrence.event.building)
                    fireDate = occurrence.start.addingTimeInterval(-(buffer + walk + 600))
                    body = "\(occurrence.event.course) in \(occurrence.event.room) at "
                        + occurrence.start.formatted(.dateTime.hour().minute())
                } else {
                    continue
                }

                guard fireDate > .now, requests.count < 60 else { continue }

                let content = UNMutableNotificationContent()
                content.title = index == 0 ? "First class today" : "Tight change"
                content.body = body
                content.interruptionLevel = .timeSensitive
                content.sound = .default

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: fireDate)

                requests.append(UNNotificationRequest(
                    identifier: "bell-\(occurrence.id)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            }
        }

        for request in requests {
            try? await center.add(request)
        }
    }
}
