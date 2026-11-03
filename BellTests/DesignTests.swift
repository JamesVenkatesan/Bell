import SwiftUI
import XCTest
@testable import Bell

// The redesign's claims, checked. The palette's numbers are the ones written
// in Design/PLAN.md; if someone retunes a colour by eye, these say so.

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}

private func lstar(_ y: Double) -> Double { y > 0.008856 ? 116 * pow(y, 1.0 / 3) - 16 : 903.3 * y }

final class RampTests: XCTestCase {

    /// Evenly spaced in perceived lightness, not just ordered: 92 down to 29
    /// in sevens. Evenness is what keeps any two courses apart when tinted.
    func testRampIsEvenlySpacedInLightness() {
        let l = Palette.steps.map { lstar(Palette.relativeLuminance($0)) }
        for (index, value) in l.enumerated() {
            XCTAssertEqual(value, 92 - Double(index) * 7, accuracy: 0.6, "\(Palette.stepNames[index])")
        }
    }

    /// Every step, not just the ones a given term happens to use.
    func testEveryStepIsSeparableWhenTinted() {
        let y = Palette.steps.map(Palette.relativeLuminance)
        for (a, b) in zip(y, y.dropFirst()) {
            XCTAssertGreaterThan(a - b, 0.02)
        }
    }

    func testTextOnEveryStepIsReadable() {
        for (index, color) in Palette.steps.enumerated() {
            let ratio = Bell.contrast(Palette.relativeLuminance(color),
                                      Palette.relativeLuminance(Bell.legibleOn(color)))
            XCTAssertGreaterThanOrEqual(ratio, 4.45, Palette.stepNames[index])
        }
    }

    /// Six courses used to take the first six steps, all light ones.
    func testCoursesSpreadAcrossTheWholeRamp() {
        XCTAssertEqual(Palette.spread(6), [0, 2, 4, 5, 7, 9])
        XCTAssertEqual(Palette.spread(2), [0, 9])
        XCTAssertEqual(Palette.spread(1), [0])
        XCTAssertEqual(Set(Palette.spread(10)).count, 10)
    }

    func testMoreCoursesThanStepsStillGetColours() {
        let courses = (0 ..< 13).map { "C \($0)00" }
        XCTAssertEqual(Palette.assign(courses: courses).count, 13)
    }
}

final class NextBellTests: XCTestCase {

    /// Mon 9:30–10:20 WALC, 15:30–16:20 WALC; Tue 9:30 BHEE.
    private let engine: ScheduleEngine = {
        var table = Timetable()
        table.events = [
            ClassEvent(course: "ECE 30864", room: "WALC 2088", dayIndex: 0,
                       startSecond: 9 * 3600 + 1800, endSecond: 10 * 3600 + 1200, weekIndex: 0),
            ClassEvent(course: "ECE 30200", room: "BHEE 170", dayIndex: 0,
                       startSecond: 15 * 3600 + 1800, endSecond: 16 * 3600 + 1200, weekIndex: 0),
        ]
        return ScheduleEngine(timetable: table)
    }()

    private func walk(_ a: String?, _ b: String?) -> TimeInterval {
        guard let a, let b, a != b, a != "HOME" else { return 0 }
        return 10 * 60
    }

    private func bell(at time: Date) -> NextBell? {
        NextBell.make(engine: engine, now: time, bufferMinutes: 5, walkSeconds: walk)
    }

    func testInClassTheBellIsTheEnd() throws {
        let b = try XCTUnwrap(bell(at: date(2026, 11, 2, 10, 0)))
        XCTAssertEqual(b.kind, .ends)
        XCTAssertEqual(b.at, date(2026, 11, 2, 10, 20))
        XCTAssertEqual(b.remainingFraction(at: date(2026, 11, 2, 10, 0)), 20.0 / 50, accuracy: 0.001)
    }

    func testBetweenClassesWithAWalkTheBellIsLeaving() throws {
        let b = try XCTUnwrap(bell(at: date(2026, 11, 2, 12, 0)))
        XCTAssertEqual(b.kind, .leave)
        XCTAssertEqual(b.at, date(2026, 11, 2, 15, 15), "15:30 minus a 10 minute walk minus 5 buffer")
        XCTAssertEqual(b.caption, "until you leave for ECE 30200")
    }

    func testOnceItsTimeToGoTheBellIsTheStart() throws {
        let b = try XCTUnwrap(bell(at: date(2026, 11, 2, 15, 20)))
        XCTAssertEqual(b.kind, .starts)
        XCTAssertEqual(b.at, date(2026, 11, 2, 15, 30))
    }

    func testFirstClassFromHomeWithoutAKnownWalkIsTheStart() throws {
        let b = try XCTUnwrap(bell(at: date(2026, 11, 2, 8, 0)))
        XCTAssertEqual(b.kind, .starts)
        // The drain began three hours before the class, at 6:30: half gone.
        XCTAssertEqual(b.remainingFraction(at: date(2026, 11, 2, 8, 0)), 0.5, accuracy: 0.001)
    }

