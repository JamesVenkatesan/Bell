import SwiftUI

/// The first screen: one day, drawn to scale.
///
/// Laid out the way Apple's own day views are, with a large title that
/// collapses, a floating strip of days, and the schedule scrolling beneath
/// both. The strip is glass because the timeline really does pass under it;
/// that is the only reason it isn't a flat bar.
struct TodayScreen: View {
    var hero: Namespace.ID
    var open: (Route) -> Void
    var onImport: () -> Void

    @Environment(BellStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    /// Which way the last day change went, so the content slides in from the
    /// side the user swiped or tapped towards rather than always from one edge.
    @State private var travel: Edge = .trailing
    @State private var isAsking = false
    @State private var toast: ToastState?
    @State private var toastTask: Task<Void, Never>?
    /// True once the hero has scrolled away, which brings in the bar.
    @State private var pastHero = false

    struct ToastState: Equatable {
        var text: String
        var action: String?
        var inboxID: UUID?
        var opensInbox = false
    }

    private var calendar: Calendar { store.engine.calendar }
    private var isToday: Bool { calendar.isDateInToday(selectedDay) }

    var body: some View {
        Group {
            if store.timetable.events.isEmpty {
                EmptySchedule(onImport: onImport)
            } else {
                schedule
            }
        }
        .background(Bell.Surface.canvas)
        .navigationTitle(title)
        .navigationSubtitle(Text(selectedDay, format: .dateTime.month(.wide).day()))
        // Inline: on today the hero is the headline, and a large title
        // above it would be two headlines competing.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    // MARK: - Schedule

    private var schedule: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Bell.Space.loose) {
                    if isToday {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            BellSlab(bell: nextBell(at: context.date),
                                     tomorrow: store.engine.next(after: context.date),
                                     color: bellColor(at: context.date),
                                     now: context.date, hero: hero, open: open)
                        }
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 0 } action: {
                            pastHero = $0
                        }
                    }

                    DayStrip(selection: Binding(get: { selectedDay }, set: { select($0) }))

