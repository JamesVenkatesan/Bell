import SwiftUI

/// Colors for courses.
///
/// The constraint that shapes everything here: when the home screen is tinted,
/// iOS throws away hue and renders the widget from luminance alone. A palette
/// of ten pretty colors at the same brightness collapses into ten identical
/// grays, which is why most timetable widgets become unreadable the moment you
/// tint them.
///
/// So the palette is built the other way round. Pick ten evenly spaced
/// luminance steps first, then choose a hue for each step. Tinted, the courses
/// stay separable because they were never relying on hue to begin with.
enum Palette {

    /// Ordered light to dark, at evenly spaced perceptual lightness: CIELAB
    /// L* 92 down to 29 in steps of exactly 7. Solved for, not picked: each
    /// hue's lightness was searched until it landed on its target, which is
    /// why they're saturated and still separable once a tinted home screen
    /// throws the hue away. No red, so the signal colour stays unique.
    static let steps: [Color] = [
        Color(hex: 0xFFEA5F), // Lemon      L* 92
        Color(hex: 0x8CED1D), // Lime       L* 85
        Color(hex: 0x18D8BF), // Aqua       L* 78
        Color(hex: 0xFF9326), // Tangerine  L* 71
        Color(hex: 0x16A2F9), // Sky        L* 64
        Color(hex: 0xFA3986), // Pink       L* 57
        Color(hex: 0x0B8854), // Jade       L* 50
        Color(hex: 0x7A34F4), // Violet     L* 43
        Color(hex: 0x1241DB), // Cobalt     L* 36
        Color(hex: 0x731781), // Plum       L* 29
    ]

    static let stepNames = ["Lemon", "Lime", "Aqua", "Tangerine", "Sky",
                            "Pink", "Jade", "Violet", "Cobalt", "Plum"]

    /// Which steps `count` courses take: spread over the whole ramp, ends
    /// included. Taking the first N made a six-course term all light colours,
    /// close together in lightness and bland together on screen.
    static func spread(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0] }
        let last = steps.count - 1
        return (0 ..< count).map { Int((Double($0) * Double(last) / Double(count - 1)).rounded()) % steps.count }
    }

    /// Stable assignment: the same course gets the same step every launch,
    /// and lab sections inherit their lecture's color.
    ///
    /// Courses are assigned in sorted order rather than by hash, so a schedule
    /// of five courses uses five *well-separated* steps instead of whatever
    /// five a hash happens to land on.
    static func assign(courses: [String]) -> [String: Color] {
        let families = Array(Set(courses.map { ClassEvent(
            course: $0, room: "", dayIndex: 0, startSecond: 0, endSecond: 0, weekIndex: 0
        ).courseFamily })).sorted()

        guard !families.isEmpty else { return [:] }

        // More families than steps wrap around; past ten courses, sharing a
        // colour is unavoidable and spread order keeps the sharers far apart.
        let picks = families.count <= steps.count ? spread(families.count)
                                                  : (0 ..< families.count).map { $0 % steps.count }
        var mapping: [String: Color] = [:]
        for (index, family) in families.enumerated() {
            mapping[family] = steps[picks[index]]
        }

        var result: [String: Color] = [:]
        for course in courses {
            let family = ClassEvent(
                course: course, room: "", dayIndex: 0, startSecond: 0, endSecond: 0, weekIndex: 0
            ).courseFamily
            result[course] = mapping[family] ?? steps[0]
        }
        return result
    }

    /// Perceived brightness, used to pick legible text on top of a course color
    /// and to verify the palette really is luminance-separated.
    static func relativeLuminance(_ color: Color) -> Double {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        #else
        return 0.5
        #endif
    }

    static func legibleForeground(on color: Color) -> Color {
        Bell.legibleOn(color)
    }
}

extension Color {
    /// Serialized into the shared store so the widget doesn't recompute the
    /// palette on every timeline refresh.
    var storableComponents: [Double] {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
        #else
        return [0.5, 0.5, 0.5]
        #endif
    }

    init(storableComponents: [Double]) {
        guard storableComponents.count == 3 else { self = .gray; return }
        self = Color(red: storableComponents[0],
                     green: storableComponents[1],
                     blue: storableComponents[2])
    }
}
