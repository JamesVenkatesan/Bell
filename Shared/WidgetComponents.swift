import SwiftUI
import WidgetKit

// MARK: - Tint survival
//
// Rules that keep the widget readable when the home screen is tinted:
//
//  1. No raster images. Tinting a PNG produces a gray blob. Everything here is
//     text, SF Symbols, and shapes.
//  2. Never encode meaning in hue alone. Course identity is carried by the
//     luminance step from Palette *and* by a shape/weight difference, so the
//     widget still parses in a single accent color.
//  3. Use `widgetAccentedRenderingMode` so symbols land in the accent group
//     rather than being flattened into the background.
//  4. Draw the background with `containerBackground`, which the system knows
//     how to recolor, instead of a hand-rolled ZStack fill that it doesn't.

extension View {
    /// Marks content as the accented group in tinted mode, so it keeps contrast
    /// against the tinted background instead of dissolving into it.
    func bellAccented() -> some View {
        widgetAccentable()
    }
}

/// A course color that quietly steps aside in tinted mode. In `.accented` the
/// system is going to recolor everything anyway, so we hand it luminance and
/// let it do the rest.
struct CourseSwatch: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var color: Color
    var height: CGFloat = 34
    var width: CGFloat = 3

    var body: some View {
        Capsule(style: .continuous)
            .fill(renderingMode == .fullColor ? color : Color.white.opacity(0.9))
            .frame(width: width, height: height)
            .bellAccented()
    }
}

/// Times, always tabular so the column doesn't jitter minute to minute.
struct TimeLabel: View {
    var date: Date
    var style: Style = .clock

    enum Style { case clock, relative }

    var body: some View {
        Group {
            switch style {
            case .clock:
                Text(date, format: .dateTime.hour().minute())
            case .relative:
                Text(date, style: .relative)
            }
        }
        .monospacedDigit()
    }
}

/// How loudly a row should speak.
///
/// Three levels, because a schedule answers three questions at once: what have
/// I done, what am I doing, what's coming. Finished classes stay on screen —
/// dropping them loses the sense of where you are in the day — but they recede
/// far enough that the eye skips past them.
enum RowEmphasis {
    case done
    case active
    case upcoming

    var opacity: Double {
        switch self {
        case .done: 0.34
        case .active: 1
        case .upcoming: 0.88
        }
    }

    var courseWeight: Font.Weight {
        switch self {
        case .done: .regular
        case .active: .semibold
        case .upcoming: .medium
        }
    }
}

/// One row of the schedule: rail, course, room, time.
struct ClassRow: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var occurrence: ScheduleEngine.Occurrence
    var color: Color
    var now: Date
    var isCompact: Bool = false
    /// Overrides the status-derived level.
    var emphasis: RowEmphasis?

    private var level: RowEmphasis {
        if let emphasis { return emphasis }
        switch occurrence.status(at: now) {
        case .finished: return .done
        case .inProgress: return .active
        case .upcoming: return .upcoming
        }
    }

    private var isLive: Bool { occurrence.status(at: now) == .inProgress }

    var body: some View {
        HStack(spacing: 9) {
            CourseSwatch(color: color, height: isCompact ? 22 : 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(occurrence.event.course)
                    .font(.system(size: isCompact ? 13 : 15, weight: level.courseWeight))
                    .lineLimit(1)
                    .strikethrough(level == .done, color: .secondary)

                if SharedStore.showsRoomNumbers, !occurrence.event.room.isEmpty {
                    Text(occurrence.event.room)
                        .font(.system(size: isCompact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                TimeLabel(date: occurrence.start)
                    .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                if !isCompact {
                    TimeLabel(date: occurrence.end)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(level.opacity)
    }
}

/// A single class given the full width — the one you're in, or the one you're
/// walking to. This is where the large widget spends its space, because it's
/// the only row you need to read from across a room.
struct FeaturedClass: View {
    var occurrence: ScheduleEngine.Occurrence
    var color: Color
    var now: Date
    var isLive: Bool
    var etaMinutes: Int?
    var leaveBy: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isLive ? "In class" : "Up next")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if isLive {
                    Text(timerInterval: now ... occurrence.end, countsDown: true)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                } else {
                    Text(occurrence.start, style: .relative)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
            }

            HStack(alignment: .center, spacing: 11) {
                CourseSwatch(color: color, height: 40, width: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(occurrence.event.course)
                        .font(.system(size: 23, weight: .semibold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if !occurrence.event.room.isEmpty {
                            Text(occurrence.event.room)
                        }
                        Text("·")
                        Text(occurrence.start, format: .dateTime.hour().minute())
                        Text("–")
                        Text(occurrence.end, format: .dateTime.hour().minute())
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let etaMinutes {
                    WalkBadge(minutes: etaMinutes)
                }
            }

            if isLive {
                ProgressRail(progress: occurrence.progress(at: now), color: color)
            } else if let leaveBy {
                LeaveNowBadge(leaveBy: leaveBy, walkNote: nil, now: now)
            }
        }
    }
}

/// Live distance, as a number you can act on rather than a map.
struct WalkBadge: View {
    var minutes: Int

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: minutes == 0 ? "checkmark.circle" : "figure.walk")
                .font(.system(size: 12, weight: .medium))
            if minutes > 0 {
                Text("\(minutes)")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                Text("min")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("here")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.top, 2)
            }
        }
        .frame(width: 44)
        .bellAccented()
    }
}

/// The thin line that tracks where you are in the current class. Reads as a
/// progress bar in full color and as a filled segment when tinted.
struct ProgressRail: View {
    var progress: Double
    var color: Color

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(renderingMode == .fullColor ? color : Color.white)
                    .frame(width: max(3, geometry.size.width * progress))
                    .bellAccented()
            }
        }
        .frame(height: 3)
    }
}

/// Shown on breaks, weekends, and after the last class. An empty schedule is
/// information, so it gets a real sentence rather than a blank card.
struct QuietState: View {
    var headline: String
    var detail: String?
    var symbol: String = "circle.dotted"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)
                .bellAccented()
            Text(headline)
                .font(.system(size: 15, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The leave-now banner. Appears only when the walk is actually at risk.
///
/// The countdown has to stop at zero rather than run negative. A widget entry
/// carries a frozen timestamp, but `Text(_:style:)` keeps ticking live against
/// the real clock — so once the deadline passes, a plain relative style starts
/// counting *up* while the entry still thinks there's time left.
///
/// `pauseTime` fixes it: the timer freezes at 00:00 instead of continuing.
/// The provider also emits a timeline entry at the exact leave-by moment, so
/// the text flips to "Leave now" the second it matters rather than at the next
/// scheduled refresh.
struct LeaveNowBadge: View {
    var leaveBy: Date
    var walkNote: String?
    var now: Date

    private var hasPassed: Bool { leaveBy <= now }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hasPassed ? "figure.walk.motion" : "figure.walk")
                .font(.system(size: 10, weight: .semibold))

            if hasPassed {
                Text("Leave now")
            } else {
                Text("Leave in")
                Text(timerInterval: now ... leaveBy,
                     pauseTime: leaveBy,
                     countsDown: true)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .leading)
                if let walkNote {
                    Text("· \(walkNote)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .bellAccented()
    }
}
