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

    /// Ink and paper. Not pure black — the schedule is read at arm's length in
    /// lecture halls, and a slightly blue-shifted dark holds up better under
    /// the warm cast of True Tone.
    static let ink = Color(red: 0.078, green: 0.102, blue: 0.133)
    static let rail = Color(red: 0.165, green: 0.196, blue: 0.239)
    static let paper = Color(red: 0.980, green: 0.973, blue: 0.957)

    /// Ordered light → dark. Each entry is a hue chosen to sit at its assigned
    /// luminance, so `relativeLuminance` steps roughly evenly down the list.
    private static let steps: [Color] = [
        Color(red: 0.98, green: 0.87, blue: 0.55), // straw
        Color(red: 0.62, green: 0.86, blue: 0.76), // seafoam
        Color(red: 0.98, green: 0.70, blue: 0.60), // apricot
        Color(red: 0.53, green: 0.74, blue: 0.94), // sky
        Color(red: 0.85, green: 0.60, blue: 0.85), // orchid
        Color(red: 0.36, green: 0.68, blue: 0.55), // fern
        Color(red: 0.91, green: 0.42, blue: 0.42), // coral
        Color(red: 0.42, green: 0.48, blue: 0.82), // indigo
        Color(red: 0.60, green: 0.34, blue: 0.55), // plum
        Color(red: 0.24, green: 0.32, blue: 0.42), // slate
    ]

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

        let stride = max(1, steps.count / families.count)
        var mapping: [String: Color] = [:]
        for (index, family) in families.enumerated() {
            mapping[family] = steps[(index * stride) % steps.count]
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
        relativeLuminance(color) > 0.45 ? ink : paper
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
