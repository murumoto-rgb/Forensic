import UIKit

/// Lightweight wrapper around `UIImpactFeedbackGenerator` /
/// `UINotificationFeedbackGenerator` so call sites can fire haptics in
/// one line without keeping generator instances alive.
///
/// Each helper allocates its generator on demand, prepares it, fires
/// once, and releases — the prepare-just-before-fire pattern keeps the
/// Taptic engine warm enough to feel responsive without the cost of
/// long-lived generator references.
@MainActor
enum Haptics {
    /// Subtle confirmation pulse — favorites toggle, chip tap, etc.
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Medium-impact thud — used for primary affirmative actions
    /// (saving overrides, committing photo location).
    static func confirm() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Notification-style success — paired with a success toast on
    /// completion of multi-step operations (export ready, batch
    /// tagging done, bucket reassignment complete).
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// Notification-style warning — used when something needs attention
    /// (iCloud conflict, validation error not blocking the flow).
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Notification-style failure — destructive failures, refusals,
    /// network errors.
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
}
