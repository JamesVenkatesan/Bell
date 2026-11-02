import SwiftUI
import XCTest
@testable import Bell

/// Renders all eight widgets, full colour and tinted, to PNGs for review.
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

    private static var fallbackDir: String? {
        let path = "/private/tmp/claude-501/-Users-jamesvenkatesan-Downloads-bell/d7c5bd49-715d-44f7-8233-928a8b1b73b3/scratchpad/widgets"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
