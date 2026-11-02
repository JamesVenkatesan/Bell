import ActivityKit
import SwiftUI
import WidgetKit

/// A Live Activity that runs for the length of a class.
///
/// This is the piece that makes the schedule ambient: the Dynamic Island shows
/// how long is left and where you're going next, so checking takes a glance at
/// the top of the screen rather than a trip to the home screen.
struct ClassActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var courseCode: String
        var room: String
        var endsAt: Date
        var nextCourse: String?
        var nextRoom: String?
        var leaveBy: Date?
        var walkMinutes: Int?
    }

    var startedAt: Date
    var colorComponents: [Double]
}

extension ClassActivityAttributes {
    /// The class itself, start to end. Was `Date.now ... endsAt`, which made
    /// the progress bar run from whenever the activity was rendered: started
    /// mid-lecture, it showed the class as just beginning. With the real
    /// start, an activity begun hours early is also right with no updates:
    /// the timer holds at the full length until the class starts, then runs.
    func classRange(_ state: ContentState) -> ClosedRange<Date> {
        min(startedAt, state.endsAt) ... state.endsAt
    }
}

// MARK: - Lifecycle

@available(iOS 16.2, *)
enum ClassActivityController {

    static func start(for occurrence: ScheduleEngine.Occurrence,
                      next: ScheduleEngine.Occurrence?,
                      leaveBy: Date?) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Same class already showing: leave it. Ending and restarting would
        // make the lock screen flicker on every app launch.
        if Activity<ClassActivityAttributes>.activities.contains(where: {
            $0.attributes.startedAt == occurrence.start && $0.content.state.courseCode == occurrence.event.course
        }) { return }

        // Must finish before requesting the next one. Firing this off in a
        // detached task meant the old activity was often still alive when the
        // new request landed, leaving two on the Lock Screen.
        await end()

        let color = Bell.color(forCourse: occurrence.event.course)
        let attributes = ClassActivityAttributes(
            startedAt: occurrence.start,
            colorComponents: color.storableComponents)

        let walk = Campus.walkingSeconds(
            from: occurrence.event.building, to: next?.event.building)

        let state = ClassActivityAttributes.ContentState(
            courseCode: occurrence.event.course,
            room: occurrence.event.room,
            endsAt: occurrence.end,
            nextCourse: next?.event.course,
            nextRoom: next?.event.room,
            leaveBy: leaveBy,
            walkMinutes: walk > 0 ? Int((walk / 60).rounded()) : nil)

        _ = try Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: occurrence.end),
            pushType: nil)
    }

    static func end() async {
        for activity in Activity<ClassActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - Presentation

@available(iOS 16.2, *)
struct ClassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassActivityAttributes.self) { context in
            lockScreen(context)
                // Black, like the night ground: the course colour on black is
                // the brightest, clearest thing a lock screen can show.
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.courseCode)
                            .font(.system(size: 15, weight: .semibold))
                        Text(context.state.room)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(timerInterval: context.attributes.classRange(context.state), countsDown: true)
                            .font(.system(size: 15, weight: .medium))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 66)
                        Text("left").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let nextCourse = context.state.nextCourse {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 10))
                            Text(nextCourse).fontWeight(.medium)
                            if let room = context.state.nextRoom {
                                Text(room).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let minutes = context.state.walkMinutes {
                                Label("\(minutes) min", systemImage: "figure.walk")
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            } compactLeading: {
                Image(systemName: "graduationcap.fill")
            } compactTrailing: {
                Text(timerInterval: context.attributes.classRange(context.state), countsDown: true)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "graduationcap.fill")
            }
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<ClassActivityAttributes>
    ) -> some View {
        let color = Color(storableComponents: context.attributes.colorComponents)
        let range = context.attributes.classRange(context.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                // The bell number, in the course's colour: the same focal
                // point as the app's hero, at lock-screen size.
                Text(timerInterval: range, countsDown: true)
                    .font(.system(size: 56, weight: .black).width(.compressed).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(maxWidth: 190, alignment: .leading)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.state.courseCode)
                        .font(.system(.headline, weight: .semibold).width(.expanded))
                    Text("\(context.state.room) · \(context.attributes.startedAt, format: .dateTime.hour().minute())–\(context.state.endsAt, format: .dateTime.hour().minute())")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .foregroundStyle(.white)

            ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(color)

            if let nextCourse = context.state.nextCourse {
                HStack(spacing: 5) {
                    Text("Then").foregroundStyle(.white.opacity(0.65))
                    Text(nextCourse).fontWeight(.semibold)
                    if let room = context.state.nextRoom { Text(room).foregroundStyle(.white.opacity(0.65)) }
                    Spacer()
                    if let leaveBy = context.state.leaveBy {
                        Text("leave \(leaveBy, format: .dateTime.hour().minute())")
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.17))
                    }
                }
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.white)
            }
        }
        .padding(16)
    }
}
