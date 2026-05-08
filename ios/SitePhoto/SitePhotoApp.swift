import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    /// Drives ContentView's fade-in (1 = visible, 0 = hidden behind splash).
    @State private var contentVisible = false

    /// Drives the logo's position (true = bottom footer, false = centered)
    /// and its scale. Same withAnimation block as `contentVisible` so the
    /// move and the cross-fade happen together.
    @State private var logoMoved = false

    /// Fade-in for the logo on launch.
    @State private var logoOpacity: Double = 0

    /// Splash size in points; everything else scales relative to this so the
    /// transform stays on the GPU rather than going through layout.
    private let splashLogoWidth: CGFloat = 280
    private let footerLogoWidth: CGFloat = 110

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    // ContentView is always in the tree; we just fade it in.
                    // Adding/removing it conditionally was making the
                    // transition look discrete despite withAnimation.
                    ContentView()
                        .environment(store)
                        .environment(location)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // Reserve space at the bottom so list content
                            // never slides under the logo footer.
                            Color.clear.frame(height: 56)
                        }
                        .opacity(contentVisible ? 1 : 0)
                        .allowsHitTesting(contentVisible)

                    Image("BaykalLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: splashLogoWidth)
                        // scaleEffect (transform) animates smoothly, unlike
                        // changing .frame which goes through layout.
                        .scaleEffect(logoMoved ? footerLogoWidth / splashLogoWidth : 1.0)
                        .opacity(logoOpacity)
                        .position(
                            x: geo.size.width / 2,
                            y: logoMoved
                                ? geo.size.height - geo.safeAreaInsets.bottom - 28
                                : geo.size.height / 2
                        )
                        .accessibilityLabel("Baykal Consulting")
                }
                .task {
                    // Fade in centered.
                    withAnimation(.easeOut(duration: 0.5)) {
                        logoOpacity = 1
                    }
                    // Hold briefly.
                    try? await Task.sleep(for: .milliseconds(900))
                    // Move + shrink + cross-fade.
                    withAnimation(.easeInOut(duration: 0.8)) {
                        logoMoved = true
                        contentVisible = true
                    }
                }
            }
        }
    }
}
