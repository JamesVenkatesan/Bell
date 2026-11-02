import SwiftUI

/// How Bell moves.
///
/// Three principles, and the curves follow from them.
///
/// **Nothing linear.** Linear motion reads as mechanical because nothing
/// physical moves that way. Every transition here is a spring.
///
/// **Response before bounce.** A spring's `response` is how quickly it starts;
/// damping is how it settles. Interfaces feel fast when they *begin* fast,
/// not when they end fast, so these keep response short and let damping do the
/// character.
///
/// **Bounce is a reward, not a default.** Overshoot draws the eye. Spend it on
/// something arriving that the user wanted — a captured event landing, a class
/// confirmed. Never on something leaving, and never on a list that redraws
/// often, where repeated bounce becomes fidget.
extension Bell {
    enum Motion {

        /// The workhorse. Rows reordering, values changing, most state.
        static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)

        /// Taps and toggles — fast enough to feel like direct manipulation.
        static let snap = Animation.spring(response: 0.22, dampingFraction: 0.9)

        /// A row expanding into a full screen. Slower because the eye has to
        /// follow a shape across a large distance; too fast and the connection
        /// between the row and the screen is lost, which is the whole point of
        /// a matched transition.
        static let hero = Animation.spring(response: 0.46, dampingFraction: 0.82)

        /// Something arriving that the user will be pleased to see.
        static let arrive = Animation.spring(response: 0.42, dampingFraction: 0.68)

        /// Dismissal. Slightly overdamped: leaving should be unremarkable.
        static let dismiss = Animation.spring(response: 0.28, dampingFraction: 1.0)

        /// Continuous values — a progress rail filling, an ETA shrinking.
        /// These change on a timer rather than on a gesture, so they get a
        /// gentle ease instead of a spring that would wobble on every tick.
        static let continuous = Animation.easeInOut(duration: 0.6)

        /// Staggered list appearance. Capped so a long list doesn't turn into
        /// a slow cascade the user waits through.
        static func stagger(index: Int, step: Double = 0.035, cap: Double = 0.28) -> Animation {
            standard.delay(min(Double(index) * step, cap))
        }
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Rows entering a schedule: rise slightly and fade. The rise reads as the
    /// row settling into place rather than materialising.
    static var bellRow: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity)
    }

    /// Cards in the inbox: scale from just under full size, so accepting one
    /// feels like it was already there rather than being drawn.
    static var bellCard: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.94).combined(with: .opacity),
            removal: .scale(scale: 0.98).combined(with: .opacity))
    }
}

// MARK: - Namespace plumbing

/// Keys for matched-geometry transitions, kept in one place so the row and the
/// detail screen can't drift apart — a mismatched ID silently degrades a hero
/// transition into a cross-fade, with no error anywhere.
enum HeroID {
    static func card(_ id: String) -> String { "card-\(id)" }
    static func title(_ id: String) -> String { "title-\(id)" }
    static func rail(_ id: String) -> String { "rail-\(id)" }
    static func room(_ id: String) -> String { "room-\(id)" }
}

// MARK: - Press

/// How a tappable card answers a finger: it gives slightly, at once, and
/// springs back. Without it a card that is about to zoom into a full screen
/// feels inert for the instant before the transition starts, which reads as
/// lag even when there is none.
struct BellPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Bell.Motion.snap, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BellPressStyle {
    static var bellPress: BellPressStyle { BellPressStyle() }
}
