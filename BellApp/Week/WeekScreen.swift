import SwiftUI

/// The week as a grid you can handle.
///
/// Pinch changes the scale of the hours, anchored on the fingers. Press and
/// hold, then drag, to scrub: a glass readout follows and names the class
/// under your finger, or how long you're free. Tapping a class zooms into its
/// course page, the same hero as from the day view.
///
/// The scrub needs a press first because the grid sits in a vertical scroll.
/// An immediate drag would steal every scroll; a hold is the system's own
/// convention (Stocks, Weather) for "I want to inspect, not move".
struct WeekScreen: View {
    var hero: Namespace.ID
    var open: (Route) -> Void

    @Environment(BellStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var weekOffset = 0
    @State private var travel: Edge = .trailing

    @State private var pointsPerHour = WeekGridGeometry.defaultPointsPerHour
    @State private var pinch: Pinch?

    @State private var position = ScrollPosition(edge: .top)
    @State private var scrollOffset: Double = 0

    @State private var scrub: Scrub?
    /// Set while a scrub is live and briefly after, so the touch that ends a
    /// scrub over a class doesn't also count as a tap and open it.
    @State private var suppressTap = false

    private struct Pinch {
        var baseScale: Double
        var focusY: Double
        var offsetAtStart: Double
        var geometryAtStart: WeekGridGeometry
    }

    private struct Scrub: Equatable {
        var day: Int
        var second: Int
        var reading: WeekGridGeometry.Reading

        /// Changes only when the scrub crosses something worth feeling: a
        /// day boundary, or into or out of a class. Ticking every five
        /// minutes would turn the haptic into noise.
        var hapticKey: String {
            switch reading {
            case .inClass(let event): "\(day)-\(event.id)"
            case .free: "\(day)-free"
            }
        }
    }

    private var calendar: Calendar { store.engine.calendar }
    private var dayCount: Int { store.timetable.showsWeekends ? 7 : 5 }
    private let axisWidth = Bell.Space.section

    private var weekStart: Date {
        let today = calendar.startOfDay(for: .now)
        let index = store.engine.mondayBasedIndex(for: today)
        let monday = calendar.date(byAdding: .day, value: -index, to: today) ?? today
        return calendar.date(byAdding: .weekOfYear, value: weekOffset, to: monday) ?? monday
    }

    private var days: [Date] {
        (0 ..< dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// This week's real meetings, with breaks and term bounds applied, as
    /// events whose `dayIndex` is the column they sit in.
    private var occurrencesByDay: [[ScheduleEngine.Occurrence]] {
        let hidden = Preferences.hiddenCourses
        return days.map { store.engine.occurrences(on: $0).filter { !hidden.contains($0.event.course) } }
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(0, proxy.size.width - Bell.Space.gutter * 2 - axisWidth)
            // Bounds from the whole timetable, not this week, so paging to a
            // week with a break doesn't rescale the grid under you.
            let geometry = WeekGridGeometry(events: store.timetable.events,
                                            dayCount: dayCount,
                                            pointsPerHour: pointsPerHour,
                                            columnsWidth: columns)
            let byDay = occurrencesByDay

            ScrollView(.vertical) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    grid(geometry: geometry, byDay: byDay, now: context.date)
                }
                .padding(.horizontal, Bell.Space.gutter)
                .padding(.top, Bell.Space.base)
                .padding(.bottom, Bell.Space.section)
                .id(weekOffset)
                .transition(reduceMotion ? .opacity : .push(from: travel))
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, y in
                scrollOffset = y
            }
            .scrollDisabled(scrub != nil)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                header(geometry: geometry)
            }
            .overlay(alignment: .top) {
                if let scrub {
                    ScrubReadout(day: days[safe: scrub.day] ?? weekStart,
                                 second: scrub.second,
                                 reading: scrub.reading)
                        .padding(.top, 76)
                        .transition(.bellCard)
                }
            }
            .animation(Bell.Motion.snap, value: scrub != nil)
        }
        .background(Bell.Surface.canvas)
        .navigationTitle(weekTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .haptic(.tick, on: scrub?.hapticKey)
    }

    // MARK: - Grid

