import SwiftUI

// MARK: - Brief card

/// The day in a few sentences, at the top of Today.
///
/// Shows the template at once and swaps in the model's phrasing when (and
/// only if) it arrives and passes the grounding check, with a cross-fade
/// rather than a jump. Waiting on the model before showing anything would
/// make the first thing on screen a spinner.
struct BriefCard: View {
    var facts: BriefFacts
    var now: Date
    var onReview: (() -> Void)?

    @State private var text: String?
    @State private var byModel = false

    var body: some View {
        let plain = BriefWriter.template(facts, now: now)
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading)
                    .font(Bell.Type_.headline)
                    .foregroundStyle(Bell.Content.primary)
                Spacer()
                if byModel {
                    Label("Written on device", systemImage: "sparkles")
                        .font(Bell.Type_.micro)
                        .foregroundStyle(Bell.Signal.inferred)
                        .transition(.opacity)
                }
            }

            Text(text ?? plain)
                .font(.system(.title3, weight: .regular))
                .foregroundStyle(Bell.Content.primary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .lineSpacing(2)

            if facts.wake != nil || onReview != nil {
                HStack(spacing: Bell.Space.snug) {
                    if let wake = facts.wake {
                        Label("\(Preferences.wakeAlarmEnabled ? "Alarm" : "Wake") \(wake.wakeAt.formatted(.dateTime.hour().minute()))",
                              systemImage: Preferences.wakeAlarmEnabled ? "alarm.fill" : "alarm")
                            .font(Bell.Type_.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Bell.Content.secondary)
                    }
                    Spacer()
                    if let onReview {
                        Button("Your week", action: onReview)
                            .font(Bell.Type_.caption.weight(.medium))
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        // Prose on the ground, not in a card: it's the one paragraph on the
        // screen, and a box around it would make it read as a widget.
        .animation(Bell.Motion.standard, value: text)
        .task(id: plain) {
            let result = await BriefWriter.write(facts, now: now)
            guard result.byModel else { return }
            text = result.text
            byModel = true
        }
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        let calendar = Calendar.current
        if calendar.isDate(facts.day, inSameDayAs: now) {
            return calendar.component(.hour, from: now) < 12 ? "This morning" : "Today"
        }
        return "Tomorrow"
    }
}

// MARK: - Ask bar

/// One field for questions and instructions, floating over the bottom of
/// Today on glass, because the timeline scrolls beneath it.
struct AskBar: View {
    var onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Bell.Space.snug) {
            Image(systemName: "sparkles")
                .foregroundStyle(Bell.Signal.inferred)
            TextField("Ask, or add something", text: $text)
                .font(Bell.Type_.body)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            if !text.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Bell.Content.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, Bell.Space.roomy)
        .padding(.trailing, Bell.Space.snug)
        .padding(.vertical, Bell.Space.snug + Bell.Space.hair)
        .glassEffect(Bell.Material_.floatingControl, in: .capsule)
        .padding(.horizontal, Bell.Space.gutter)
        .padding(.bottom, Bell.Space.snug)
        .animation(Bell.Motion.snap, value: text.isEmpty)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
        focused = false
    }
}

// MARK: - Conversation

