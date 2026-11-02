import SwiftUI

/// The vocabulary every Bell surface is built from.
///
/// One idea organises it: **the next bell is the interface.** The countdown
/// to the next class starting, ending or the moment to leave is set huge, in a
/// slab of the course's colour, and that slab is the one loud thing in the app.
/// Everything else is a strict, quiet timetable that reads in a corridor.
///
/// So the vocabulary splits in two. Course colours are saturated and used as
/// solid fields, because they carry identity. Everything else is ink on a plain
/// ground with a single signal colour, because it carries information and must
/// stay sharp next to the loud part.
///
/// The one constraint kept from before: course colours step evenly through
/// lightness (see `Palette`), because tinted widgets discard hue. That rule
/// governs the ramp only, not the rest of the look.
enum Bell {}

// MARK: - Adaptive colour

extension Color {
    /// One colour for the light ground and one for the dark, resolved by the
    /// system per trait, so the app and its widgets follow the user's
    /// appearance setting instead of forcing one.
    init(day: UInt32, night: UInt32) {
        #if canImport(UIKit)
        self = Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? night : day)
        })
        #else
        self = Color(hex: day)
        #endif
    }

    init(hex: UInt32) {
        self = Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

// MARK: - Surfaces

extension Bell {
    enum Surface {
        /// The ground. Day is a cool grey, not white (white glares in a lit
        /// corridor) and not cream (warm grounds muddy saturated colour).
        /// Night is true black: saturated slabs on OLED black are the
        /// brightest, cleanest thing the screen can show.
        static let canvas = Color(day: 0xF2F3F5, night: 0x000000)

        /// Sheets and the collapsed bar. Used rarely: groups are separated
        /// by space, not by boxes.
        static let raised = Color(day: 0xFFFFFF, night: 0x141416)

        /// Wells: fields, the empty part of a track.
        static let sunken = Color(day: 0xE6E8EB, night: 0x0C0C0E)

        /// Rules. Only where alignment can't do the separating.
        static let hairline = Color(day: 0xD9DBDF, night: 0x26282C)

        /// The fallback for a course with no colour, and empty track.
        static let scaffold = Color(day: 0xC9CCD1, night: 0x2C2E33)
    }
}

// MARK: - Ink

extension Bell {
    enum Content {
        static let primary = Color(day: 0x0B0B0C, night: 0xF5F6F7)
        /// 5.9:1 on the day ground, 8.6:1 on night.
        static let secondary = Color(day: 0x5B5E64, night: 0xA3A6AC)
        /// Large text and non-text only; below 4.5:1 on purpose.
        static let tertiary = Color(day: 0x8A8D93, night: 0x6B6E74)
        static let spent = tertiary
    }
}

// MARK: - Signal

extension Bell {
    /// One signal colour, where there used to be four. Vermilion means "now"
    /// or "act": the now line, leave now, a clash. The ramp has no red in it,
    /// so it can never be mistaken for a course. Everything that is fine is
    /// simply ink; everything the model proposed is marked by shape (a
    /// sparkle and a dashed outline), not by a hue of its own.
    enum Signal {
        static let now = Color(day: 0xFF4F1F, night: 0xFF5A2B)
        static let urgent = now
        static let conflict = now
        static let settled = Content.primary
        static let inferred = Content.primary
    }
}

// MARK: - Type
//
// One family, SF Pro, made expressive with its width axis instead of a second
// typeface. Compressed Black is reserved for the bell number and nothing else,
// so it always means "the countdown". Expanded carries titles. Everything that
// changes is tabular, so a ticking number never shifts sideways.
//
// No tracked-out capitals anywhere. Sections are named in sentence case;
// hierarchy comes from size, weight and width.

extension Bell {
    enum Type_ {
        /// The countdown. Capped rather than scaled with Dynamic Type: it is
        /// already the largest thing on screen, and its accessibility label
        /// carries the value.
        static func bell(_ size: CGFloat) -> Font {
            .system(size: size, weight: .black).width(.compressed).monospacedDigit()
        }

        static let display = Font.system(.largeTitle, weight: .bold).width(.expanded)
        static let title = Font.system(.title2, weight: .semibold).width(.expanded)
        static let headline = Font.system(.headline, weight: .semibold)
        static let body = Font.system(.body)
        /// Labels and metadata, sentence case.
        static let caption = Font.system(.subheadline, weight: .medium)
        static let micro = Font.system(.caption, weight: .semibold)

        /// For times and counts.
        static func data(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight).monospacedDigit()
        }
    }
}

// MARK: - Metrics

extension Bell {
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 32

        /// Side margin. Matches the widget's gutter so the app and the home
        /// screen feel like one surface.
        static let gutter: CGFloat = 16
    }

    enum Radius {
        /// Timetable slabs. Nearly square: they're data, not buttons.
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 12
        /// The few things that are objects: sheets, the hero's inner corner.
        static let card: CGFloat = 20
    }

    enum Stroke {
        static let hair: CGFloat = 0.5
        static let rail: CGFloat = 4
    }
}

// MARK: - Course colour

extension Bell {
    /// Resolves a course to its colour through the stored palette, so the app
    /// and the widget agree without either recomputing.
    static func color(forCourse code: String) -> Color {
        SnapshotCache.palette()[code] ?? Surface.scaffold
    }

    /// Text that stays legible on a course colour: whichever of ink or paper
    /// has the higher contrast ratio against it.
    ///
    /// This used a fixed luminance cut at 0.45, which is far too high. The
    /// point where dark and light text contrast equally is near 0.18, so
    /// mid-ramp colours like orchid (0.43) got white text at about 2:1 and
    /// the course page header was unreadable.
    static func legibleOn(_ color: Color) -> Color {
        let background = Palette.relativeLuminance(color)
        return contrast(background, Palette.relativeLuminance(ink)) >= contrast(background, 1)
            ? ink : paper
    }

    /// Fixed ink and paper for text on course colour. Not the adaptive ink:
    /// a lemon slab needs near-black text in dark mode too.
    static let ink = Color(hex: 0x0B0B0C)
    static let paper = Color(hex: 0xFFFFFF)

    /// WCAG contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

// MARK: - Materials

extension Bell {
    /// Translucency used sparingly and always over content that benefits from
    /// showing through — a sheet above the timeline, a bar above a scroll.
    /// Blur over a flat fill is decoration, and decoration on a utility costs
    /// legibility for nothing.
    enum Material_ {
        static let overlay = Material.ultraThin
        static let bar = Material.bar

        /// Controls that float over a scrolling schedule: the day strip, the
        /// week grid's header, the scrub readout. Glass rather than a material
        /// because it refracts what passes beneath, so a class sliding under
        /// the strip stays legible as a shape instead of turning to fog.
        /// Same rule as above: only where content actually moves underneath.
        static let floating = Glass.regular

        /// The same, for something you can press. Glass that responds to touch
        /// is the system's signal that a surface is a control.
        static let floatingControl = Glass.regular.interactive()
    }
}
