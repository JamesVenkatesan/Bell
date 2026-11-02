import AppIntents
import Foundation
import WidgetKit

/// What a widget button did, waiting for the app to make it real.
///
/// A widget runs in its own process and can't open the SwiftData store, so a
/// tap can't write a task or an attendance record directly. It writes the
/// action here instead (App Group defaults, a few bytes) and the widget reads
/// it straight back, so the tap shows at once; the app applies the queue the
/// next time it runs and clears it.
enum WidgetAction: Codable, Equatable {
    case taskDone(UUID)
    case attendance(course: String, start: Date, went: Bool)
}

enum WidgetActions {
    private static let key = "widget.actions"
    private static let markedKey = "attendance.recentKeys"

    static func pending() -> [WidgetAction] {
        guard let data = AppGroup.defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WidgetAction].self, from: data)) ?? []
    }

    static func append(_ action: WidgetAction) {
        var all = pending()
        all.append(action)
        if let data = try? JSONEncoder().encode(all) { AppGroup.defaults?.set(data, forKey: key) }
    }

    static func clear() { AppGroup.defaults?.removeObject(forKey: key) }

    static var completedTasks: Set<UUID> {
        Set(pending().compactMap { if case .taskDone(let id) = $0 { id } else { nil } })
    }

    /// Attendance marked anywhere: by the app (it records recent keys here)
    /// or by a widget tap still in the queue. The prompt shows for neither.
    static var markedAttendance: Set<String> {
        let queued = pending().compactMap { action -> String? in
            if case .attendance(let course, let start, _) = action {
                return WidgetModel.attendanceKey(course: course, start: start)
            }
            return nil
        }
        return Set(queued + (AppGroup.defaults?.stringArray(forKey: markedKey) ?? []))
    }

    /// Called by the store whenever attendance is recorded, so the widget
    /// stops asking about a class that's already been marked in the app.
    static func noteMarked(_ key: String) {
        let recent = (AppGroup.defaults?.stringArray(forKey: markedKey) ?? []) + [key]
        AppGroup.defaults?.set(Array(recent.suffix(60)), forKey: markedKey)
    }
}

// MARK: - Intents

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark work done"
    static let isDiscoverable = false

    @Parameter(title: "Task") var taskID: String

    init() {}
    init(taskID: UUID) { self.taskID = taskID.uuidString }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: taskID) { WidgetActions.append(.taskDone(id)) }
        return .result()
    }
}

struct MarkAttendanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark attendance"
    static let isDiscoverable = false

    @Parameter(title: "Course") var course: String
    @Parameter(title: "Start") var start: Date
    @Parameter(title: "Went") var went: Bool

    init() {}
    init(course: String, start: Date, went: Bool) {
        self.course = course
        self.start = start
        self.went = went
    }

    func perform() async throws -> some IntentResult {
        WidgetActions.append(.attendance(course: course, start: start, went: went))
        return .result()
    }
}
