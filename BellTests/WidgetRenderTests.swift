import SwiftUI
import XCTest
@testable import Bell

/// Renders all nine widgets, full colour and tinted, to PNGs for review.
/// Writes only when BELL_RENDER_DIR is set, so a normal test run stays clean.
@MainActor
final class WidgetRenderTests: XCTestCase {

    func testRenderGallery() throws {
        guard let dir = ProcessInfo.processInfo.environment["BELL_RENDER_DIR"] ?? Self.fallbackDir else {
            throw XCTSkip("Set BELL_RENDER_DIR to render widget previews")
        }
        let table = BundledTimetable.load() ?? .empty
        // A weekday mid-afternoon, so every widget has something to show.
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = 13; components.minute = 50
        let now = Calendar.current.date(from: components) ?? .now
        var tasks = table
        tasks.tasks = [
            TaskEvent(title: "ECE 30200 Homework 9", course: "ECE 30200",
                      due: now.addingTimeInterval(30 * 3600), kind: .assignment),
            TaskEvent(title: "Midterm 2", course: "ECE 36200", due: now.addingTimeInterval(3 * 86_400), kind: .exam),
            TaskEvent(title: "Lab report", course: "ECE 30864L", due: now.addingTimeInterval(4 * 86_400), kind: .assignment),
        ]
        let model = WidgetModel.build(timetable: tasks, palette: Palette.assign(courses: tasks.courses), busy: [],
                                      hidden: [], leaveBuffer: 5, completedTasks: [], markedAttendance: [], now: now)

        for tinted in [false, true] {
            for kind in WidgetKind.allCases {
                let view = WidgetPreview(kind: kind, model: model, tinted: tinted)
                    .padding(12)
                    .background(Color(hex: 0xF2F3F5))
                    .frame(width: 400)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let data = renderer.uiImage?.pngData() else { continue }
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(kind.rawValue)\(tinted ? "-tinted" : "").png"))
            }
        }
    }