                    VStack(alignment: .leading, spacing: Bell.Space.loose) {
                        if !session.recentCancellations.isEmpty {
                            CancellationNotice(occurrences: session.recentCancellations) {
                                withAnimation(Bell.Motion.standard) {
                                    session.undoRecentCancellations(using: store)
                                }
                            } onDismiss: {
                                withAnimation(Bell.Motion.dismiss) { session.recentCancellations = [] }
                            }
                            .transition(.bellCard)
                        }
                        if isToday {
                            BriefCard(facts: Briefing.facts(engine: store.engine,
                                                            busy: session.calendar.external,
                                                            hidden: Preferences.hiddenCourses, now: .now),
                                      now: .now,
                                      onReview: showsReviewLink ? { open(.review) } : nil)
                            if !dueSoon.isEmpty {
                                VStack(alignment: .leading, spacing: Bell.Space.snug) {
                                    Text("Due soon")
                                        .font(Bell.Type_.headline)
                                        .foregroundStyle(Bell.Content.primary)
                                    ForEach(dueSoon) { task in
                                        TaskRow(task: task, pressure: pressures[task.id]) {
                                            withAnimation(Bell.Motion.standard) { store.setTaskDone(true, id: task.id) }
                                            Haptic.confirm.play()
                                        }
                                        .transition(.bellRow)
                                    }
                                }
                            }
                        }
                        day(proxy: proxy)
                    }
                    .id(selectedDay)
                    .transition(reduceMotion ? .opacity : .push(from: travel))
                }
                .padding(.horizontal, Bell.Space.gutter)
                .padding(.top, Bell.Space.tight)
                .padding(.bottom, Bell.Space.section)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isToday, pastHero {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let bell = nextBell(at: context.date) {
                            BellBar(bell: bell, color: bellColor(at: context.date), now: context.date)
                                .padding(.bottom, Bell.Space.snug)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Bell.Motion.standard, value: pastHero)
            .simultaneousGesture(daySwipe)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let toast {
                        Toast(text: toast.text, actionTitle: toast.action) { handleToastAction(toast) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    AskBar(onSubmit: submit)
                }
                .animation(Bell.Motion.standard, value: toast)
            }
            .sheet(isPresented: $isAsking) {
                AskSheet().presentationDetents([.medium, .large])
            }
        }
    }

    private func nextBell(at now: Date) -> NextBell? {
        NextBell.make(engine: store.engine, hidden: Preferences.hiddenCourses, now: now,
                      bufferMinutes: Preferences.leaveBuffer, walkSeconds: Campus.walkingSeconds)
    }

    private func bellColor(at now: Date) -> Color {
        nextBell(at: now).flatMap { store.palette[$0.occurrence.event.course] } ?? Bell.Surface.scaffold
    }

    @ViewBuilder
    private func day(proxy: ScrollViewProxy) -> some View {
        let occurrences = store.engine.occurrences(on: selectedDay)
            .filter { !Preferences.hiddenCourses.contains($0.event.course) }
        let busy = session.calendar.external(on: selectedDay)
        let cancelled = store.engine.cancelledOccurrences(on: selectedDay)
        let conflicts = ConflictDetector.conflicts(classes: occurrences, events: busy,
                                                   walkSeconds: Campus.walkingSeconds)

        if !conflicts.isEmpty {
            ConflictList(conflicts: conflicts)
        }

        if let holiday = store.engine.exception(on: selectedDay) {
            DayQuiet(headline: holiday.name, detail: "No classes scheduled.", symbol: "moon.zzz")
        } else if !store.engine.isInTerm(selectedDay) {
            DayQuiet(headline: "Outside term",
                     detail: "Term dates are set in Settings.",
                     symbol: "calendar.badge.minus")
        } else if occurrences.isEmpty && busy.isEmpty {
            DayQuiet(headline: cancelled.isEmpty ? "Nothing scheduled" : "Everything's cancelled",
                     detail: nil, symbol: "circle.dotted")
        } else {
            let layout = DayLayout(occurrences: occurrences,
                                   busy: busy,
                                   calendar: calendar,
                                   walkSeconds: Campus.walkingSeconds)
            // Overlaps outrank travel clashes: two places at once is worse
            // than arriving late.
            let worst = Dictionary(conflicts.map { ($0.occurrence.id, $0) }) { a, b in
                a.kind.isOverlap ? a : b
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                DayTimeline(layout: layout,
                            now: context.date,
                            palette: store.palette,
                            hero: hero,
                            conflicts: worst,
                            suggestions: suggestions(for: layout),
                            open: open)
            }
            .onAppear {
                // Never on today: the hero at the top *is* now, and scrolling
                // to the timeline's now line hid it. Other days have no hero,
                // so there's nothing to scroll for either; this is kept for
                // a day viewed while it's under way in another context.
                guard !isToday, calendar.isDateInToday(selectedDay), layout.nowY(at: .now) != nil else { return }
                // Lands with now a third of the way down, so the class you
                // are in and the next one are both on screen without
                // scrolling, which is what opening the app is for.
                proxy.scrollTo(DayTimeline.nowAnchor, anchor: UnitPoint(x: 0, y: 0.33))
            }
        }

        if !cancelled.isEmpty {
            CancelledList(occurrences: cancelled) { occurrence in
                withAnimation(Bell.Motion.arrive) { store.restore(cancellationKey: occurrence.key) }
                Haptic.confirm.play()
            }
        }
    }

    // MARK: - Intelligence

    /// Sunday through Monday, when looking back at the week is the natural
    /// thing to do.
    private var showsReviewLink: Bool {
        let index = store.engine.mondayBasedIndex(for: .now)
        return index == 6 || index == 0
    }

    private var pressures: [UUID: DeadlinePressure] {
        let all = DeadlinePressure.evaluate(tasks: store.timetable.tasks, engine: store.engine,
                                            busy: session.calendar.external, now: .now)
        return Dictionary(all.map { ($0.task.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func suggestions(for layout: DayLayout) -> [Date: String] {
        let free = layout.gaps.filter { $0.kind == .free }.map { DateInterval(start: $0.start, end: $0.end) }
        let ranked = DeadlinePressure.evaluate(tasks: store.timetable.tasks, engine: store.engine,
                                               busy: session.calendar.external, now: .now)
        return Dictionary(GapAdvisor.suggest(gaps: free, pressures: ranked).map { ($0.gapStart, $0.text) },
                          uniquingKeysWith: { a, _ in a })
    }

    private func submit(_ text: String) {
        switch AskIntent.classify(text) {
        case .question:
            isAsking = true
            Task { await session.ask(text, store: store) }
        case .instruction:
            Task {
                switch await session.tell(text, store: store) {
                case .added(let title, let due, let id):
                    Haptic.confirm.play()
                    show(ToastState(text: "Added \(title), \(due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
                                    action: "Undo", inboxID: id))
                case .needsDetails:
                    Haptic.warn.play()
                    show(ToastState(text: "No date in that, so it's in your inbox to finish.",
                                    action: "Open", opensInbox: true))
                }
            }
        }
    }

    private func show(_ state: ToastState) {
        toastTask?.cancel()
        toast = state
        toastTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func handleToastAction(_ state: ToastState) {
        if state.opensInbox {
            open(.inbox)
        } else if let id = state.inboxID {
            withAnimation(Bell.Motion.dismiss) {
                store.undoAutomaticAdd(inboxID: id)
                store.dismiss(inboxID: id)
            }
        }
        toast = nil
    }

    // MARK: - Changing day

    private func select(_ day: Date) {
        let target = calendar.startOfDay(for: day)
        guard target != selectedDay else { return }
        travel = target > selectedDay ? .trailing : .leading
        withAnimation(Bell.Motion.standard) { selectedDay = target }
    }

    private func shift(by days: Int) {
        guard let target = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        select(target)
        Haptic.tick.play()
    }

    /// Horizontal swipes page between days. Recognised alongside the vertical
    /// scroll and only when clearly sideways, so a slightly diagonal scroll
    /// never flips the day out from under you.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                shift(by: dx < 0 ? 1 : -1)
            }
    }

    // MARK: - Chrome

    private var pendingCount: Int { store.inbox.filter { $0.state == .pending }.count }

    /// Work due in the next three days, above the timeline. Three because
    /// that's the horizon where "due" changes what you do today.
    private var dueSoon: [TaskEvent] {
        let start = calendar.startOfDay(for: .now)
        let horizon = calendar.date(byAdding: .day, value: 3, to: start) ?? start
        return store.timetable.tasks
            .filter { !$0.isDone && $0.due >= start && $0.due < horizon }
            .sorted { $0.due < $1.due }
    }

    private var title: String {
        if isToday { return "Today" }
        if calendar.isDateInTomorrow(selectedDay) { return "Tomorrow" }
        if calendar.isDateInYesterday(selectedDay) { return "Yesterday" }
        return selectedDay.formatted(.dateTime.weekday(.wide))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { open(.week) } label: {
                Label("Week", systemImage: "calendar")
            }
        }
        if !isToday {
            ToolbarItem(placement: .topBarLeading) {
                Button("Today") { select(.now) }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { open(.inbox) } label: {
                Label("Inbox", systemImage: pendingCount > 0 ? "tray.full" : "tray")
            }
            .badge(pendingCount)
            Button(action: onImport) {
                Label("Update schedule", systemImage: "square.and.arrow.down")
            }
            Button { open(.settings) } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

// MARK: - Day strip

/// Two weeks of days either side of today, in a glass capsule that floats
/// over the timeline. The selection is one shape that slides between days,
/// matched across positions, so changing day looks like moving a marker
/// rather than repainting a row.
struct DayStrip: View {
    @Binding var selection: Date

    @Environment(BellStore.self) private var store
    @Namespace private var marker

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (-7 ... 20).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Bell.Space.tight) {
                    ForEach(days, id: \.self) { day in
                        cell(day)
                            .id(day)
                    }
                }
                .padding(Bell.Space.tight)
            }
            .scrollClipDisabled(false)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, day in
                withAnimation(Bell.Motion.standard) { proxy.scrollTo(day, anchor: .center) }
            }
        }
        .haptic(.select, on: selection)
    }

    private func cell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let hasClasses = !store.engine.occurrences(on: day).isEmpty

        return Button {
            withAnimation(Bell.Motion.snap) { selection = day }
        } label: {
            VStack(spacing: Bell.Space.hair) {
                Text(day, format: .dateTime.weekday(.narrow))
                    .font(Bell.Type_.micro)
                    .foregroundStyle(isSelected ? Bell.Surface.canvas : Bell.Content.tertiary)
                Text(day, format: .dateTime.day())
                    .font(Bell.Type_.data(16, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Bell.Surface.canvas : Bell.Content.primary)
                Circle()
                    .fill(isSelected ? Bell.Surface.canvas : Bell.Content.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(hasClasses ? 1 : 0)
            }
            .frame(width: 40, height: 54)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Bell.Content.primary)
                        .matchedGeometryEffect(id: "selected-day", in: marker)
                } else if isToday {
                    Capsule(style: .continuous)
                        .strokeBorder(Bell.Content.tertiary, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Quiet and empty

private struct DayQuiet: View {
    var headline: String
    var detail: String?
    var symbol: String

    var body: some View {
        VStack(spacing: Bell.Space.snug) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Bell.Content.tertiary)
                .symbolEffect(.breathe, options: .nonRepeating)
                .padding(.bottom, Bell.Space.tight)
            Text(headline)
                .font(Bell.Type_.headline)
                .foregroundStyle(Bell.Content.primary)
            if let detail {
                Text(detail)
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Bell.Space.section * 2)
    }
}

/// An empty screen is an invitation to act, so it says exactly what to do and
/// what will happen, not "no data".
struct EmptySchedule: View {
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.base) {
            Spacer()
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Bell.Content.secondary)
                .symbolEffect(.wiggle, options: .nonRepeating)
                .padding(.bottom, Bell.Space.snug)

            Text("Bring your schedule over")
                .font(Bell.Type_.title)
                .foregroundStyle(Bell.Content.primary)

            Text("Subscribe to your registrar's calendar, or open the PDF or a screenshot. "
                 + "Bell reads it on this device and shows you what it found before anything changes.")
                .font(Bell.Type_.body)
                .foregroundStyle(Bell.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onImport) {
                Text("Import schedule")
                    .font(Bell.Type_.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Bell.Space.snug)
            }
            .buttonStyle(.glassProminent)
            // Filled with the near-white app tint, so the label takes the canvas
            // colour; left alone it was white on white.
            .foregroundStyle(Bell.Surface.canvas)
        }
        .padding(Bell.Space.loose)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Calendar results

/// Clashes with the rest of the user's calendar on this day, in words.
/// The badge on a class says *that* something's wrong; this says what.
private struct ConflictList: View {
    var conflicts: [ConflictDetector.Conflict]

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            ForEach(conflicts) { conflict in
                Label {
                    VStack(alignment: .leading, spacing: Bell.Space.hair) {
                        Text(headline(conflict))
                            .font(Bell.Type_.caption.weight(.semibold))
                            .foregroundStyle(Bell.Content.primary)
                        Text(detail(conflict))
                            .font(Bell.Type_.caption)
                            .foregroundStyle(Bell.Content.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: conflict.kind.isOverlap ? "exclamationmark.2" : "figure.walk.motion")
                        .foregroundStyle(conflict.kind.isOverlap ? Bell.Signal.conflict : Bell.Signal.urgent)
                }
            }
        }
        .padding(Bell.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .fill(Bell.Surface.raised))
        .overlay(RoundedRectangle(cornerRadius: Bell.Radius.large, style: .continuous)
            .strokeBorder(Bell.Signal.urgent.opacity(0.35), lineWidth: Bell.Stroke.hair))
        .transition(.bellCard)
    }

    private func headline(_ conflict: ConflictDetector.Conflict) -> String {
        "\(conflict.occurrence.event.course) and \(conflict.event.title)"
    }

    private func detail(_ conflict: ConflictDetector.Conflict) -> String {
        switch conflict.kind {
        case .overlap(let minutes):
            return "Overlap by \(minutes) min. \(conflict.event.calendarTitle) calendar."
        case .cantReachClass(let gap, let walk):
            return "\(gap) min gap, \(walk) min walk to \(conflict.occurrence.event.room)."
        case .cantReachEvent(let gap, let walk):
            return "\(gap) min gap, \(walk) min walk to \(conflict.event.location ?? "it")."
        }
    }
}

/// Shown once after a sync turned calendar deletions into cancellations.
/// Something done in another app changed Bell's schedule, so it says so and
/// offers to take it back, instead of letting a class quietly disappear.
private struct CancellationNotice: View {
    var occurrences: [ScheduleEngine.Occurrence]
    var onUndo: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Bell.Space.base) {
            Image(systemName: "calendar.badge.minus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Bell.Signal.urgent)
            VStack(alignment: .leading, spacing: Bell.Space.tight) {
                Text(title)
                    .font(Bell.Type_.caption.weight(.semibold))
                    .foregroundStyle(Bell.Content.primary)
                Text("Deleted from your calendar, so Bell marked \(occurrences.count == 1 ? "it" : "them") cancelled.")
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Bell.Space.base) {
                    Button("Undo", action: onUndo).buttonStyle(.glass)
                    Button("OK", action: onDismiss)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                }
                .padding(.top, Bell.Space.tight)
            }
            Spacer(minLength: 0)
        }
        .padding(Bell.Space.roomy)
        .glassEffect(Bell.Material_.floating, in: .rect(cornerRadius: Bell.Radius.large))
    }

    private var title: String {
        guard let first = occurrences.first else { return "" }
        let when = first.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return occurrences.count == 1
            ? "\(first.event.course), \(when)"
            : "\(occurrences.count) classes, from \(first.event.course) \(when)"
    }
}

private struct CancelledList: View {
    var occurrences: [ScheduleEngine.Occurrence]
    var onRestore: (ScheduleEngine.Occurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Bell.Space.snug) {
            Text("Cancelled")
                .font(Bell.Type_.micro)
                .foregroundStyle(Bell.Content.secondary)
            ForEach(occurrences) { occurrence in
                HStack {
                    Text(occurrence.event.course)
                        .strikethrough(color: Bell.Content.tertiary)
                        .foregroundStyle(Bell.Content.secondary)
                    Text(occurrence.start, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(Bell.Content.tertiary)
                    Spacer()
                    Button("Restore") { onRestore(occurrence) }
                        .font(Bell.Type_.caption.weight(.medium))
                        .buttonStyle(.glass)
                }
                .font(Bell.Type_.body)
            }
        }
    }
}
