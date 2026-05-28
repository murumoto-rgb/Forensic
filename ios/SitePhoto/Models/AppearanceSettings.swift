import Foundation
import SwiftUI
import UIKit

/// Namespace for the user's visual-customisation preferences. Backed by
/// `UserDefaults` so the chosen accent (and, when present, alternate app
/// icon) survive launches without needing a dedicated JSON manifest.
///
/// The accent palette is curated rather than free-form: a fixed set of
/// well-balanced hues that read on light + dark backgrounds, plus the
/// option to fall back to "system blue" (no tint override). A full
/// `ColorPicker` would give the user too much rope to hang the UI with.
enum AppearanceSettings {
    static let accentColorKey = "sitephoto.accentColorHex"
    static let alternateIconKey = "sitephoto.alternateIconName"

    /// Default tint that matches the bundled BaykalLogo when no override
    /// has been picked yet. Kept in sync with the existing
    /// `AccentColor.colorset` so the first-launch experience is the same.
    static let defaultAccentHex = "#22896F"

    /// Curated palette presented in Settings. Each entry has a display
    /// name + an `#RRGGBB` hex. We keep the count modest so the picker
    /// stays a one-row scroll rather than a scrollable grid.
    static let accentPalette: [(name: String, hex: String)] = [
        ("Baykal Teal", "#22896F"),
        ("Pacific",     "#0EA5E9"),
        ("Royal",       "#2B7FFF"),
        ("Indigo",      "#4F46E5"),
        ("Plum",        "#9333EA"),
        ("Rose",        "#E11D48"),
        ("Amber",       "#D4820A"),
        ("Slate",       "#475569")
    ]

    /// Names registered in `project.yml`'s `CFBundleAlternateIcons` —
    /// each must have matching `*.png` assets in the project. Empty for
    /// now; populated when alternate icon assets are added to the bundle.
    /// The picker hides the section entirely when this list is empty.
    static let alternateIcons: [(name: String, displayName: String)] = []

    /// Resolve the current accent color from storage. Falls back to the
    /// bundled Baykal teal if no override is set or the stored value is
    /// malformed.
    static func currentAccent() -> Color {
        let hex = UserDefaults.standard.string(forKey: accentColorKey)
            ?? defaultAccentHex
        return Color(bucketHex: hex) ?? Color(bucketHex: defaultAccentHex)!
    }

    /// Apply a new alternate icon. iOS handles the resource swap; the
    /// completion runs back on the main thread when finished. No-ops on
    /// platforms without alternate icon support.
    @MainActor
    static func setAlternateIcon(_ name: String?) async {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(name)
            UserDefaults.standard.set(name, forKey: alternateIconKey)
        } catch {
            // setAlternateIconName fails if the asset isn't registered or
            // the app isn't in the foreground. Silent fail is fine here —
            // the picker UI re-reads the actual icon on next appearance.
        }
    }
}