    private func grid(geometry: WeekGridGeometry,
                      byDay: [[ScheduleEngine.Occurrence]],
                      now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            hourRules(geometry: geometry)

            if let todayColumn = days.firstIndex(where: { calendar.isDateInToday($0) }) {
                RoundedRectangle(cornerRadius: Bell.Radius.small, style: .continuous)
                    .fill(Bell.Surface.raised.opacity(0.6))
                    .frame(width: geometry.columnWidth, height: geometry.height)
                    .offset(x: axisWidth + geometry.x(forDay: todayColumn))
            }

            ForEach(Array(byDay.enumerated()), id: \.offset) { column, occurrences in
                ForEach(occurrences) { occurrence in
                    block(occurrence, column: column, geometry: geometry, now: now)
                }
            }

            nowLine(geometry: geometry, now: now)

            if let scrub {
                scrubGuide(scrub, geometry: geometry)
            }
        }
        .frame(width: axisWidth + geometry.columnsWidth, height: geometry.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrubGesture(geometry: geometry, byDay: byDay))
        .simultaneousGesture(pinchGesture(geometry: geometry))
    }

    private func hourRules(geometry: WeekGridGeometry) -> some View {
        ForEach(geometry.hours, id: \.self) { hour in
            HStack(spacing: 0) {
                Text(hourLabel(hour))
                    .font(Bell.Type_.data(10, weight: .regular))
                    .foregroundStyle(Bell.Content.tertiary)
                    .frame(width: axisWidth - Bell.Space.tight, alignment: .trailing)
                    .padding(.trailing, Bell.Space.tight)
                Rectangle()
                    .fill(Bell.Surface.hairline)
                    .frame(height: Bell.Stroke.hair)
            }
            .frame(height: 12)
            .offset(y: geometry.y(forSecond: hour * 3600) - 6)
            .accessibilityHidden(true)
        }
    }

    private func block(_ occurrence: ScheduleEngine.Occurrence,
                       column: Int,
                       geometry: WeekGridGeometry,
                       now: Date) -> some View {
        var placed = occurrence.event
        placed.dayIndex = column
        let frame = geometry.frame(for: placed)
        let color = store.palette[occurrence.event.course] ?? Bell.Surface.scaffold
        let sourceID = "week-\(occurrence.id)"

        return WeekBlock(occurrence: occurrence, color: color, now: now, height: frame.height)
            .frame(width: max(0, frame.width - Bell.Space.hair), height: max(0, frame.height - Bell.Space.hair))
            .matchedTransitionSource(id: HeroID.card(sourceID), in: hero) { source in
                source.clipShape(RoundedRectangle(cornerRadius: Bell.Radius.small, style: .continuous))
            }
            .onTapGesture {
                guard !suppressTap else { return }
                Haptic.select.play()
                open(.course(code: occurrence.event.course, sourceID: sourceID))
            }
            .offset(x: axisWidth + frame.x + Bell.Space.hair / 2, y: frame.y)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func nowLine(geometry: WeekGridGeometry, now: Date) -> some View {
        if let column = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
            let second = Int(now.timeIntervalSince(calendar.startOfDay(for: now)))
            if second >= geometry.startSecond, second <= geometry.endSecond {
                HStack(spacing: 0) {
                    Circle()
                        .fill(Bell.Content.primary)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(Bell.Content.primary)
                        .frame(height: 1.5)
                }
                .frame(width: geometry.columnWidth + 3.5, height: 7)
                .offset(x: axisWidth + geometry.x(forDay: column) - 3.5,
                        y: geometry.y(forSecond: second) - 3.5)
                .animation(Bell.Motion.continuous, value: second)
                .allowsHitTesting(false)
            }
        }
    }

    private func scrubGuide(_ scrub: Scrub, geometry: WeekGridGeometry) -> some View {
        let y = geometry.y(forSecond: scrub.second)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Bell.Radius.small, style: .continuous)
                .strokeBorder(Bell.Content.secondary, lineWidth: 1)
                .frame(width: geometry.columnWidth, height: geometry.height)
                .offset(x: axisWidth + geometry.x(forDay: scrub.day))
            Rectangle()
                .fill(Bell.Content.primary)
                .frame(width: geometry.columnsWidth, height: 1)
                .offset(x: axisWidth, y: y)
        }
        .allowsHitTesting(false)
        .animation(Bell.Motion.snap, value: scrub)
    }

    // MARK: - Header

    /// Weekday names float on glass above the grid, because the grid scrolls
    /// beneath them and the columns need their labels at every scroll offset.
    private func header(geometry: WeekGridGeometry) -> some View {
        HStack(spacing: 0) {
            // A spacer with a fixed height: Color.clear takes all the height
            // it's offered, and stretched the glass header down the screen.
            Spacer().frame(width: axisWidth, height: 0)
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 0) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(Bell.Type_.micro)
                        .foregroundStyle(isToday ? Bell.Content.primary : Bell.Content.tertiary)
                    Text(day, format: .dateTime.day())
                        .font(Bell.Type_.data(15, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Bell.Surface.canvas : Bell.Content.primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if isToday { Circle().fill(Bell.Content.primary) }
                        }
                }
                .frame(width: geometry.columnWidth)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Bell.Space.snug)
        // Inner and outer padding sum to the gutter, so the columns line up
        // with the grid below and the glass stays inside the screen.
        .padding(.horizontal, Bell.Space.gutter - Bell.Space.tight)
        .glassEffect(Bell.Material_.floating, in: .rect(cornerRadius: Bell.Radius.large))
        .padding(.horizontal, Bell.Space.tight)
        .id(weekOffset)
        .transition(.opacity)
    }

    // MARK: - Gestures

    private func pinchGesture(geometry: WeekGridGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil {
                    pinch = Pinch(baseScale: pointsPerHour,
                                  focusY: value.startLocation.y,
                                  offsetAtStart: scrollOffset,
                                  geometryAtStart: geometry)
                }
                guard let pinch else { return }
                let scale = WeekGridGeometry.zoom(from: pinch.baseScale,
                                                  magnification: value.magnification)
                var next = pinch.geometryAtStart
                next.pointsPerHour = scale
                let offset = WeekGridGeometry.anchoredOffset(focusY: pinch.focusY,
                                                             offsetAtStart: pinch.offsetAtStart,
                                                             from: pinch.geometryAtStart,
                                                             to: next)
                // No animation: a pinch is direct manipulation, and anything
                // that lags the fingers breaks the illusion of holding it.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pointsPerHour = scale
                    position.scrollTo(y: offset)
                }
            }
            .onEnded { _ in pinch = nil }
    }

    private func scrubGesture(geometry: WeekGridGeometry,
                              byDay: [[ScheduleEngine.Occurrence]]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    suppressTap = true
                case .second(true, let drag?):
                    let x = drag.location.x - axisWidth
                    let day = geometry.day(atX: x)
                    let second = geometry.second(atY: drag.location.y)
                    let events = byDay.enumerated().flatMap { column, occurrences in
                        occurrences.map { occurrence -> ClassEvent in
                            var event = occurrence.event
                            event.dayIndex = column
                            return event
                        }
                    }
                    let reading = WeekGridGeometry.reading(day: day, second: second, events: events)
                    let next = Scrub(day: day, second: second, reading: reading)
                    if scrub == nil { Haptic.select.play() }
                    scrub = next
                default:
                    break
                }
            }
            .onEnded { _ in
                scrub = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    suppressTap = false
                }
            }
    }

    // MARK: - Chrome

    private var weekTitle: String {
        guard let last = days.last else { return "Week" }
        if weekOffset == 0 { return "This week" }
        return "\(weekStart.formatted(.dateTime.month(.abbreviated).day()))–"
            + last.formatted(.dateTime.day())
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { page(-1) } label: { Label("Previous week", systemImage: "chevron.left") }
            if weekOffset != 0 {
                Button("Now") { page(-weekOffset) }
            }
            Button { page(1) } label: { Label("Next week", systemImage: "chevron.right") }
        }
    }

    private func page(_ delta: Int) {
        guard delta != 0 else { return }
        travel = delta > 0 ? .trailing : .leading
        withAnimation(Bell.Motion.standard) { weekOffset += delta }
        Haptic.tick.play()
    }

    private func hourLabel(_ hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return "\(normalized)\(hour < 12 || hour == 24 ? "a" : "p")"
    }
}

