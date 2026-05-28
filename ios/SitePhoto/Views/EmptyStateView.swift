import SwiftUI

/// Branded empty-state placeholder used in place of the default
/// `ContentUnavailableView`. The hero is an accent-tinted circle holding
/// a single SF Symbol, which lets each empty screen feel like part of
/// SitePhoto rather than a generic system blank slate without shipping
/// custom illustration assets.
///
/// Use the convenience initialiser to drop one in:
///
/// ```swift
/// EmptyStateView(icon: "photo.stack", title: "No photos yet",
///                 message: "Tap Camera to capture the first one.")
/// ```
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String?
    var accent: Color = .accentColor

    init(icon: String, title: String, message: String? = nil, accent: Color = .accentColor) {
        self.icon = icon
        self.title = title
        self.message = message
        self.accent = accent
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                Circle()
                    .stroke(accent.opacity(0.30), lineWidth: 1)
                    .frame(width: 120, height: 120)
                Image(systemName: icon)
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