    /// Bell Max at four moments, because its composition is the point:
    /// the same widget should look different on each.
    func testRenderBellMaxScenarios() throws {
        guard let dir = ProcessInfo.processInfo.environment["BELL_RENDER_DIR"] ?? Self.fallbackDir else {
            throw XCTSkip("Set BELL_RENDER_DIR to render widget previews")
        }
        let table = BundledTimetable.load() ?? .empty
        let calendar = Calendar.current
        // The Monday of this week, so the bundled schedule has classes.
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: .now) + 5) % 7),
                                   to: calendar.startOfDay(for: .now))!
        func at(_ hour: Int, _ minute: Int = 0, plusDays: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute + plusDays * 1440, to: monday)!
        }
        func notion(_ title: String, _ course: String?, _ due: Date, _ kind: TaskEvent.Kind = .assignment,
                    allDay: Bool = false) -> TaskEvent {
            TaskEvent(title: title, course: course, due: due, kind: kind, isAllDay: allDay, fromNotion: true)
        }

        let scenarios: [(String, Date, [TaskEvent], Date?)] = [
            // Four classes, nothing due, no exam.
            ("morning-quiet", at(7, 10), [], at(6, 30)),
            // Mid-afternoon, two things due tonight, an exam on Thursday.
            ("afternoon-exam-thu", at(16, 40), [
                notion("Homework 9", "ECE 30200", at(23, 59)),
                notion("Read chapter 7", nil, at(0), .other, allDay: true),
                notion("Midterm 2", "ECE 30100", at(19, plusDays: 3), .exam)], at(15, 0)),
            // Between classes, an exam tomorrow morning, one thing due.
            ("exam-tomorrow", at(11, 0), [
                notion("Lab 6 write-up", "ECE 30864L", at(17, 0)),
                notion("Exam 2", "ECE 20869", at(8, plusDays: 1), .exam)], at(10, 30)),
            // Saturday, nothing at all, with Notion data that's gone stale.
            ("weekend-stale", at(10, 0, plusDays: 5), [
                notion("Project proposal", "ECE 39401", at(12, plusDays: 11), .project)], at(1, 0, plusDays: 5)),
        ]
        for (name, now, tasks, synced) in scenarios {
            var t = table
            t.tasks = tasks
            let model = WidgetModel.build(timetable: t, palette: Palette.assign(courses: t.courses), busy: [],
                                          hidden: [], leaveBuffer: 5, completedTasks: [], markedAttendance: [],
                                          notionSyncedAt: synced, now: now)
            // Light, dark, and tinted: the home screen can be any of them,
            // and legibility has to hold in all three.
            for variant in ["", "-dark", "-tinted"] {
                let view = WidgetPreview(kind: .max, model: model, tinted: variant == "-tinted")
                    .padding(12).background(variant == "-dark" ? Color.black : Color(hex: 0xF2F3F5)).frame(width: 400)
                    .environment(\.colorScheme, variant == "-dark" ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let data = renderer.uiImage?.pngData() else { continue }
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("max-\(name)\(variant).png"))
            }
        }
    }

    /// The Today screen's day with deadlines and an exam on it, rendered
    /// directly because the simulator can't be scrolled down to it.
    func testRenderDayWithDeadlines() throws {
        guard let dir = ProcessInfo.processInfo.environment["BELL_RENDER_DIR"] ?? Self.fallbackDir else {
            throw XCTSkip("Set BELL_RENDER_DIR to render previews")
        }
        let table = BundledTimetable.load() ?? .empty
        let calendar = Calendar.current
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: .now) + 5) % 7),
                                   to: calendar.startOfDay(for: .now))!
        func at(_ h: Int, _ m: Int = 0) -> Date { monday.addingTimeInterval(Double(h * 3600 + m * 60)) }
        let tasks = [
            TaskEvent(title: "Homework 9", course: "ECE 30200", due: at(10), kind: .assignment, fromNotion: true),
            TaskEvent(title: "Lab 6 write-up", course: "ECE 30864L", due: at(13, 20), kind: .assignment, fromNotion: true),
            TaskEvent(title: "Problem set 3", course: nil, due: at(13, 35), kind: .assignment, fromNotion: true),
            TaskEvent(title: "Midterm 2", course: "ECE 30100", due: at(18), kind: .exam, end: at(19, 30), fromNotion: true),
            TaskEvent(title: "Quiz 4 corrections", course: "ECE 36200", due: at(23, 59), kind: .quiz, fromNotion: true),
            TaskEvent(title: "Read chapter 7", course: nil, due: monday, kind: .other, isAllDay: true, fromNotion: true),
        ]
        let engine = ScheduleEngine(timetable: table)
        let occurrences = engine.occurrences(on: monday)
        let exams = tasks.filter { $0.kind == .exam && $0.end != nil }
        let layout = DayLayout(occurrences: occurrences, exams: exams, walkSeconds: Campus.walkingSeconds)
        let deadlines = layout.deadlines(tasks.filter { t in !exams.contains { $0.id == t.id } })
        let palette = Palette.assign(courses: table.courses)

        struct Day: View {
            var layout: DayLayout
            var deadlines: DayLayout.Deadlines
            var palette: [String: Color]
            var now: Date
            @Namespace private var hero
            var body: some View {
                VStack(alignment: .leading, spacing: Bell.Space.loose) {
                    DeadlineList(title: "Due today", tasks: deadlines.allDay, palette: palette) { _ in }
                    DayTimeline(layout: layout, now: now, palette: palette, hero: hero,
                                deadlines: deadlines.marks, open: { _ in })
                    DeadlineList(title: "After your last class", tasks: deadlines.after, palette: palette) { _ in }
                }
                .padding(Bell.Space.gutter)
                .frame(width: 402)
                .background(Bell.Surface.canvas)
            }
        }
        for dark in [false, true] {
            let view = Day(layout: layout, deadlines: deadlines, palette: palette, now: at(11, 5))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let data = renderer.uiImage?.pngData() else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("day-deadlines\(dark ? "-dark" : "").png"))
        }
    }

    /// The done-for-the-day sky through an afternoon and into the night,
    /// since the simulator only ever shows whatever time it is.
    func testRenderSkyThroughTheDay() throws {
        guard let dir = ProcessInfo.processInfo.environment["BELL_RENDER_DIR"] ?? Self.fallbackDir else {
            throw XCTSkip("Set BELL_RENDER_DIR to render previews")
        }
        let day = Calendar.current.startOfDay(for: .now)
        for (name, hour, minute) in [("1300", 13, 0), ("1600", 16, 0), ("1720", 17, 20), ("2200", 22, 0)] {
            let now = day.addingTimeInterval(Double(hour * 3600 + minute * 60))
            let view = ZStack(alignment: .bottomLeading) {
                SkyScene(now: now)
                VStack(alignment: .leading) {
                    Text("Done for today").font(Bell.Type_.display)
                    Text("ECE 30100 at 7:30 AM tomorrow").font(Bell.Type_.title)
                }
                .foregroundStyle(Bell.paper)
                .padding(24)
            }
            .frame(width: 370, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Bell.Radius.card, style: .continuous))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let data = renderer.uiImage?.pngData() else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sky-\(name).png"))
        }
    }

    private static var fallbackDir: String? {
        let path = "/private/tmp/claude-501/-Users-jamesvenkatesan-Downloads-bell/d7c5bd49-715d-44f7-8233-928a8b1b73b3/scratchpad/widgets"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
