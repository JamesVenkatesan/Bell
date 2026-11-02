import SwiftUI

/// The day as a vertical strip at true scale.
///
/// All positions come from `DayLayout`; this view only draws. Four layers,
/// back to front: hour rules, gaps, classes, and the now hairline. The now
/// line is last so nothing can hide it, because "where am I in the day" is
/// the first thing the eye looks for.
struct DayTimeline: View {
    var layout: DayLayout
    var now: Date
    var palette: [String: Color]
    var hero: Namespace.ID
    /// The worst clash per class, keyed by occurrence id.
    var conflicts: [String: ConflictDetector.Conflict] = [:]
    /// What each free gap is good for, keyed by the gap's start.
    var suggestions: [Date: String] = [:]
    var open: (Route) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false

    /// Scroll target for landing on the current time.
    static let nowAnchor = "timeline-now"

    /// Room for "10 AM" in the data face, built from the spacing scale so it
    /// lines up with the gutter of everything above it.
    private let axisWidth = Bell.Space.section + Bell.Space.base

    var body: some View {
        GeometryReader { geometry in
            let trackX = axisWidth + Bell.Space.snug
            let trackWidth = max(0, geometry.size.width - trackX)

            ZStack(alignment: .topLeading) {
                hourRules(width: geometry.size.width)

                ForEach(layout.gaps) { gap in
                    GapMark(gap: gap, suggestion: suggestions[gap.start])
                        .frame(width: trackWidth, height: gap.height, alignment: .leading)
                        .offset(x: trackX, y: gap.y)
                }

                ForEach(layout.busyBlocks) { block in
                    let laneWidth = trackWidth / Double(block.laneCount)
                    BusyBlockView(event: block.event, height: block.height)
                        .frame(width: max(0, laneWidth - (block.laneCount > 1 ? Bell.Space.tight : 0)),
                               height: block.height)
                        .offset(x: trackX + laneWidth * Double(block.lane), y: block.y)
                        .opacity(hasArrived ? 1 : 0)
                        .animation(Bell.Motion.standard, value: hasArrived)
                }

                ForEach(Array(layout.blocks.enumerated()), id: \.element.id) { index, block in
                    let laneWidth = trackWidth / Double(block.laneCount)
                    blockButton(block)
                        .frame(width: max(0, laneWidth - (block.laneCount > 1 ? Bell.Space.tight : 0)),
                               height: block.height)
                        .offset(x: trackX + laneWidth * Double(block.lane), y: block.y)
                        .opacity(hasArrived ? 1 : 0)
                        .offset(y: hasArrived || reduceMotion ? 0 : Bell.Space.snug)
                        .animation(Bell.Motion.stagger(index: index), value: hasArrived)
                }

                nowLine(width: geometry.size.width)
            }
        }
        .frame(height: layout.height)
        .padding(.top, Bell.Space.base)
        .onAppear { hasArrived = true }
    }

    // MARK: - Layers

