import Foundation

/// The shared sandbox the app and the widget both see.
///
/// Two processes, one container. The app writes; the widget reads. Everything
/// durable goes through here, and nothing durable lives in either target's own
/// container — a file written to the app's private directory is invisible to
/// the widget, which is the single most common way a widget ends up showing
/// stale data.
enum AppGroup {

    /// Must match the string in both `.entitlements` files exactly.
    static let identifier = "group.com.yourteam.bell"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Where SwiftData's store file lives.
    static var databaseURL: URL? {
        containerURL?.appendingPathComponent("Bell.store")
    }

    /// Scratch space for imports — a photo being parsed, a downloaded `.ics`.
    /// Separate from the database so a failed import can't corrupt anything.
    static var importsURL: URL? {
        guard let base = containerURL?.appendingPathComponent("Imports", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// False when the entitlement is missing or the group identifier is wrong.
    /// Worth surfacing in Settings rather than failing silently, because every
    /// symptom of a broken group looks like a bug somewhere else.
    static var isAvailable: Bool { containerURL != nil }

    /// A one-line description for the Settings screen.
    static var status: String {
        isAvailable ? "Shared container active" : "Shared container unavailable"
    }
}
