import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    /// Drives ContentView's fade-in (1 = visible, 0 = hidden behind splash).
    @State private var contentVisible = false

    /// Drives the logo's position (true = bottom footer, false = centered)
    /// and its scale.
    @State private var logoMoved = false

    /// Fade-in for the logo on launch.
    @State private var logoOpacity: Double = 0

    /// Reported by ContentView via .onChange(path.isEmpty). True only when
    /// the navigation stack is at its root (the projects list).
    @State private var atRoot: Bool = true

    private let splashLogoWidth: CGFloat = 280
    private let footerLogoWidth: CGFloat = 110

    /// Visible height of the white footer band ABOVE the home-indicator
    /// safe area. The band actually extends further down through the safe
    /// area so the home indicator sits on white too.
    private let footerVisibleHeight: CGFloat = 64

    private var logoOnscreen: Bool {
        !logoMoved || atRoot
    }

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    ContentView(atRoot: $atRoot)
                        .environment(store)
                        .environment(location)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // Reserve space so list content doesn't slide
                            // under the white footer band. Detail pages
                            // collapse this to 0 for full-screen content.
                            Color.clear
                                .frame(height: atRoot ? footerVisibleHeight : 0)
                        }
                        .opacity(contentVisible ? 1 : 0)
                        .allowsHitTesting(contentVisible)

                    // White footer band — separate ZStack layer so it can
                    // extend through the home-indicator safe area via
                    // .ignoresSafeArea(.bottom). The safeAreaInset above
                    // only reserves layout space; this layer paints it.
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
                        .frame(width: splashLogoWidth)
                        .scaleEffect(logoMoved ? footerLogoWidth / splashLogoWidth : 1.0)
                        .opacity(logoOpacity)
                        .opacity(logoOnscreen ? 1 : 0)
                        .position(
                            x: geo.size.width / 2,
                            y: logoMoved
                                // Center the logo within the visible
                                // (above home-indicator) part of the band.
                                ? geo.size.height - geo.safeAreaInsets.bottom - footerVisibleHeight / 2
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
