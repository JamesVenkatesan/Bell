import SwiftUI

/// The hero: the minutes until the next bell, on a slab of the course's
/// colour that sinks as the time runs out.
///
/// This is the one loud thing in Bell, and the only place Compressed Black
/// appears. It carries one fact, so it can afford to be expressive.
///
/// The level is literal. The colour fills the slab from the bottom to a
/// height proportional to the time left, and the content is drawn twice:
/// in ink above the level and in the course's legible ink below it, masked
/// at the line. As the colour sinks the numerals visibly change colour where
/// the level crosses them, which is what makes it read as a level and not a
/// progress bar, and keeps every part of the text at full contrast.
struct BellSlab: View {
    var bell: NextBell?
    var tomorrow: ScheduleEngine.Occurrence?
    var color: Color
    var now: Date
    var hero: Namespace.ID
    var open: (Route) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rings = 0

    var body: some View {
        GeometryReader { geometry in
            let level = bell?.remainingFraction(at: now) ?? 0
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                if bell == nil {
                    // No bell left today, so no course to colour the slab
                    // with: it shows the sky instead, sunset or moon.
                    SkyScene(now: now)
                        .transition(.opacity)
                    content(width: geometry.size.width)
                        .foregroundStyle(Bell.paper)
                        // The date line sits on sky, which can be pale in
                        // the afternoon; a soft shadow keeps it legible
                        // without a box.
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                } else {
                    // The drained part is a wash of the same colour rather
                    // than grey, so the slab keeps its course's identity all
                    // the way down. Pale enough that ink stays above 4.5:1.
                    Bell.Surface.canvas
                    color.opacity(0.22)
                    color.frame(height: height * level)
                        .animation(reduceMotion ? nil : Bell.Motion.continuous, value: level)

                    content(width: geometry.size.width)
                        .foregroundStyle(Bell.Content.primary)

                    content(width: geometry.size.width)
                        .foregroundStyle(Bell.legibleOn(color))
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: height * level)
                                .animation(reduceMotion ? nil : Bell.Motion.continuous, value: level)
                        }
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : Bell.Motion.standard, value: bell == nil)
            .keyframeAnimator(initialValue: 0.0, trigger: rings) { view, swing in
                view.offset(x: swing)
            } keyframes: { _ in
                // The ring: three damped swings, quickest first, the way a
                // struck bell settles. Only at a transition, never idly.
                SpringKeyframe(-14, duration: 0.09)
                SpringKeyframe(10, duration: 0.11)
                SpringKeyframe(-6, duration: 0.12)
                SpringKeyframe(3, duration: 0.12)
                SpringKeyframe(0, duration: 0.2)
            }
        }
        // About two fifths of the screen, so the first class is still
        // visible beneath it; shorter on small phones.
        .containerRelativeFrame(.vertical) { length, _ in min(340, max(270, length * 0.42)) }
        .clipShape(.rect(cornerRadius: Bell.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let bell else { return }
            Haptic.select.play()
            open(.course(code: bell.occurrence.event.course, sourceID: "bell-\(bell.occurrence.id)"))
        }
        .matchedTransitionSource(id: HeroID.card("bell-\(bell?.occurrence.id ?? "none")"), in: hero)
        .onChange(of: bell?.at) { old, new in
            // A different bell while the app is open: the moment of character.
            guard old != nil, new != old else { return }
            Haptic.confirm.play()
            if !reduceMotion { rings += 1 }
        }
        .animation(Bell.Motion.standard, value: color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(bell == nil ? [] : .isButton)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(Bell.Type_.caption)
                .padding(.top, Bell.Space.snug)

            Spacer(minLength: 0)

            if let bell {
                let number = BellNumber.format(bell.at.timeIntervalSince(now))
                HStack(alignment: .firstTextBaseline, spacing: Bell.Space.snug) {
                    Text(number.value)
                        .font(Bell.Type_.bell(width < 380 ? 104 : 132))
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Bell.Motion.standard, value: number.value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(number.unit)
                        .font(Bell.Type_.title)
                }
                Text(bell.caption)
                    .font(Bell.Type_.title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(detail(bell))
                    .font(Bell.Type_.caption)
                    .monospacedDigit()
                    .padding(.top, Bell.Space.tight)
                    .padding(.bottom, Bell.Space.loose)
            } else {
                Text("Done for today")
                    .font(Bell.Type_.display)
                if let tomorrow {
                    Text("\(tomorrow.event.course) at \(tomorrow.start.formatted(.dateTime.hour().minute())) \(dayWord(tomorrow.start))")
                        .font(Bell.Type_.title)
                        .padding(.bottom, Bell.Space.loose)
                } else {
                    Text("Nothing else in the next three weeks.")
                        .font(Bell.Type_.caption)
                        .padding(.bottom, Bell.Space.loose)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, Bell.Space.gutter + Bell.Space.tight)
    }

    private func detail(_ bell: NextBell) -> String {
        var parts: [String] = []
        let event = bell.occurrence.event
        if !event.room.isEmpty { parts.append(event.room) }
        parts.append("\(bell.occurrence.start.formatted(.dateTime.hour().minute()))–\(bell.occurrence.end.formatted(.dateTime.hour().minute()))")
        if let walk = bell.walkMinutes { parts.append("\(walk) min walk") }
        return parts.joined(separator: " · ")
    }

    private func dayWord(_ date: Date) -> String {
        Calendar.current.isDateInTomorrow(date) ? "tomorrow" : date.formatted(.dateTime.weekday(.wide))
    }

    private var accessibilityText: String {
        guard let bell else { return "Done for today" }
        return "\(BellNumber.spoken(bell.at.timeIntervalSince(now))) \(bell.caption). \(detail(bell))"
    }
}

/// The hero once it has scrolled away: one line on glass, because the
/// timeline really does pass under it.
struct BellBar: View {
    var bell: NextBell
    var color: Color
    var now: Date

    var body: some View {
        let number = BellNumber.format(bell.at.timeIntervalSince(now))
        HStack(spacing: Bell.Space.snug) {
            RoundedRectangle(cornerRadius: Bell.Radius.small, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 22)
            Text("\(number.value) \(number.unit)")
                .font(Bell.Type_.bell(22))
                .contentTransition(.numericText(countsDown: true))
            Text(bell.caption)
                .font(Bell.Type_.caption)
                .foregroundStyle(Bell.Content.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Bell.Content.primary)
        .padding(.horizontal, Bell.Space.roomy)
        .padding(.vertical, Bell.Space.snug + Bell.Space.hair)
        .glassEffect(Bell.Material_.floating, in: .capsule)
        .padding(.horizontal, Bell.Space.gutter)
        .accessibilityElement(children: .combine)
    }
}
