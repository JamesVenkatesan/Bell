import Foundation

/// Coordinates for the interactive week grid.
///
/// The grid supports pinch-to-zoom and drag-to-scrub, and both are mostly
/// arithmetic: a zoom is a clamped scale, a scrub is a point turned back into
/// a day and a time. That arithmetic lives here, away from gesture code, so a
/// finger at the bottom edge resolving to "Saturday 25:10" is a failing test
/// rather than something noticed on device.
struct WeekGridGeometry: Equatable {

    var dayCount: Int
    /// Seconds since midnight at the top and bottom of the grid.
    var startSecond: Int
    var endSecond: Int
    var pointsPerHour: Double
    /// Width available for day columns, after the hour gutter.
    var columnsWidth: Double

    // MARK: - Zoom limits
    //
    // The floor fits a typical eight-to-six day on one phone screen; the
    // ceiling makes a fifty-minute class tall enough to read three lines.
    static let minPointsPerHour: Double = 36
    static let maxPointsPerHour: Double = 160
    static let defaultPointsPerHour: Double = 64

    /// Scrubbing snaps to this, because "10:17" is false precision for a
    /// question that's really "what's on around ten".
    static let scrubSnapSeconds = 5 * 60

    // MARK: - Building

    /// Bounds come from the schedule rather than a fixed eight-to-six, so a
    /// 7:30 lecture isn't clipped off the top.
    init(events: [ClassEvent],
         dayCount: Int,
         pointsPerHour: Double = WeekGridGeometry.defaultPointsPerHour,
         columnsWidth: Double) {
        let visible = events.filter { $0.dayIndex < dayCount }
        let earliest = visible.map(\.startSecond).min() ?? 8 * 3600
        let latest = visible.map(\.endSecond).max() ?? 18 * 3600

        self.dayCount = max(1, dayCount)
        self.startSecond = (earliest / 3600) * 3600
        self.endSecond = min(24 * 3600, Int((Double(latest) / 3600).rounded(.up)) * 3600)
        self.pointsPerHour = Self.clampZoom(pointsPerHour)
        self.columnsWidth = max(0, columnsWidth)
    }

    // MARK: - Size

    var columnWidth: Double { columnsWidth / Double(dayCount) }

    var height: Double { Double(endSecond - startSecond) / 3600 * pointsPerHour }

    var hours: [Int] { Array(startSecond / 3600 ... endSecond / 3600) }

    func y(forSecond second: Int) -> Double {
        Double(second - startSecond) / 3600 * pointsPerHour
    }

    func x(forDay day: Int) -> Double { Double(day) * columnWidth }

    /// Frame of one meeting, relative to the columns' origin.
    func frame(for event: ClassEvent) -> (x: Double, y: Double, width: Double, height: Double) {
        (x(forDay: event.dayIndex),
         y(forSecond: event.startSecond),
         columnWidth,
         Double(event.duration) / 3600 * pointsPerHour)
    }

    // MARK: - Zoom

    static func clampZoom(_ value: Double) -> Double {
        min(maxPointsPerHour, max(minPointsPerHour, value))
    }

    /// The scale a pinch arrives at. Multiplies the scale the pinch *began*
    /// with, not the current one: compounding on every gesture update makes
    /// zoom accelerate away from the fingers.
    static func zoom(from base: Double, magnification: Double) -> Double {
        clampZoom(base * magnification)
    }

    /// The scroll offset that keeps the moment under the fingers still while
    /// the scale changes.
    ///
    /// Without this, zooming scales about the top of the grid: pinch on the
    /// afternoon and the afternoon slides off the bottom of the screen, so
    /// you zoom into the thing you weren't looking at.
    ///
    /// - Parameters:
    ///   - focusY: where the pinch began, in content coordinates of `old`.
    ///   - offsetAtStart: the scroll offset when the pinch began.
    static func anchoredOffset(focusY: Double,
                               offsetAtStart: Double,
                               from old: WeekGridGeometry,
                               to new: WeekGridGeometry) -> Double {
        let focusSecond = old.unsnappedSecond(atY: focusY)
        let onScreen = focusY - offsetAtStart
        return max(0, new.y(forSecond: focusSecond) - onScreen)
    }

    private func unsnappedSecond(atY y: Double) -> Double {
        Double(startSecond) + y / pointsPerHour * 3600
    }

    private func y(forSecond second: Double) -> Double {
        (second - Double(startSecond)) / 3600 * pointsPerHour
    }

    // MARK: - Scrub

    func day(atX x: Double) -> Int {
        guard columnWidth > 0 else { return 0 }
        return min(dayCount - 1, max(0, Int(x / columnWidth)))
    }

    /// Clamped to the grid and snapped, so the readout never names a time
    /// outside what's drawn.
    func second(atY y: Double) -> Int {
        let raw = Double(startSecond) + y / pointsPerHour * 3600
        let snap = Double(Self.scrubSnapSeconds)
        let snapped = Int((raw / snap).rounded()) * Self.scrubSnapSeconds
        return min(endSecond, max(startSecond, snapped))
    }

    /// What the scrubber is pointing at.
    enum Reading: Equatable {
        case inClass(ClassEvent)
        /// Free, with when the next class that day starts (nil when nothing
        /// is left that day).
        case free(untilSecond: Int?)
    }

    static func reading(day: Int, second: Int, events: [ClassEvent]) -> Reading {
        let today = events.filter { $0.dayIndex == day }.sorted { $0.startSecond < $1.startSecond }
        if let hit = today.first(where: { $0.startSecond <= second && second < $0.endSecond }) {
            return .inClass(hit)
        }
        return .free(untilSecond: today.first(where: { $0.startSecond > second })?.startSecond)
    }
}