// MARK: - Block

/// A class in the grid. Filled with its course colour because at this size
/// the fill is the identity; text picks ink or paper by luminance so it stays
/// legible on every step of the ramp.
private struct WeekBlock: View {
    var occurrence: ScheduleEngine.Occurrence
    var color: Color
    var now: Date
    var height: Double

    var body: some View {
        let level = RowEmphasis(occurrence.status(at: now))
        let ink = Bell.legibleOn(color)

        RoundedRectangle(cornerRadius: Bell.Radius.small, style: .continuous)
            .fill(color)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(shortCode)
                        .font(Bell.Type_.micro.weight(level.courseWeight))
                        .strikethrough(level.isStruck)
                        .lineLimit(1)
                    if height >= 34 {
                        Text(occurrence.event.room)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(ink)
                .padding(.horizontal, Bell.Space.tight)
                .padding(.top, Bell.Space.hair + 1)
            }
            .opacity(level.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(occurrence.event.course), "
                                + occurrence.start.formatted(.dateTime.weekday(.wide).hour().minute())
                                + ", \(occurrence.event.room)")
    }

    /// "30200" rather than "ECE 30200": a fifth of a phone's width can't
    /// hold the subject, and within one student's week the number is unique.
    private var shortCode: String {
        occurrence.event.course.split(separator: " ").last.map(String.init) ?? occurrence.event.course
    }
}

// MARK: - Scrub readout

private struct ScrubReadout: View {
    var day: Date
    var second: Int
    var reading: WeekGridGeometry.Reading

    var body: some View {
        HStack(spacing: Bell.Space.snug) {
            Text("\(day, format: .dateTime.weekday(.abbreviated)) \(clock(second))")
                .font(Bell.Type_.data(13, weight: .semibold))
                .foregroundStyle(Bell.Content.primary)

            Rectangle()
                .fill(Bell.Content.tertiary)
                .frame(width: Bell.Stroke.hair, height: 14)

            switch reading {
            case .inClass(let event):
                Text("\(event.course)\(event.room.isEmpty ? "" : " · \(event.room)")")
                    .font(Bell.Type_.caption.weight(.medium))
                    .foregroundStyle(Bell.Content.primary)
            case .free(let until):
                Text(until.map { "Free until \(clock($0))" } ?? "Free for the rest of the day")
                    .font(Bell.Type_.caption)
                    .foregroundStyle(Bell.Content.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, Bell.Space.roomy)
        .padding(.vertical, Bell.Space.snug + Bell.Space.hair)
        .glassEffect(Bell.Material_.floating, in: .capsule)
        .contentTransition(.numericText())
        .animation(Bell.Motion.snap, value: second)
    }

    private func clock(_ seconds: Int) -> String {
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        let display = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", display, minute, hour < 12 || hour == 24 ? "AM" : "PM")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
