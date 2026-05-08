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

    /// Whether the logo should be visible at the bottom right now.
    /// True during the splash (`!logoMoved`) and on the projects list
    /// (`atRoot`); false on detail / nested screens.
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
                            // White footer strip on the projects list (also
                            // covers the home-indicator area). Collapses to 0
                            // on detail pages so they get the full screen.
                            // Hard-coded to white — not theme-dependent — so
                            // the logo's white background blends seamlessly
                            // even in dark mode.
                            Color.white
                                .frame(height: atRoot ? 56 : 0)
                        }
                        .opacity(contentVisible ? 1 : 0)
                        .allowsHitTesting(contentVisible)

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
                                ? geo.size.height - geo.safeAreaInsets.bottom - 28
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