    /// Waiting since breakfast for an afternoon class shouldn't make the slab
    /// barely move: the drain covers at most three hours.
    func testTheDrainIsCappedAtThreeHours() throws {
        let b = try XCTUnwrap(bell(at: date(2026, 11, 2, 11, 0)))
        XCTAssertEqual(b.from, date(2026, 11, 2, 12, 30))
        XCTAssertEqual(b.remainingFraction(at: date(2026, 11, 2, 11, 0)), 1)
    }

    func testAfterTheLastClassThereIsNoBell() {
        XCTAssertNil(bell(at: date(2026, 11, 2, 17, 0)))
    }

    func testNumberFormatting() {
        XCTAssertEqual(BellNumber.format(14 * 60).value, "14")
        XCTAssertEqual(BellNumber.format(14 * 60).unit, "min")
        XCTAssertEqual(BellNumber.format(105 * 60).value, "1:45")
        XCTAssertEqual(BellNumber.format(105 * 60).unit, "hr")
        XCTAssertEqual(BellNumber.format(20).value, "1", "Never 0 while there's still time")
        XCTAssertEqual(BellNumber.spoken(105 * 60), "1 hour 45 minutes")
        XCTAssertEqual(BellNumber.spoken(60), "1 minute")
    }
}

final class TermProgressTests: XCTestCase {

    func testWeekAndFraction() throws {
        var table = Timetable()
        table.termStart = date(2026, 8, 24)
        table.termEnd = date(2026, 12, 12)
        let engine = ScheduleEngine(timetable: table)
        let p = try XCTUnwrap(TermProgress.make(timetable: table, engine: engine, now: date(2026, 11, 2, 12)))
        XCTAssertEqual(p.week, 11)
        XCTAssertEqual(p.weeks, 16)
        XCTAssertEqual(p.fraction, 0.64, accuracy: 0.02)
        XCTAssertNil(TermProgress.make(timetable: table, engine: engine, now: date(2027, 1, 10)), "Out of term")
    }
}

final class SkyClockTests: XCTestCase {

    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, zone: String = "America/Indiana/Indianapolis") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var indiana: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return calendar
    }

    /// Checked against an independent formulation (the sunrise equation),
    /// which agrees to about a minute; tolerance is three.
    func testSunsetAndSunriseOnCampus() throws {
        let november = try XCTUnwrap(SkyClock.sun(on: local(2026, 11, 2, 12, 0), calendar: indiana))
        XCTAssertEqual(november.sunset.timeIntervalSince(local(2026, 11, 2, 17, 43)), 0, accuracy: 3 * 60)
        XCTAssertEqual(november.sunrise.timeIntervalSince(local(2026, 11, 2, 7, 18)), 0, accuracy: 3 * 60)

        let june = try XCTUnwrap(SkyClock.sun(on: local(2026, 6, 21, 12, 0), calendar: indiana))
        XCTAssertEqual(june.sunset.timeIntervalSince(local(2026, 6, 21, 21, 21)), 0, accuracy: 3 * 60)
    }

    func testNightIsAfterSunsetAndBeforeSunrise() {
        XCTAssertFalse(SkyClock.isNight(at: local(2026, 11, 2, 16, 30), calendar: indiana))
        XCTAssertTrue(SkyClock.isNight(at: local(2026, 11, 2, 18, 30), calendar: indiana))
        XCTAssertTrue(SkyClock.isNight(at: local(2026, 11, 3, 2, 0), calendar: indiana), "Small hours")
        XCTAssertFalse(SkyClock.isNight(at: local(2026, 11, 3, 9, 0), calendar: indiana))
    }

    /// The 8 April 2024 eclipse was, necessarily, a new moon.
    func testMoonPhase() {
        let eclipse = Date(timeIntervalSince1970: 1_712_600_460) // 2024-04-08 18:21 UTC
        let phase = SkyClock.moonPhase(at: eclipse)
        XCTAssertLessThan(min(phase, 1 - phase), 0.04)
        let fortnightLater = eclipse.addingTimeInterval(14.77 * 86_400)
        XCTAssertEqual(SkyClock.moonPhase(at: fortnightLater), 0.5, accuracy: 0.04)
        XCTAssertEqual(SkyClock.illumination(phase: 0.5), 1, accuracy: 0.001)
        XCTAssertEqual(SkyClock.illumination(phase: 0.25), 0.5, accuracy: 0.001)
    }

    /// The moon's lit shape covers the right fraction of the disc.
    func testMoonShapeArea() {
        func litFraction(_ phase: Double) -> Double {
            let path = MoonShape(phase: phase).path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            var inside = 0, total = 0
            for x in stride(from: 0.5, to: 100, by: 1) {
                for y in stride(from: 0.5, to: 100, by: 1) where (x - 50) * (x - 50) + (y - 50) * (y - 50) < 2500 {
                    total += 1
                    if path.contains(CGPoint(x: x, y: y)) { inside += 1 }
                }
            }
            return Double(inside) / Double(total)
        }
        XCTAssertEqual(litFraction(0.25), 0.5, accuracy: 0.03)
        XCTAssertEqual(litFraction(0.5), 1, accuracy: 0.03)
        XCTAssertEqual(litFraction(0.1), SkyClock.illumination(phase: 0.1), accuracy: 0.04)
        XCTAssertEqual(litFraction(0.85), SkyClock.illumination(phase: 0.85), accuracy: 0.04)
    }
}
