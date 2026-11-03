import SwiftUI

/// The sky behind "Done for today": a sunset before sundown, the moon after.
///
/// It takes the place of the course colour, which is what the slab shows
/// while there's a bell to count down to. Once the day's classes are over
/// there's no course to colour it with, and the honest thing to show is the
/// time of day itself.
///
/// The sunset moves like the slab's level does: the sun sits high and the
/// sky is pale in the early afternoon, and both sink and warm as sundown
/// approaches. At night the moon is drawn at its real phase. The day's
/// text always sits on the dark silhouette at the bottom, so it reads in
/// white on either sky.
///
/// These are illustration colours, not interface tokens: they're only ever
/// a picture of a sky, so they live here rather than in `Bell`.
struct SkyScene: View {
    var now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let night = SkyClock.isNight(at: now)
        GeometryReader { geometry in
            ZStack {
                if night {
                    nightSky(geometry.size)
                } else {
                    daySky(geometry.size)
                }
                Hills(night: night)
            }
        }
        .animation(reduceMotion ? nil : Bell.Motion.continuous, value: night)
        .accessibilityHidden(true)
    }

    // MARK: Before sundown

    /// 0 four hours or more before sunset, 1 at sunset.
    private var dusk: Double {
        guard let sun = SkyClock.sun(on: now) else { return 1 }
        let hours = sun.sunset.timeIntervalSince(now) / 3600
        return min(1, max(0, 1 - hours / 4))
    }

    private func daySky(_ size: CGSize) -> some View {
        let p = dusk
        let top = Sky.afternoonTop.mix(with: Sky.duskTop, by: p)
        let middle = Sky.afternoonMiddle.mix(with: Sky.duskMiddle, by: p)
        let horizon = Sky.afternoonHorizon.mix(with: Sky.duskHorizon, by: p)
        let sunSize = size.width * 0.27
        // The horizon is where the hills begin; the sun sinks towards it.
        let horizonY = size.height * 0.5
        let sunY = horizonY - (1 - p) * size.height * 0.28
        return ZStack {
            LinearGradient(stops: [.init(color: top, location: 0),
                                   .init(color: middle, location: 0.45),
                                   .init(color: horizon, location: 0.52)],
                           startPoint: .top, endPoint: .bottom)
            // The glow, then the sun. The glow widens as it sets, which is
            // most of what makes a sunset look like one.
            RadialGradient(colors: [Sky.sunGlow.opacity(0.55 + 0.3 * p), .clear],
                           center: .center, startRadius: 0, endRadius: sunSize * (1.1 + p))
                .frame(width: sunSize * 4, height: sunSize * 4)
                .position(x: size.width * 0.72, y: sunY)
            Circle()
                .fill(LinearGradient(colors: [Sky.sunTop, Sky.sunBottom.mix(with: Sky.duskHorizon, by: p * 0.4)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: sunSize, height: sunSize)
                .position(x: size.width * 0.72, y: sunY)
        }
    }

    // MARK: After sundown

    private func nightSky(_ size: CGSize) -> some View {
        let moonSize = size.width * 0.2
        let moonCentre = CGPoint(x: size.width * 0.76, y: size.height * 0.22)
        return ZStack {
            LinearGradient(colors: [Sky.nightTop, Sky.nightBottom], startPoint: .top, endPoint: .bottom)
            Stars(now: now, twinkles: !reduceMotion)
            RadialGradient(colors: [Sky.moonGlow.opacity(0.35), .clear],
                           center: .center, startRadius: moonSize * 0.4, endRadius: moonSize * 1.6)
                .frame(width: moonSize * 3.4, height: moonSize * 3.4)
                .position(moonCentre)
            ZStack {
                // The unlit part, faintly, the way earthshine shows it.
                Circle().fill(Sky.moonDark)
                MoonShape(phase: SkyClock.moonPhase(at: now)).fill(Sky.moonLit)
            }
            .frame(width: moonSize, height: moonSize)
            .position(moonCentre)
        }
    }
}

/// Illustration colours for the sky. Hues of a real sky, chosen so the
/// white text on the hills clears 7:1 at any point in the dusk blend.
private enum Sky {
    static let afternoonTop = Color(hex: 0x5E9CE0)
    static let afternoonMiddle = Color(hex: 0xA9CBEB)
    static let afternoonHorizon = Color(hex: 0xFFE2B8)
    static let duskTop = Color(hex: 0x2E2B6B)
    static let duskMiddle = Color(hex: 0xC4507A)
    static let duskHorizon = Color(hex: 0xFF8A4C)
    static let sunTop = Color(hex: 0xFFF3C4)
    static let sunBottom = Color(hex: 0xFFB35C)
    static let sunGlow = Color(hex: 0xFFC47A)
    static let nightTop = Color(hex: 0x03050C)
    static let nightBottom = Color(hex: 0x16203D)
    static let moonLit = Color(hex: 0xF3EFE2)
    static let moonDark = Color(hex: 0x2A3150)
    static let moonGlow = Color(hex: 0xC9D6FF)
    static let hillFar = (day: Color(hex: 0x3A2347), night: Color(hex: 0x0D1326))
    static let hillNear = (day: Color(hex: 0x1C1024), night: Color(hex: 0x060912))
}

/// Two layers of rolling hills, the nearer one dark enough to carry white
/// text at full contrast. They rise to just under half the slab because the
/// headline starts there: lower, and "Done for today" sat half on pale sky.
private struct Hills: View {
    var night: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Ridge(base: 0.48, amplitude: 0.045, waves: 1.3, shift: 0.2)
                    .fill(night ? Sky.hillFar.night : Sky.hillFar.day)
                Ridge(base: 0.56, amplitude: 0.035, waves: 0.9, shift: 0.65)
                    .fill(night ? Sky.hillNear.night : Sky.hillNear.day)
                // The text area: a soft fade to the near hill's colour at the
                // very bottom, so a long second line never runs onto sky.
                LinearGradient(colors: [.clear, night ? Sky.hillNear.night : Sky.hillNear.day],
                               startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A gentle ridge line across the slab, filled down to the bottom edge.
private struct Ridge: Shape {
    var base: Double
    var amplitude: Double
    var waves: Double
    var shift: Double

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            let steps = 48
            for step in 0 ... steps {
                let x = Double(step) / Double(steps)
                let y = base + amplitude * sin((x * waves + shift) * 2 * .pi)
                path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The lit part of the moon for a phase: 0 new, 0.25 first quarter (right
/// half lit), 0.5 full, 0.75 last quarter. The terminator is a half-ellipse
/// whose width follows the phase, which is what the real one looks like.
struct MoonShape: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let waxing = phase < 0.5
        // Distance of the terminator from the centre, as a fraction of r:
        // +1 at new (no light), 0 at a quarter, -1 at full.
        let local = waxing ? phase : 1 - phase
        let terminator = cos(2 * Double.pi * local)
        let side: Double = waxing ? 1 : -1

        return Path { path in
            let steps = 40
            // The limb: the lit edge, a semicircle on the lit side.
            for step in 0 ... steps {
                let angle = -Double.pi / 2 + Double.pi * Double(step) / Double(steps)
                let point = CGPoint(x: centre.x + side * r * cos(angle), y: centre.y + r * sin(angle))
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            // The terminator, back up from the bottom.
            for step in 0 ... steps {
                let angle = Double.pi / 2 - Double.pi * Double(step) / Double(steps)
                path.addLine(to: CGPoint(x: centre.x + side * r * terminator * cos(angle),
                                         y: centre.y + r * sin(angle)))
            }
            path.closeSubpath()
        }
    }
}

/// A scattering of stars, the same every night (seeded, not random), each
/// breathing slowly at its own pace unless Reduce Motion is on.
private struct Stars: View {
    var now: Date
    var twinkles: Bool

    private static let field: [(x: Double, y: Double, size: Double, speed: Double)] = {
        var seed: UInt64 = 0x5EED_BE11
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0 ..< 34).map { _ in (next(), next() * 0.46, 1 + next() * 1.8, 0.3 + next() * 0.9) }
    }()

    var body: some View {
        GeometryReader { geometry in
            let t = now.timeIntervalSinceReferenceDate
            ForEach(Array(Self.field.enumerated()), id: \.offset) { index, star in
                Circle()
                    .fill(Color.white)
                    .frame(width: star.size, height: star.size)
                    .opacity(twinkles ? 0.35 + 0.55 * abs(sin(t * star.speed + Double(index))) : 0.7)
                    .animation(.easeInOut(duration: 1), value: Int(t))
                    .position(x: star.x * geometry.size.width, y: star.y * geometry.size.height)
            }
        }
    }
}
