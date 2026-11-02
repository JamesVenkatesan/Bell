import Foundation
import UserNotifications

/// Builds the brief for a given moment, and the notifications that carry it.
@MainActor
enum Briefing {

    /// Which day the brief is about: today until the last class is over (or
    /// 6pm on a day without classes), then tomorrow, because in the evening
    /// the useful question is what the morning looks like.
    static func subjectDay(engine: ScheduleEngine, hidden: Set<String>, now: Date) -> Date {
        let calendar = engine.calendar
        let today = engine.occurrences(on: now).filter { !hidden.contains($0.event.course) }
        let switchover = today.last?.end
            ?? calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        if now < switchover { return calendar.startOfDay(for: now) }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    static func facts(engine: ScheduleEngine, busy: [ExternalEvent], hidden: Set<String>, now: Date) -> BriefFacts {
        let day = subjectDay(engine: engine, hidden: hidden, now: now)
        let wake = WakeAlarm.nextPlan(engine: engine, hidden: hidden, now: now)
            .flatMap { engine.calendar.isDate($0.firstClass.start, inSameDayAs: day) ? $0 : nil }
        return BriefFacts.build(day: day, engine: engine, busy: busy, hidden: hidden, wake: wake, now: now)
    }

    /// A brief each class morning for the next week, at the wake time (or
    /// 7:00 without one), plus the review on Sunday evening. Built from the
    /// template: notifications are scheduled ahead, and the model can't be
    /// asked to write next Thursday's prose today without seeing Thursday.
    static func notificationRequests(engine: ScheduleEngine, busy: [ExternalEvent],
                                     hidden: Set<String>, now: Date = .now) -> [UNNotificationRequest] {
        guard Preferences.briefNotificationsEnabled else { return [] }
        let calendar = engine.calendar
        var requests: [UNNotificationRequest] = []

        for offset in 0 ..< 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  !engine.occurrences(on: day).filter({ !hidden.contains($0.event.course) }).isEmpty
            else { continue }

            let wake = WakePlan.make(day: day, engine: engine, hidden: hidden, walkMinutes: nil,
                                     walkSource: .estimate,
                                     routineMinutes: Preferences.morningRoutineMinutes,
                                     bufferMinutes: Preferences.leaveBuffer)
            let fire = wake?.wakeAt ?? calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? day
            guard fire > now else { continue }

            let facts = BriefFacts.build(day: day, engine: engine, busy: busy, hidden: hidden,
                                         wake: nil, now: fire)
            let content = UNMutableNotificationContent()
            content.title = "Your day"
            content.body = BriefWriter.template(facts, now: fire)
            requests.append(request("brief-\(Int(day.timeIntervalSince1970))", content, at: fire, calendar: calendar))
        }

        if let sunday = nextSundayEvening(after: now, calendar: calendar) {
            let monday = WeeklyReview.monday(of: sunday, engine: engine)
            let review = WeeklyReview.build(weekStart: monday, engine: engine, attendance: [], hidden: hidden)
            let content = UNMutableNotificationContent()
            content.title = "Your week"
            content.body = review.summary
            requests.append(request("review-\(Int(sunday.timeIntervalSince1970))", content, at: sunday, calendar: calendar))
        }
        return requests
    }

    private static func nextSundayEvening(after now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = 1
        components.hour = 18
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    private static func request(_ id: String, _ content: UNMutableNotificationContent,
                                at date: Date, calendar: Calendar) -> UNNotificationRequest {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}
