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

extension ClassActivityAttributes.ContentState {
    var timeRange: ClosedRange<Date> { Date.now ... endsAt }
}

// MARK: - Lifecycle

@available(iOS 16.2, *)
enum ClassActivityController {

    static func start(for occurrence: ScheduleEngine.Occurrence,
                      next: ScheduleEngine.Occurrence?,
                      leaveBy: Date?) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end() // never stack two

        let color = SharedStore.color(for: occurrence.event.course)
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

    static func end() {
        Task {
            for activity in Activity<ClassActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - Presentation

@available(iOS 16.2, *)
struct ClassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Palette.ink)
                .activitySystemActionForegroundColor(Palette.paper)
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
                        Text(timerInterval: context.state.timeRange, countsDown: true)
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
                Text(timerInterval: context.state.timeRange, countsDown: true)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.state.courseCode)
                        .font(.system(size: 19, weight: .semibold))
                    Text(context.state.room)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: context.state.timeRange, countsDown: true)
                    .font(.system(size: 19, weight: .medium))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 84)
            }

            ProgressView(timerInterval: context.state.timeRange, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Color(storableComponents: context.attributes.colorComponents))

            if let nextCourse = context.state.nextCourse {
                HStack(spacing: 5) {
                    Text("Next").foregroundStyle(.secondary)
                    Text(nextCourse).fontWeight(.medium)
                    if let room = context.state.nextRoom { Text(room) }
                    Spacer()
                    if let leaveBy = context.state.leaveBy {
                        Text("leave ") + Text(leaveBy, style: .relative)
                    }
                }
                .font(.system(size: 12))
                .monospacedDigit()
            }
        }
        .padding(14)
    }
}
