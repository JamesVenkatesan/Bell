import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 9. Bell Max (large): what matters most today?

/// One hero, one list, one line: the shape of Apple's own large widgets.
///
/// The second design. The first stacked three sections of equal weight in
/// boxes and panels, which read as clutter however it was styled. This one
/// has a single focal point (the hero, in the app's Compressed Black), one
/// ring that carries the day's progress in course colours, and one list of
/// the rest of today in time order. One typeface apart from the numeral,
/// two weights, two greys, and no containers: hierarchy comes from size
/// and space, not from boxes.
///
/// What fills the hero, the list and the footer is decided by `MaxLayout`.
struct MaxWidgetView: View {
    var model: WidgetModel

    var body: some View {
        let layout = MaxLayout.make(model)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MaxHero(hero: layout.hero, model: model, listShowsNext: layout.listTitle != nil)
                Spacer(minLength: 0)
                if !model.today.isEmpty {
                    DayRing(model: model).frame(width: 62, height: 62)
                }
            }

            // The list sits on the bottom edge. Spare room on a light day
            // becomes air under the hero, which is how Apple's large
            // widgets breathe, instead of a gap left at the bottom.
            Spacer(minLength: 12)

            if !layout.rows.isEmpty {
                if let title = layout.listTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)
                        .padding(.bottom, 10)
                }
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(layout.rows) { MaxRow(row: $0, model: model) }
                }
            }

            if layout.more > 0 || layout.footer != nil {
                MaxFooter(footer: layout.footer, more: layout.more)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The ground is dark in both appearances, so the content is too:
        // otherwise "primary" would be black on black in light mode.
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Hero

private struct MaxHero: View {
    var hero: MaxLayout.Hero
    var model: WidgetModel
    /// The "coming up" list already names the next class.
    var listShowsNext = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
            number
                .padding(.top, -2)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The one large thing on the widget. A live countdown when there's a
    /// bell (it ticks without timeline entries), a clock time for an exam
    /// or a deadline, a short statement on a quiet day.
    @ViewBuilder
    private var number: some View {
        switch hero {
        case .bell(let bell):
            Text(timerInterval: model.date ... max(model.date, bell.at), countsDown: true)
                .font(Bell.Type_.bell(62))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .widgetAccentable()
        case .exam(let exam):
            clock(exam.task.due, allDay: exam.task.allDay)
        case .due(let task):
            clock(task.due, allDay: task.allDay)
        case .quiet(let quiet):
            Text(statement(quiet))
                .font(.system(size: 32, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .widgetAccentable()
                .padding(.vertical, 4)
        }
    }

    private func clock(_ date: Date, allDay: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if allDay {
                Text("Today").font(Bell.Type_.bell(62))
            } else {
                Text(date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(Bell.Type_.bell(62))
                Text(date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))).filter(\.isLetter))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }

    private var label: String {
        switch hero {
        case .bell(let bell):
            switch bell.kind {
            case .starts: "Starts in"
            case .ends: "Ends in"
            case .leave: "Leave in"
            }
        case .exam(let exam): exam.daysOut == 0 ? "Exam today" : "Exam tomorrow"
        case .due(let task): task.due < model.date && !task.allDay ? "Was due" : "Due next"
        case .quiet: model.date.formatted(.dateTime.weekday(.wide))
        }
    }

    /// The label carries the exam's urgency in colour; everything else's
    /// label is quiet.
    private var labelStyle: AnyShapeStyle {
        if case .exam = hero, mode == .fullColor { return AnyShapeStyle(Bell.Signal.now) }
        if case .due(let task) = hero, task.due < model.date, !task.allDay, mode == .fullColor {
            return AnyShapeStyle(Bell.Signal.now)
        }
        return AnyShapeStyle(.secondary)
    }

    private var title: String {
        switch hero {
        case .bell(let bell): bell.occurrence.event.course
        case .exam(let exam): exam.task.title
        case .due(let task): task.title
        case .quiet(.done(let at)): "Classes ended at \(widgetClock(at))"
        case .quiet(.noClasses): "No classes today"
        case .quiet(.away(let name)): name
        }
    }

    private var detail: String? {
        switch hero {
        case .bell(let bell):
            let event = bell.occurrence.event
            let parts = [event.room, bell.kind == .leave ? bell.walkMinutes.map { "\($0) min walk" } : nil]
            return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .exam(let exam):
            return ([exam.task.course ?? "Uncategorised"] + [exam.task.location].compactMap { $0 }).joined(separator: " · ")
        case .due(let task):
            return task.course ?? "Uncategorised"
        case .quiet:
            guard !listShowsNext, let next = model.tomorrowFirst else { return nil }
            let day = Calendar.current.isDateInTomorrow(next.start) ? "tomorrow" : next.start.formatted(.dateTime.weekday(.wide))
            return "Next: \(next.event.course), \(day) \(widgetClock(next.start))"
        }
    }

    private func statement(_ quiet: MaxLayout.Quiet) -> String {
        switch quiet {
        case .done: "All done"
        case .noClasses: "A clear day"
        case .away: "Nothing on"
        }
    }
}

// MARK: - Day ring

/// The day's classes as one ring, a segment each, sized by length, in
/// course colours: filled when finished, filling while in progress, a faint
/// track when still ahead. Fitness's language for "how far through", which
/// a home screen already knows how to read.
private struct DayRing: View {
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let classes = model.today
        let total = max(1, classes.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })
        let gap = classes.count > 1 ? 0.018 : 0
        let parts = segments(classes, total: total)
        ZStack {
            ZStack {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, segment in
                    let occurrence = classes[index]
                    let fill = fraction(of: occurrence)
                    // What's still ahead shows faintly in its own colour,
                    // so the ring previews the day before it starts.
                    Circle()
                        .trim(from: segment.start + gap / 2, to: segment.end - gap / 2)
                        .stroke((mode == .fullColor ? model.color(for: occurrence) : Color.primary).opacity(0.22),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    if fill > 0 {
                        Circle()
                            .trim(from: segment.start + gap / 2,
                                  to: max(segment.start + gap / 2,
                                          segment.start + (segment.end - segment.start) * fill - gap / 2))
                            .stroke(mode == .fullColor ? model.color(for: occurrence) : Color.primary,
                                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .widgetAccentable()
                    }
                }
            }
            .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(model.finished.count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("of \(classes.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.finished.count) of \(classes.count) classes done")
    }

    private func segments(_ classes: [ScheduleEngine.Occurrence], total: Double) -> [(start: Double, end: Double)] {
        var cursor = 0.0
        return classes.map { occurrence in
            let length = occurrence.end.timeIntervalSince(occurrence.start) / total
            defer { cursor += length }
            return (cursor, cursor + length)
        }
    }

    private func fraction(of occurrence: ScheduleEngine.Occurrence) -> Double {
        switch occurrence.status(at: model.date) {
        case .finished: 1
        case .inProgress: occurrence.progress(at: model.date)
        case .upcoming: 0
        }
    }
}

// MARK: - The rest of today

/// One line per item: time, a mark that says what kind of thing it is,
/// the title, and one quiet detail on the right.
private struct MaxRow: View {
    var row: MaxLayout.Row
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(timeText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(row.isMissed && mode == .fullColor ? AnyShapeStyle(Bell.Signal.now) : AnyShapeStyle(.secondary))
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)
            mark.frame(width: 16)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 22)
        // Finished classes stay, faded, so the list reads as the day so far
        // and what's left, not just a shrinking queue.
        .opacity(row.isPast ? (mode == .fullColor ? 0.38 : 0.55) : 1)
    }

    @ViewBuilder
    private var mark: some View {
        switch row.item {
        case .meeting(let occurrence):
            Capsule()
                .fill(mode == .fullColor ? model.color(for: occurrence) : .primary)
                .frame(width: 4, height: 18)
                .widgetAccentable()
        case .deadline(let task):
            // A ring you can tick, in the course's colour when there is one.
            Button(intent: CompleteTaskIntent(taskID: task.id)) {
                Circle()
                    .strokeBorder(ringColor(task), lineWidth: 1.75)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(task.title) done")
        case .exam:
            Circle()
                .fill(mode == .fullColor ? Bell.Signal.now : .primary)
                .frame(width: 9, height: 9)
                .widgetAccentable()
        }
    }

    private func ringColor(_ task: TaskEvent) -> Color {
        guard mode == .fullColor else { return .primary }
        return model.color(forCourse: task.course) ?? .secondary
    }

    private var timeText: String {
        let allDay: Bool = if case .deadline(let task) = row.item { task.allDay } else { false }
        if row.isLater {
            let day = row.time.formatted(.dateTime.weekday(.abbreviated))
            return allDay ? day : "\(day) \(row.time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))"
        }
        return allDay ? "Today" : widgetClock(row.time)
    }

    private var title: String {
        switch row.item {
        case .meeting(let o): o.event.course
        case .deadline(let t), .exam(let t): t.title
        }
    }

    private var detail: String {
        switch row.item {
        case .meeting(let o): o.event.room
        case .deadline(let t): t.course ?? "Uncategorised"
        case .exam(let t): "Exam" + (t.course.map { " · \($0)" } ?? "")
        }
    }
}

// MARK: - Footer

private struct MaxFooter: View {
    var footer: MaxLayout.Footer?
    var more: Int
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        HStack(spacing: 8) {
            switch footer {
            case .exam(let exam)?:
                // The day count in a small filled capsule: the only coloured
                // shape outside the ring, so the eye finds it.
                Text("\(exam.daysOut) days")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(mode == .fullColor ? AnyShapeStyle(Bell.legibleOn(Bell.Signal.now)) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        if mode == .fullColor {
                            Capsule().fill(Bell.Signal.now)
                        } else {
                            Capsule().strokeBorder(Color.primary, lineWidth: 1.5).widgetAccentable()
                        }
                    }
                Text("\(exam.task.title), \(exam.task.due.formatted(.dateTime.weekday(.abbreviated)))")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            case .stale(let synced)?:
                Text("Notion synced \(Text(synced, style: .relative)) ago")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
            if more > 0 {
                Text("+\(more) more")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Ground

/// A deep, quiet ground with one soft bloom of the hero's colour from the
/// top corner. Dark in either appearance, the way Weather and Music keep
/// their own look: dark lets the course colours and the white numeral carry
/// the design, and it sits well on almost any wallpaper.
struct MaxGround: View {
    var model: WidgetModel

    private var bloom: Color {
        switch MaxLayout.make(model).hero {
        case .exam: Bell.Signal.now
        case .bell(let bell): model.color(for: bell.occurrence)
        case .due(let task): model.color(forCourse: task.course) ?? Color(hex: 0x5B7BA6)
        case .quiet: Color(hex: 0x5B7BA6)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x17181D), Color(hex: 0x0C0D10)], startPoint: .top, endPoint: .bottom)
            // Lifted towards white before fading, so a warm course colour
            // glows rather than browning on the dark ground.
            RadialGradient(colors: [bloom.mix(with: .white, by: 0.2).opacity(0.34), bloom.opacity(0.06), .clear],
                           center: UnitPoint(x: 0.0, y: 0.0), startRadius: 0, endRadius: 300)
        }
    }
}
