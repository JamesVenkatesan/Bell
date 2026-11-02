import AppIntents
import SwiftUI
import WidgetKit

// The eight widgets. Each answers one question, has one focal point, and
// uses its family's space for that question rather than shrinking another's.
//
// Shared with the app so the gallery renders exactly what the home screen
// does. Tint survival on every one: text, SF Symbols and shapes only; the
// focal element marked `widgetAccentable()`; colours chosen by luminance, so
// a tinted home screen that throws hue away still shows the hierarchy.

// MARK: - Shared pieces

enum WidgetKind: String, CaseIterable, Identifiable {
    case bell, behind, free, due, today, week, leave, term
    var id: String { rawValue }

    var name: String {
        switch self {
        case .bell: "Bell"
        case .behind: "Behind me"
        case .free: "Free"
        case .due: "Due"
        case .today: "The rest of today"
        case .week: "Week"
        case .leave: "Leave"
        case .term: "Term"
        }
    }

    var question: String {
        switch self {
        case .bell: "How long until the next bell?"
        case .behind: "How much of today is done?"
        case .free: "When am I actually free today?"
        case .due: "What's due that isn't a class?"
        case .today: "What happens next, in order?"
        case .week: "How does the whole week look?"
        case .leave: "When do I leave, and for where?"
        case .term: "How far through the term am I?"
        }
    }

    var family: WidgetFamily {
        switch self {
        case .bell, .behind: .systemSmall
        case .free, .due: .systemMedium
        case .today, .week: .systemLarge
        case .leave: .accessoryRectangular
        case .term: .accessoryCircular
        }
    }

    var kindID: String { "com.yourteam.bell.\(rawValue)" }
}

/// The view for a kind. One switch, used by the extension and the gallery.
struct WidgetBody: View {
    var kind: WidgetKind
    var model: WidgetModel

    var body: some View {
        switch kind {
        case .bell: BellWidgetView(model: model)
        case .behind: BehindWidgetView(model: model)
        case .free: FreeWidgetView(model: model)
        case .due: DueWidgetView(model: model)
        case .today: TodayWidgetView(model: model)
        case .week: WeekWidgetView(model: model)
        case .leave: LeaveWidgetView(model: model)
        case .term: TermWidgetView(model: model)
        }
    }

    /// The ground behind it. Only the Bell widget is loud: the whole tile is
    /// the course's colour, the way the hero is in the app. Everything else
    /// sits on the plain ground next to Apple's own widgets.
    static func background(_ kind: WidgetKind, _ model: WidgetModel) -> Color {
        if kind == .bell, let bell = model.bell { return model.color(for: bell.occurrence) }
        return Bell.Surface.raised
    }
}

private func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

private func duration(_ interval: TimeInterval) -> String {
    let minutes = Int(interval / 60)
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

/// A true sentence for when there's nothing to count: a break, a weekend,
/// after the last class, or out of term. Never a blank tile.
private struct QuietTile: View {
    var model: WidgetModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 16 : 20, weight: .semibold))
                .widgetAccentable()
            Spacer(minLength: 0)
            Text(headline)
                .font(.system(size: compact ? 17 : 20, weight: .bold).width(.expanded))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch model.quiet {
        case .noSchedule?: "square.and.arrow.down"
        case .onBreak?: "sun.max"
        case .outOfTerm?: "graduationcap"
        case .noClasses?: "moon.stars"
        case nil: "checkmark.circle"
        }
    }

    private var headline: String {
        switch model.quiet {
        case .noSchedule?: "No schedule yet"
        case .onBreak(let name)?: name
        case .outOfTerm?: "Out of term"
        case .noClasses?: "No classes today"
        case nil: "Done for today"
        }
    }

    private var detail: String? {
        if model.quiet == .noSchedule { return "Open Bell to import it." }
        guard let next = model.tomorrowFirst else { return nil }
        let day = Calendar.current.isDateInTomorrow(next.start) ? "Tomorrow" : next.start.formatted(.dateTime.weekday(.abbreviated))
        return "\(day): \(next.event.course), \(clock(next.start))"
    }
}

// MARK: - 1. Bell (small): how long until the next bell?

