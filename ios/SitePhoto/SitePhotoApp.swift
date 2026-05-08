import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    @State private var contentVisible = false
    @State private var logoMoved = false
    @State private var logoOpacity: Double = 0
    @State private var atRoot: Bool = true

    /// Fixed footer logo box. The image inside is scaledToFit, so a square
    /// or a wide source both end up at exactly this height — which lets us
    /// give the white band the *same* height and have the logo sit flush.
    private let footerLogoWidth:  CGFloat = 110
    private let footerLogoHeight: CGFloat = 50

    /// Splash logo is the same frame, just rendered at `splashScale`× via
    /// scaleEffect. Layout doesn't move; only the rendered pixels grow.
    private let splashScale: CGFloat = 2.8

    /// White band's visible portion above the home-indicator safe area.
    /// Matched to the logo's frame height so the band hugs the logo on
    /// top and bottom — no extra space.
    private var footerVisibleHeight: CGFloat { footerLogoHeight }

    private var logoOnscreen: Bool { !logoMoved || atRoot }

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    ContentView(atRoot: $atRoot)
                        .environment(store)
                        .environment(location)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear
                                .frame(height: atRoot ? footerVisibleHeight : 0)
                        }
                        .opacity(contentVisible ? 1 : 0)
                        .allowsHitTesting(contentVisible)

                    // White band: visible strip = logo height, plus a tail
                    // through the home-indicator safe area so the home
                    // indicator sits on white too.
                    VStack(spacing: 0) {
                        Spacer()
                        Color.white
                            .frame(height: footerVisibleHeight + geo.safeAreaInsets.bottom)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .opacity((logoMoved && atRoot) ? 1 : 0)
                    .allowsHitTesting(false)

                    Image("BaykalLogo")
                        .resizable()
                        .scaledToFit()
                        // Fixed frame, used for BOTH splash and footer.
                        // scaleEffect changes only the rendered pixels.
                        .frame(width: footerLogoWidth, height: footerLogoHeight)
                        .scaleEffect(logoMoved ? 1.0 : splashScale)
                        .opacity(logoOpacity)
                        .opacity(logoOnscreen ? 1 : 0)
                        .position(
                            x: geo.size.width / 2,
                            // Footer: place the logo's frame center at
                            // (boundary − height/2) so its bottom edge lands
                            // exactly on the safe-area boundary — flush
                            // against the home-indicator strip.
                            y: logoMoved
                                ? geo.size.height - geo.safeAreaInsets.bottom - footerLogoHeight / 2
                                : geo.size.height / 2
                        )
                        .accessibilityLabel("Baykal Consulting")
                }
                .task {
                    withAnimation(.easeOut(duration: 0.5)) {
                        logoOpacity = 1
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: 0.8)) {
                        logoMoved = true
                        contentVisible = true
                    }
                }
            }
        }
    }
}
