import SwiftUI
import WidgetKit

// MARK: - Bundle

@main
struct BellWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextClassWidget()
        TodayWidget()
        WeekWidget()
        if #available(iOS 16.2, *) {
            ClassLiveActivity()
        }
    }
}

// MARK: - Small + accessory: what's next

struct NextClassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.yourteam.bell.next", provider: ScheduleProvider()) { entry in
            NextClassView(entry: entry)
                .containerBackground(Palette.ink.gradient, for: .widget)
        }
        .configurationDisplayName("Next class")
        .description("The class you're in, or the one you're walking to.")
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct NextClassView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ScheduleEntry

    var body: some View {
        switch family {
        case .accessoryInline: inlineBody
        case .accessoryCircular: circularBody
        case .accessoryRectangular: rectangularBody
        default: smallBody
        }
    }

    // Home screen small.
    @ViewBuilder private var smallBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reason = entry.quietReason {
                QuietState(headline: reason, detail: nextDayHint, symbol: "moon.zzz")
            } else if let current = entry.current {
                header("In class")
                Text(current.event.course)
                    .font(.system(size: 20, weight: .semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(current.event.room)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                ProgressRail(progress: current.progress(at: entry.date),
                             color: color(for: current))
                    .padding(.bottom, 5)

                HStack {
                    Text("Ends ") + Text(current.end, style: .relative)
                    Spacer()
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            } else if let next = entry.next {
                header(dayLabel(for: next.start))
                Text(next.event.course)
                    .font(.system(size: 20, weight: .semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(next.event.room)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Text(next.start, style: .relative)
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()

                if let leaveBy = entry.leaveBy {
                    LeaveNowBadge(leaveBy: leaveBy, walkNote: entry.walkNote, now: entry.date)
                        .padding(.top, 2)
                }
            } else {
                QuietState(headline: "Nothing left today", detail: nextDayHint, symbol: "checkmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // Lock screen: one line, no decoration.
    @ViewBuilder private var inlineBody: some View {
        if let current = entry.current {
            Text("\(current.event.course) · ends \(current.end, style: .relative)")
        } else if let next = entry.next {
            Text("\(next.event.course) · \(next.start, format: .dateTime.hour().minute())")
        } else {
            Text(entry.quietReason ?? "No more classes")
        }
    }

    // Lock screen circular: a ring that fills through the current class.
    private var circularBody: some View {
        Gauge(value: entry.current?.progress(at: entry.date) ?? 0) {
            Image(systemName: "graduationcap.fill")
        } currentValueLabel: {
            Text(shortCode)
                .font(.system(size: 11, weight: .semibold))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
    }

    @ViewBuilder private var rectangularBody: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let current = entry.current {
                Text("Now · \(current.event.room)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(current.event.course).font(.system(size: 15, weight: .semibold))
                Text("Ends ") + Text(current.end, style: .relative)
            } else if let next = entry.next {
                Text(dayLabel(for: next.start))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(next.event.course).font(.system(size: 15, weight: .semibold))
                Text("\(next.event.room) · ") + Text(next.start, style: .relative)
            } else {
                Text(entry.quietReason ?? "Nothing left today")
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Helpers

    private var shortCode: String {
        let course = entry.current?.event.course ?? entry.next?.event.course ?? "—"
        return course.split(separator: " ").last.map(String.init) ?? course
    }

    private var nextDayHint: String? {
        guard let next = entry.next else { return nil }
        return "\(next.event.course) \(dayLabel(for: next.start).lowercased())"
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }

    private func color(for occurrence: ScheduleEngine.Occurrence) -> Color {
        entry.palette[occurrence.event.course] ?? Palette.rail
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Next" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

// MARK: - Medium + large: the rest of today

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.yourteam.bell.today", provider: ScheduleProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(Palette.ink.gradient, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Everything still ahead of you, with walking times between rooms.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ScheduleEntry

    /// The class the eye should land on first: what you're in, or what's next
    /// if it's still today. Tomorrow's first class doesn't get the big
    /// treatment — at 9pm that's not what you need shouting at you.
    private var featured: ScheduleEngine.Occurrence? {
        if let current = entry.current { return current }
        guard let next = entry.next,
              Calendar.current.isDate(next.start, inSameDayAs: entry.date)
        else { return nil }
        return next
    }

    private var listed: [ScheduleEngine.Occurrence] {
        entry.today.filter { $0.id != featured?.id }
    }

    private var rowLimit: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let reason = entry.quietReason {
                QuietState(headline: reason, detail: hint, symbol: "moon.zzz")
            } else if entry.today.isEmpty {
                QuietState(headline: "Nothing scheduled", detail: hint, symbol: "circle.dotted")
            } else if family == .systemLarge {
                largeBody
            } else {
                mediumBody
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.date, format: .dateTime.weekday(.wide))
                .font(.system(size: 15, weight: .semibold))
            Text(entry.date, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Spacer()

            if !entry.today.isEmpty {
                Text(dayProgress)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 9)
    }

    /// "2 of 5 done" reads faster than a count of what's left, and it's the
    /// number that tells you how much of the day is behind you.
    private var dayProgress: String {
        "\(entry.finished.count) of \(entry.today.count) done"
    }

    // MARK: Large
    //
    // The space breaks into three bands: the featured class, a hairline, then
    // the rest of the day. Finished classes stay in that list, dimmed, so the
    // widget reads as a day in progress rather than a shrinking to-do list.

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let featured {
                FeaturedClass(
                    occurrence: featured,
                    color: entry.palette[featured.event.course] ?? Palette.rail,
                    now: entry.date,
                    isLive: featured.status(at: entry.date) == .inProgress,
                    etaMinutes: featured.id == entry.next?.id ? entry.etaMinutes : nil,
                    leaveBy: featured.id == entry.next?.id ? entry.leaveBy : nil)
                .padding(.bottom, 11)

                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
                    .padding(.bottom, 9)
            }

            if listed.isEmpty {
                Text(featured == nil ? "Done for the day" : "Nothing else today")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(listed.prefix(rowLimit)) { occurrence in
                        ClassRow(
                            occurrence: occurrence,
                            color: entry.palette[occurrence.event.course] ?? Palette.rail,
                            now: entry.date,
                            isCompact: true)
                    }
                }
            }

            if listed.count > rowLimit {
                Text("+\(listed.count - rowLimit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            }

            Spacer(minLength: 6)

            footer
        }
    }

    /// One line that answers "when am I actually free". Worth the space
    /// because it's the question the grid above doesn't answer at a glance.
    @ViewBuilder private var footer: some View {
        if let last = entry.today.last, last.end > entry.date {
            HStack(spacing: 4) {
                Image(systemName: "moon")
                    .font(.system(size: 10))
                Text("Free from ")
                    + Text(last.end, format: .dateTime.hour().minute())
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .bellAccented()
        } else if let next = entry.next {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10))
                Text(nextDayLabel(for: next.start))
                Text(next.event.course).fontWeight(.medium)
                Text(next.start, format: .dateTime.hour().minute())
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .bellAccented()
        }
    }

    // MARK: Medium

    private var mediumBody: some View {
        VStack(spacing: 7) {
            ForEach(entry.upcoming.prefix(rowLimit)) { occurrence in
                ClassRow(
                    occurrence: occurrence,
                    color: entry.palette[occurrence.event.course] ?? Palette.rail,
                    now: entry.date,
                    isCompact: true)
            }

            if entry.upcoming.isEmpty {
                QuietState(headline: "Done for the day", detail: hint, symbol: "checkmark")
            }
        }
    }

    // MARK: Helpers

    private var hint: String? {
        guard let next = entry.next else { return nil }
        return "\(nextDayLabel(for: next.start))\(next.event.course) at "
            + next.start.formatted(.dateTime.hour().minute())
    }

    private func nextDayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow · " }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " · "
    }
}

// MARK: - Extra large: the week grid

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.yourteam.bell.week", provider: ScheduleProvider()) { entry in
            WeekGridView(entry: entry)
                .containerBackground(Palette.ink.gradient, for: .widget)
        }
        .configurationDisplayName("Week")
        .description("The whole week as a grid, with today's column marked.")
        .supportedFamilies([.systemExtraLarge])
    }
}

struct WeekGridView: View {
    var entry: ScheduleEntry

    private var engine: ScheduleEngine { ScheduleEngine(timetable: SharedStore.load()) }
    private var dayCount: Int { SharedStore.load().showsWeekends ? 7 : 5 }

    private var weekStart: Date {
        let calendar = Calendar.current
        let index = engine.mondayBasedIndex(for: entry.date)
        return calendar.date(byAdding: .day, value: -index,
                             to: calendar.startOfDay(for: entry.date)) ?? entry.date
    }

    /// Bounds of the grid, derived from the actual schedule rather than a fixed
    /// 8-to-6 so a 7:30 lecture isn't clipped off the top.
    private var bounds: (start: Int, end: Int) {
        let all = (0 ..< dayCount).flatMap { offset -> [ScheduleEngine.Occurrence] in
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: weekStart)
            else { return [] }
            return engine.occurrences(on: day)
        }
        let starts = all.map(\.event.startSecond)
        let ends = all.map(\.event.endSecond)
        return (starts.min() ?? 28800, ends.max() ?? 64800)
    }

    var body: some View {
        GeometryReader { geometry in
            let span = Double(bounds.end - bounds.start)
            let columnWidth = (geometry.size.width - 34) / Double(dayCount)
            let gridHeight = geometry.size.height - 22

            ZStack(alignment: .topLeading) {
                hourRules(height: gridHeight, width: geometry.size.width)

                ForEach(0 ..< dayCount, id: \.self) { offset in
                    let day = Calendar.current.date(byAdding: .day, value: offset, to: weekStart)!
                    let isToday = Calendar.current.isDateInToday(day)

                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 11, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                        .frame(width: columnWidth)
                        .offset(x: 34 + Double(offset) * columnWidth)

                    ForEach(engine.occurrences(on: day)) { occurrence in
                        block(occurrence, isToday: isToday)
                            .frame(
                                width: columnWidth - 3,
                                height: max(14, gridHeight * Double(occurrence.event.duration) / span))
                            .offset(
                                x: 34 + Double(offset) * columnWidth,
                                y: 22 + gridHeight
                                    * Double(occurrence.event.startSecond - bounds.start) / span)
                    }
                }
            }
        }
    }

    private func block(_ occurrence: ScheduleEngine.Occurrence, isToday: Bool) -> some View {
        let color = entry.palette[occurrence.event.course] ?? Palette.rail
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.opacity(isToday ? 0.95 : 0.55))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(occurrence.event.course)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text(occurrence.event.room)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .opacity(0.75)
                }
                .foregroundStyle(Palette.legibleForeground(on: color))
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
            .bellAccented()
    }

    private func hourRules(height: Double, width: Double) -> some View {
        let startHour = bounds.start / 3600
        let endHour = Int(ceil(Double(bounds.end) / 3600))
        let span = Double(bounds.end - bounds.start)

        return ForEach(startHour ... endHour, id: \.self) { hour in
            let y = 22 + height * Double(hour * 3600 - bounds.start) / span
            HStack(spacing: 4) {
                Text(hourLabel(hour))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
            }
            .offset(y: y)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return "\(normalized)\(hour < 12 ? "a" : "p")"
    }
}
