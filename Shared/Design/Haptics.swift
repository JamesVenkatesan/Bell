import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Touch feedback, keyed to meaning rather than to events.
///
/// The discipline that matters: haptics are a vocabulary, not a garnish. If
/// every tap buzzes, the buzz stops carrying information and becomes texture
/// the user learns to ignore — at which point the one that should have meant
/// something lands on deaf fingers.
///
/// So each case here corresponds to a *kind of thing happening*, and callers
/// pick by meaning. Scrolling past a boundary, confirming a capture, and
/// hitting a conflict feel different because they are different.
enum Haptic {

    /// Crossing a boundary while dragging — a day in the week scrubber, an
    /// hour in the timeline.
    case tick

    /// A normal selection: picking a day, opening a class.
    case select

    /// Something accepted. Captured event confirmed, attendance marked.
    case confirm

    /// Something that needs attention but isn't an error: a tight transition,
    /// a leave-now threshold crossing.
    case warn

    /// A genuine conflict, or an action that failed.
    case reject

    func play() {
        #if canImport(UIKit)
        switch self {
        case .tick:
            UISelectionFeedbackGenerator().selectionChanged()
        case .select:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .confirm:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warn:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .reject:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}

extension View {
    /// Fires when `value` changes, so feedback stays attached to state rather
    /// than being scattered through button actions where it drifts out of sync
    /// with what actually happened.
    func haptic<V: Equatable>(_ feedback: Haptic, on value: V) -> some View {
        onChange(of: value) { _, _ in feedback.play() }
    }
}