struct BellWidgetView: View {
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if let bell = model.bell {
            let ink = mode == .fullColor ? Bell.legibleOn(model.color(for: bell.occurrence)) : Color.primary
            VStack(alignment: .leading, spacing: 0) {
                Text(label(bell.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.8)
                // The focal point: the same Compressed Black as the app's
                // hero, ticking on its own between timeline entries.
                Text(timerInterval: model.date ... max(model.date, bell.at), countsDown: true)
                    .font(Bell.Type_.bell(50))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .widgetAccentable()
                Spacer(minLength: 2)
                Text(bell.occurrence.event.course)
                    .font(.system(size: 15, weight: .bold).width(.expanded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(bell.occurrence.event.room.isEmpty ? clock(bell.occurrence.start) : bell.occurrence.event.room)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.8)
                // The drain, as on the hero: full when the wait began, empty
                // when the bell goes.
                ProgressView(timerInterval: bell.from ... max(bell.from, bell.at), countsDown: true) {
                    EmptyView()
                } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(ink)
                    .padding(.top, 6)
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            QuietTile(model: model, compact: true)
        }
    }

    private func label(_ kind: NextBell.Kind) -> String {
        switch kind {
        case .starts: "Starts in"
        case .ends: "Ends in"
        case .leave: "Leave in"
        }
    }
}

// MARK: - 2. Behind me (small): how much of today is done?

struct BehindWidgetView: View {
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if model.quiet != nil {
            QuietTile(model: model, compact: true)
        } else {
            let done = model.finished.count
            VStack(alignment: .leading, spacing: 0) {
                Text("Behind you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(done)")
                        .font(Bell.Type_.bell(64))
                        .widgetAccentable()
                    Text("of \(model.today.count)")
                        .font(.system(size: 17, weight: .bold).width(.expanded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // The day as segments, one per class, proportional to length.
                GeometryReader { geometry in
                    let total = max(1, model.today.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })
                    HStack(spacing: 3) {
                        ForEach(model.today) { occurrence in
                            segment(occurrence)
                                .frame(width: max(4, (geometry.size.width - CGFloat(model.today.count - 1) * 3)
                                                  * occurrence.end.timeIntervalSince(occurrence.start) / total))
                        }
                    }
                }
                .frame(height: 10)
                Text(model.lastEnd.map { done == model.today.count ? "All done" : "Done at \(clock($0))" } ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segment(_ occurrence: ScheduleEngine.Occurrence) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch occurrence.status(at: model.date) {
        case .finished:
            shape.fill(Color.primary).widgetAccentable()
        case .inProgress:
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(0.18))
                GeometryReader { g in
                    shape.fill(mode == .fullColor ? model.color(for: occurrence) : .primary)
                        .frame(width: g.size.width * occurrence.progress(at: model.date))
                }
            }
        case .upcoming:
            shape.fill(Color.primary.opacity(0.18))
        }
    }
}

// MARK: - 3. Free (medium): when am I actually free today?

struct FreeWidgetView: View {
    var model: WidgetModel

    var body: some View {
        if let quiet = model.quiet, quiet != .noClasses {
            QuietTile(model: model)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    focal
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                track
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var focal: some View {
        if let last = model.lastEnd, last <= model.date || model.today.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Free").font(Bell.Type_.bell(44)).widgetAccentable()
                Text("for the rest of the day").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
        } else if let best = model.bestFree {
            VStack(alignment: .leading, spacing: 0) {
                Text("Longest free stretch").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(duration(best.duration)).font(Bell.Type_.bell(44)).widgetAccentable()
                Text("\(clock(best.start)) to \(clock(best.end))")
                    .font(.system(size: 13, weight: .semibold).width(.expanded))
                    .monospacedDigit()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Busy until").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(model.lastEnd.map(clock) ?? "").font(Bell.Type_.bell(44)).widgetAccentable()
                Text("No half hour free before then").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    /// 8am to 10pm at true scale: what's taken in ink, what's free left
    /// empty, the longest free stretch underlined, and now in vermilion.
    private var track: some View {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: model.date)
        let start = day.addingTimeInterval(8 * 3600), end = day.addingTimeInterval(22 * 3600)
        let span = end.timeIntervalSince(start)
        func x(_ date: Date, _ width: CGFloat) -> CGFloat {
            width * CGFloat(min(1, max(0, date.timeIntervalSince(start) / span)))
        }
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                let w = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    ForEach(Array(model.busyToday.enumerated()), id: \.offset) { _, block in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(block.end <= model.date ? 0.3 : 0.85))
                            .frame(width: max(2, x(block.end, w) - x(block.start, w)))
                            .offset(x: x(block.start, w))
                    }
                    if let best = model.bestFree {
                        Capsule().fill(Color.primary).widgetAccentable()
                            .frame(width: max(2, x(best.end, w) - x(best.start, w)), height: 3)
                            .offset(x: x(best.start, w), y: 11)
                    }
                    if model.date > start, model.date < end {
                        Capsule().fill(Bell.Signal.now)
                            .frame(width: 2, height: 20)
                            .offset(x: x(model.date, w) - 1)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                ForEach([8, 12, 16, 20], id: \.self) { hour in
                    Text(hour == 12 ? "12p" : hour < 12 ? "\(hour)a" : "\(hour - 12)p")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if hour != 20 { Spacer() }
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - 4. Due (medium): what's due that isn't a class?

struct DueWidgetView: View {
    var model: WidgetModel

    var body: some View {
        if model.due.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "checkmark.circle").font(.system(size: 20, weight: .semibold)).widgetAccentable()
                Spacer(minLength: 0)
                Text("Nothing due").font(.system(size: 20, weight: .bold).width(.expanded))
                Text("in the next seven days").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 14) {
                if let first = model.due.first { focal(first) }
                if model.due.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.due.dropFirst()) { row($0) }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 120, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func focal(_ p: DeadlinePressure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(p.task.due, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(intent: CompleteTaskIntent(taskID: p.task.id)) {
                    Image(systemName: "circle").font(.system(size: 20, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(p.task.title) done")
            }
            Text(p.task.title)
                .font(.system(size: 18, weight: .bold).width(.expanded))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text("About \(Int(p.freeHours.rounded())) free hours before it")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.level >= .tight ? Bell.Signal.now : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ p: DeadlinePressure) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button(intent: CompleteTaskIntent(taskID: p.task.id)) {
                Image(systemName: "circle").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.task.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(p.task.due, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 5. The rest of today (large): what happens next, in order?

struct TodayWidgetView: View {
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if let quiet = model.quiet {
            let _ = quiet
            QuietTile(model: model)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.date, format: .dateTime.weekday(.wide))
                        .font(.system(size: 22, weight: .bold).width(.expanded))
                    Spacer()
                    Text("\(model.finished.count) of \(model.today.count) done")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)

                if let prompt = model.attendancePrompt { attendance(prompt).padding(.bottom, 10) }

                let window = RowWindow.select(model.today, now: model.date, limit: model.attendancePrompt == nil ? 5 : 4)
                // The rows share the height between them, so a light day
                // fills the tile instead of leaving its lower third empty.
                // Capped, so two classes don't drift to opposite corners.
                ForEach(Array(window.rows.enumerated()), id: \.element.id) { index, occurrence in
                    if index > 0 { Spacer(minLength: 7).frame(maxHeight: 30) }
                    row(occurrence)
                }
                Spacer(minLength: 7)
                if let last = model.lastEnd {
                    Text(last > model.date ? "Free from \(clock(last))" : "All done for today")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ occurrence: ScheduleEngine.Occurrence) -> some View {
        let status = occurrence.status(at: model.date)
        let level = RowEmphasis(status)
        let focal = status == .inProgress || occurrence.id == model.bell?.occurrence.id
        return HStack(alignment: .center, spacing: 10) {
            Text(clock(occurrence.start))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(mode == .fullColor ? model.color(for: occurrence) : .primary)
                .frame(width: 6, height: focal ? 40 : 30)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(occurrence.event.course)
                    .font(.system(size: focal ? 17 : 14, weight: focal ? .bold : .semibold).width(focal ? .expanded : .standard))
                    .strikethrough(level.isStruck)
                    .lineLimit(1)
                Text(occurrence.event.room)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status == .inProgress {
                Text(timerInterval: model.date ... occurrence.end, countsDown: true)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Bell.Signal.now)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .opacity(level.opacity)
    }

    /// One tap, no app: the class that just ended, and whether you went.
    private func attendance(_ occurrence: ScheduleEngine.Occurrence) -> some View {
        HStack(spacing: 8) {
            Text("Did you make \(occurrence.event.course)?")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(intent: MarkAttendanceIntent(course: occurrence.event.course, start: occurrence.start, went: true)) {
                Text("Went").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            Button(intent: MarkAttendanceIntent(course: occurrence.event.course, start: occurrence.start, went: false)) {
                Text("Missed").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 6. Week (large): how does the whole week look?

struct WeekWidgetView: View {
    var model: WidgetModel
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        if model.quiet == .noSchedule || model.quiet == .outOfTerm {
            QuietTile(model: model)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This week").font(.system(size: 20, weight: .bold).width(.expanded))
                    Spacer()
                    Text(summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in grid(in: geometry.size) }
            }
        }
    }

    private var summary: String {
        let counts = model.week.map(\.count)
        guard let most = counts.max(), most > 0, let index = counts.firstIndex(of: most) else { return "Clear week" }
        let day = Calendar.current.date(byAdding: .day, value: index, to: model.weekStart) ?? model.weekStart
        return "Heaviest: \(day.formatted(.dateTime.weekday(.wide)))"
    }

    private func grid(in size: CGSize) -> some View {
        let events = model.week.flatMap { $0.map(\.event) }
        var geometry = WeekGridGeometry(events: events, dayCount: model.week.count, columnsWidth: size.width - 26)
        let headerHeight: CGFloat = 30
        geometry.pointsPerHour = max(1, (size.height - headerHeight) / max(1, CGFloat(geometry.endSecond - geometry.startSecond) / 3600))

        return ZStack(alignment: .topLeading) {
            ForEach(geometry.hours.filter { $0 % 2 == 0 }, id: \.self) { hour in
                HStack(spacing: 4) {
                    Text(hour == 12 ? "12p" : hour < 12 ? "\(hour)a" : "\(hour - 12)p")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                }
                .offset(y: headerHeight + geometry.y(forSecond: hour * 3600) - 5)
            }
            ForEach(Array(model.week.enumerated()), id: \.offset) { column, day in
                let date = Calendar.current.date(byAdding: .day, value: column, to: model.weekStart) ?? model.weekStart
                let isToday = Calendar.current.isDate(date, inSameDayAs: model.date)
                VStack(spacing: 0) {
                    Text(date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(date, format: .dateTime.day())
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        // `.background`, not white: tinted, the circle turns
                        // white too, and fixed white text vanished into it.
                        .foregroundStyle(isToday ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                        .frame(width: 20, height: 18)
                        .background { if isToday { Capsule().fill(Color.primary).widgetAccentable() } }
                }
                .frame(width: geometry.columnWidth)
                .offset(x: 26 + geometry.x(forDay: column))

                ForEach(day) { occurrence in
                    var placed = occurrence.event
                    let _ = (placed.dayIndex = column)
                    let frame = geometry.frame(for: placed)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(mode == .fullColor ? model.color(for: occurrence) : .primary)
                        .overlay(alignment: .topLeading) {
                            if frame.height > 18 {
                                Text(occurrence.event.course.split(separator: " ").last.map(String.init) ?? "")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(mode == .fullColor ? Bell.legibleOn(model.color(for: occurrence)) : Color(white: 0.1))
                                    .padding(3)
                            }
                        }
                        .opacity(RowEmphasis(occurrence.status(at: model.date)).opacity)
                        .frame(width: geometry.columnWidth - 3, height: max(6, frame.height - 1.5))
                        .offset(x: 26 + frame.x, y: headerHeight + frame.y)
                        .widgetAccentable(isToday)
                }
            }
        }
    }
}

// MARK: - 7. Leave (lock screen, rectangular): when do I leave, and for where?

struct LeaveWidgetView: View {
    var model: WidgetModel

    private var quietHeadline: String {
        switch model.quiet {
        case .onBreak(let name)?: name
        case .outOfTerm?: "Out of term"
        case .noSchedule?: "No schedule yet"
        case .noClasses?: "No classes today"
        case nil: "No more classes"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bell = model.bell {
                switch bell.kind {
                case .leave:
                    Text("Leave \(clock(bell.at))").font(.system(size: 17, weight: .bold)).widgetAccentable()
                    Text("\(bell.occurrence.event.course) · \(bell.occurrence.event.room)").font(.system(size: 13, weight: .semibold))
                    Text("\(bell.walkMinutes ?? 0) min walk, starts \(clock(bell.occurrence.start))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                case .starts:
                    Text("\(bell.occurrence.event.course) \(clock(bell.occurrence.start))").font(.system(size: 17, weight: .bold)).widgetAccentable()
                    Text(bell.occurrence.event.room).font(.system(size: 13, weight: .semibold))
                    Text(bell.walkMinutes.map { "\($0) min walk, go now" } ?? "No walk needed")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                case .ends:
                    let next = model.today.first { $0.start >= bell.occurrence.end }
                    Text("In \(bell.occurrence.event.course)").font(.system(size: 17, weight: .bold)).widgetAccentable()
                    Text("until \(clock(bell.at))").font(.system(size: 13, weight: .semibold))
                    Text(next.map { "Then \($0.event.course), \($0.event.room)" } ?? "Last class today")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(quietHeadline).font(.system(size: 17, weight: .bold)).widgetAccentable()
                if let next = model.tomorrowFirst {
                    Text("Next: \(next.event.course)").font(.system(size: 13, weight: .semibold))
                    Text(next.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 8. Term (lock screen, circular): how far through the term am I?

struct TermWidgetView: View {
    var model: WidgetModel

    var body: some View {
        if let term = model.term {
            Gauge(value: term.fraction) {
                Image(systemName: "graduationcap")
            } currentValueLabel: {
                if term.onBreak != nil {
                    Image(systemName: "sun.max")
                } else {
                    Text("W\(term.week)")
                        .font(.system(size: 15, weight: .bold).width(.compressed))
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel("Week \(term.week) of \(term.weeks)")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "graduationcap").font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("Out of term")
        }
    }
}