struct AskSheet: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Bell.Space.loose) {
                        ForEach(session.conversation) { turn in
                            VStack(alignment: .leading, spacing: Bell.Space.snug) {
                                Text(turn.question)
                                    .font(Bell.Type_.body.weight(.medium))
                                    .foregroundStyle(Bell.Content.primary)
                                    .padding(.horizontal, Bell.Space.roomy)
                                    .padding(.vertical, Bell.Space.snug + Bell.Space.hair)
                                    .background(Capsule().fill(Bell.Surface.raised))
                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                if let answer = turn.answer {
                                    VStack(alignment: .leading, spacing: Bell.Space.tight) {
                                        Text(answer)
                                            .font(Bell.Type_.body)
                                            .foregroundStyle(Bell.Content.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if turn.byModel {
                                            Label("Apple Intelligence, checked against your schedule",
                                                  systemImage: "sparkles")
                                                .font(Bell.Type_.micro)
                                                .foregroundStyle(Bell.Signal.inferred)
                                        }
                                    }
                                    .transition(.bellCard)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .padding(Bell.Space.gutter)
                    .animation(Bell.Motion.arrive, value: session.conversation)
                }
                .onChange(of: session.conversation.count) {
                    if let last = session.conversation.last {
                        withAnimation(Bell.Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Bell.Surface.canvas)
            .safeAreaInset(edge: .bottom) {
                AskBar { question in
                    Task { await session.ask(question, store: store) }
                }
            }
            .navigationTitle("Ask Bell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Toast

/// A short confirmation for something added from the ask bar, with undo.
/// Floats above the bar and leaves on its own; anything that needs a
/// decision goes to the inbox instead of living in a toast.
struct Toast: View {
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Bell.Space.base) {
            Text(text)
                .font(Bell.Type_.caption.weight(.medium))
                .foregroundStyle(Bell.Content.primary)
                .lineLimit(2)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Bell.Type_.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Bell.Signal.inferred)
            }
        }
        .padding(.horizontal, Bell.Space.roomy)
        .padding(.vertical, Bell.Space.base)
        .glassEffect(Bell.Material_.floating, in: .capsule)
        .padding(.bottom, Bell.Space.snug)
    }
}

// MARK: - Weekly review

struct WeeklyReviewScreen: View {
    @Environment(BellStore.self) private var store

    var body: some View {
        let engine = store.engine
        // Reviewing on Sunday or Monday morning both mean "the week that just
        // ended": before Wednesday, the previous Monday's week.
        let now = Date.now
        let thisMonday = WeeklyReview.monday(of: now, engine: engine)
        let reviewed = engine.mondayBasedIndex(for: now) < 2
            ? (engine.calendar.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday)
            : thisMonday
        let review = WeeklyReview.build(weekStart: reviewed, engine: engine,
                                        attendance: store.allAttendance(), hidden: Preferences.hiddenCourses)

        ScrollView {
            VStack(alignment: .leading, spacing: Bell.Space.section) {
                Text(review.summary)
                    .font(Bell.Type_.headline.weight(.regular))
                    .foregroundStyle(Bell.Content.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)

                HStack(spacing: Bell.Space.snug) {
                    tile("\(review.classesHeld)", "classes")
                    tile(String(format: review.minutesInClass % 60 == 0 ? "%.0f" : "%.1f",
                                Double(review.minutesInClass) / 60), "hours")
                    if review.attended + review.missed > 0 {
                        tile("\(review.attended)/\(review.attended + review.missed)", "attended")
                    } else {
                        tile("\(review.unrecorded)", "unmarked")
                    }
                }

                if !review.tasksSlipped.isEmpty {
                    list("Still open", review.tasksSlipped)
                }
                if !review.dueNextWeek.isEmpty {
                    list("Due next week", review.dueNextWeek)
                }
                if !review.tasksDone.isEmpty {
                    list("Done", review.tasksDone)
                }
            }
            .padding(.horizontal, Bell.Space.gutter)
            .padding(.bottom, Bell.Space.section)
        }
        .background(Bell.Surface.canvas)
        .navigationTitle("Week of \(reviewed.formatted(.dateTime.month(.abbreviated).day()))")
        .navigationBarTitleDisplayMode(.large)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Bell.Space.hair) {
            Text(value)
                .font(Bell.Type_.data(28, weight: .semibold))
                .foregroundStyle(Bell.Content.primary)
            Text(label)
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Bell.Space.roomy)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .fill(Bell.Surface.raised))
    }

    private func list(_ title: String, _ tasks: [TaskEvent]) -> some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            Text(title)
                .font(Bell.Type_.micro)
                .foregroundStyle(Bell.Content.secondary)
            ForEach(tasks) { task in
                HStack {
                    Image(systemName: task.kind.symbol).foregroundStyle(Bell.Content.tertiary)
                    Text(task.title).foregroundStyle(Bell.Content.primary)
                    Spacer()
                    Text(task.due, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .foregroundStyle(Bell.Content.secondary)
                }
                .font(Bell.Type_.body)
            }
        }
    }
}

// MARK: - Settings

struct MorningsSettingsView: View {
    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var alarm = Preferences.wakeAlarmEnabled
    @State private var routine = Preferences.morningRoutineMinutes
    @State private var notify = Preferences.briefNotificationsEnabled
    @State private var denied = false

    var body: some View {
        let plan = WakeAlarm.nextPlan(engine: store.engine, hidden: Preferences.hiddenCourses)
        Form {
            Section {
                Toggle("Wake me for my first class", isOn: $alarm)
                    .onChange(of: alarm) { _, on in
                        Task {
                            if on, !WakeAlarm.isAuthorized, !(await WakeAlarm.requestAuthorization()) {
                                alarm = false
                                denied = true
                                return
                            }
                            Preferences.wakeAlarmEnabled = on
                            await session.refreshBackgroundWork(using: store)
                        }
                    }
                Stepper("Ready in \(routine) min", value: $routine, in: 10 ... 120, step: 5)
                    .onChange(of: routine) { _, value in
                        Preferences.morningRoutineMinutes = value
                        Task { await session.refreshBackgroundWork(using: store) }
                    }
                if let plan {
                    LabeledContent("Next") {
                        Text("\(plan.wakeAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())) for \(plan.firstClass.event.course)")
                            .monospacedDigit()
                            .foregroundStyle(Bell.Content.secondary)
                    }
                }
                if denied {
                    Text("Alarms are off for Bell in Settings.")
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Signal.urgent)
                }
            } header: {
                Text("Wake-up")
            } footer: {
                Text(footer(plan))
            }

            Section {
                Toggle("Morning brief and Sunday review", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        Preferences.briefNotificationsEnabled = on
                        Task { await session.refreshBackgroundWork(using: store) }
                    }
            } footer: {
                Text("A few sentences about the day, at your wake time, and a look back at the week on Sunday evening.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Bell.Surface.canvas)
        .navigationTitle("Mornings")
    }

    private func footer(_ plan: WakePlan?) -> String {
        let walk: String = switch plan?.walkSource {
        case .home?: "the walk from HOME in your room coordinates"
        case .lastLocation?: "the walk from where your phone was last"
        default: "a guessed \(WakePlan.defaultWalkMinutes) minute walk, because Bell doesn't know where you start. Add HOME to Room coordinates to fix that"
        }
        return "A real alarm that sounds through silent mode, set from your first class, the leave-early "
            + "buffer, this getting-ready time and \(walk). It's recalculated whenever Bell runs, "
            + "usually the evening before; once set it can't adjust itself overnight."
    }
}