    private func hourRules(width: Double) -> some View {
        ForEach(layout.hourMarks(), id: \.self) { mark in
            let y = layout.y(for: mark)
            HStack(alignment: .center, spacing: Bell.Space.snug) {
                Text(mark, format: .dateTime.hour())
                    .font(Bell.Type_.data(11, weight: .regular))
                    .foregroundStyle(Bell.Content.tertiary)
                    .frame(width: axisWidth, alignment: .trailing)
                Rectangle()
                    .fill(Bell.Surface.hairline)
                    .frame(height: Bell.Stroke.hair)
            }
            .frame(width: width, height: 12)
            .offset(y: y - 6)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func nowLine(width: Double) -> some View {
        // Anchor sits at now when today is drawn, otherwise at the first
        // class, so landing on a future day starts at its first class.
        let anchorY = layout.nowY(at: now) ?? layout.blocks.first?.y ?? 0
        Color.clear
            .frame(width: 1, height: 1)
            .offset(y: anchorY)
            .id(Self.nowAnchor)

        if let y = layout.nowY(at: now) {
            HStack(spacing: 0) {
                Text(now, format: .dateTime.hour().minute())
                    .font(Bell.Type_.data(11, weight: .semibold))
                    .foregroundStyle(Bell.paper)
                    .padding(.horizontal, Bell.Space.tight + Bell.Space.hair)
                    .padding(.vertical, Bell.Space.hair)
                    .background(Capsule().fill(Bell.Signal.now))
                    .frame(width: axisWidth + Bell.Space.snug, alignment: .trailing)
                Rectangle()
                    .fill(Bell.Signal.now)
                    .frame(height: 2)
            }
            .frame(width: width, height: 20)
            .offset(y: y - 10)
            .animation(Bell.Motion.continuous, value: y)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Now, \(now.formatted(.dateTime.hour().minute()))")
        }
    }

    private func blockButton(_ block: DayLayout.Block) -> some View {
        let occurrence = block.occurrence
        let color = palette[occurrence.event.course] ?? Bell.Surface.scaffold

        return Button {
            Haptic.select.play()
            open(.course(code: occurrence.event.course, sourceID: occurrence.id))
        } label: {
            ClassBlock(occurrence: occurrence, color: color, now: now, height: block.height,
                       conflict: conflicts[occurrence.id])
        }
        .buttonStyle(.bellPress)
        // No background on the source: the class sits on the track, not in a
        // box, and the zoom morphs from exactly what's drawn.
        .matchedTransitionSource(id: HeroID.card(occurrence.id), in: hero)
    }
}

// MARK: - Class block

/// One class, sized by its duration.
///
/// The three-tier emphasis lives here as it does in the widget: finished
/// classes at 34% and struck through, the live one at full weight, the rest
/// at 88%. The live block also fills with its course colour as time passes,
/// so how far through the class you are reads without a number.
struct ClassBlock: View {
    var occurrence: ScheduleEngine.Occurrence
    var color: Color
    var now: Date
    var height: Double
    var conflict: ConflictDetector.Conflict? = nil

    private var status: ScheduleEngine.Occurrence.Status { occurrence.status(at: now) }
    private var level: RowEmphasis { RowEmphasis(status) }

    /// The track: one column, the width of a thumb's edge, that every class,
    /// gap and other event sits on. Flighty's lesson: a day that looks like a
    /// physical line you travel along reads faster than a stack of boxes.
    static let trackWidth: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)

        HStack(alignment: .top, spacing: Bell.Space.base) {
            // The class itself, as a solid segment of the track in its
            // colour. The live one shows how far through you are: the part
            // already gone fades back.
            ZStack(alignment: .top) {
                shape.fill(color)
                if status == .inProgress {
                    shape.fill(Bell.Surface.canvas.opacity(0.55))
                        .frame(height: max(0, height * occurrence.progress(at: now)))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .animation(Bell.Motion.continuous, value: occurrence.progress(at: now))
                }
            }
            .frame(width: Self.trackWidth)

            VStack(alignment: .leading, spacing: Bell.Space.hair) {
                HStack(alignment: .firstTextBaseline) {
                    Text(occurrence.event.course)
                        .font(height >= 44 ? Bell.Type_.title : Bell.Type_.headline)
                        .fontWeight(level.courseWeight == .regular ? .regular : .semibold)
                        .strikethrough(level.isStruck, color: Bell.Content.secondary)
                        .foregroundStyle(Bell.Content.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Bell.Space.snug)
                    if status == .inProgress {
                        Text(timerInterval: now ... occurrence.end, countsDown: true)
                            .font(Bell.Type_.data(15, weight: .semibold))
                            .foregroundStyle(Bell.Signal.now)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64, alignment: .trailing)
                    }
                    if let conflict, status != .finished {
                        Image(systemName: conflict.kind.isOverlap ? "exclamationmark.2" : "figure.walk.motion")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Bell.Signal.conflict)
                            .transition(.bellCard)
                    }
                }

                if height >= 44, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.secondary)
                        .lineLimit(1)
                }
                if height >= 72 {
                    Text("\(occurrence.start, format: .dateTime.hour().minute())–\(occurrence.end, format: .dateTime.hour().minute())")
                        .font(Bell.Type_.data(13, weight: .regular))
                        .foregroundStyle(Bell.Content.secondary)
                }
            }
            .padding(.top, Bell.Space.hair)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .opacity(level.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the course")
    }

    private var subtitle: String {
        [occurrence.event.room, occurrence.event.instructor ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var accessibilityText: String {
        let time = occurrence.start.formatted(.dateTime.hour().minute())
        let prefix: String = switch status {
        case .finished: "Finished. "
        case .inProgress: "In progress. "
        case .upcoming: ""
        }
        let clash = conflict.map { ". Clashes with \($0.event.title)" } ?? ""
        return "\(prefix)\(occurrence.event.course), \(time), \(occurrence.event.room)\(clash)"
    }
}

// MARK: - Other calendars

/// An event from another calendar. Drawn as an outline rather than a filled
/// card, so it reads as "time that's taken" without competing with classes,
/// which are Bell's subject. No course colour: it isn't a course.
private struct BusyBlockView: View {
    var event: ExternalEvent
    var height: Double

    var body: some View {
        HStack(alignment: .top, spacing: Bell.Space.base) {
            // Hollow, on the same track: time that's taken, by something
            // that isn't a class.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Bell.Content.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: ClassBlock.trackWidth)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(Bell.Type_.headline.weight(.regular))
                    .foregroundStyle(Bell.Content.secondary)
                    .lineLimit(1)
                if height >= 40 {
                    Text(event.location.map { "\($0) · \(event.calendarTitle)" } ?? event.calendarTitle)
                        .font(Bell.Type_.caption)
                        .foregroundStyle(Bell.Content.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), from \(event.calendarTitle), "
                            + event.start.formatted(.dateTime.hour().minute()))
    }
}

// MARK: - Gaps

/// The space between classes, labelled by what it means rather than by its
/// length alone: a tight change is a warning, a long gap is free time, and a
/// short walk between rooms is barely mentioned.
private struct GapMark: View {
    var gap: DayLayout.Gap
    var suggestion: String?

    var body: some View {
        HStack(spacing: Bell.Space.base) {
            rail
                .frame(width: ClassBlock.trackWidth)
                .padding(.vertical, Bell.Space.hair)

            if gap.height >= 18 {
                label
                    .font(Bell.Type_.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rail: some View {
        switch gap.kind {
        case .tight:
            // The one gap in the signal colour: it's a thing to act on.
            RoundedRectangle(cornerRadius: 3).fill(Bell.Signal.urgent)
        case .free:
            // Empty track: there, and unoccupied.
            RoundedRectangle(cornerRadius: 3).fill(Bell.Surface.sunken)
        case .change:
            RoundedRectangle(cornerRadius: 3).fill(Bell.Surface.sunken.opacity(0.5))
        }
    }

    @ViewBuilder
    private var label: some View {
        switch gap.kind {
        case .tight:
            Label {
                Text("\(duration) gap, \(gap.walkMinutes ?? 0) min walk")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Bell.Signal.urgent)
        case .free:
            // The suggestion rides on the free label rather than getting a
            // row of its own: it's about this gap, and should read that way.
            Text(suggestion.map { "\(duration) free · \($0)" } ?? "\(duration) free")
                .foregroundStyle(Bell.Content.secondary)
        case .change:
            Text(gap.walkMinutes.map { "\(duration) · \($0) min walk" } ?? duration)
                .foregroundStyle(Bell.Content.tertiary)
        }
    }

    private var duration: String {
        let hours = gap.minutes / 60
        let minutes = gap.minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) h" }
        return "\(hours) h \(minutes) min"
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
