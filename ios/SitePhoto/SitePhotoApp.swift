import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    /// True once the opening animation has settled the logo at the bottom
    /// of the screen. ContentView fades in at the same time.
    @State private var splashFinished = false

    /// Drives the logo's position (true = bottom footer, false = centered)
    /// and its size. Toggled inside the same withAnimation block as
    /// `splashFinished` so the move and the cross-fade happen together.
    @State private var logoMoved = false

    /// Fade-in for the logo on launch.
    @State private var logoOpacity: Double = 0

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    if splashFinished {
                        ContentView()
                            .environment(store)
                            .environment(location)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                // Reserve space at the bottom so list content
                                // never slides under the logo footer.
                                Color.clear.frame(height: 56)
                            }
                            .transition(.opacity)
                    }

                    Image("BaykalLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoMoved ? 110 : 280)
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
                    // Move to the bottom while ContentView fades in.
                    withAnimation(.easeInOut(duration: 0.7)) {
                        logoMoved = true
                        splashFinished = true
                    }
                }
            }
        }
    }
}
