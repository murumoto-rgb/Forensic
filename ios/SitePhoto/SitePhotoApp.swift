import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    /// True once the white splash screen has faded out.
    @State private var splashDone = false

    /// Reported by ContentView via .onChange(path.isEmpty). True only when
    /// the navigation stack is at its root (the projects list). Drives
    /// whether the white logo banner is shown at the bottom.
    @State private var atRoot: Bool = true

    var body: some Scene {
        WindowGroup {
            ContentView(atRoot: $atRoot)
                .environment(store)
                .environment(location)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if atRoot {
                        FooterLogoBar()
                    }
                }
                .overlay {
                    if !splashDone {
                        SplashScreen()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: splashDone)
                .task {
                    // Hold the splash for ~1.3s, then cross-fade to main.
                    try? await Task.sleep(for: .milliseconds(1300))
                    splashDone = true
                }
        }
    }
}

/// Full white background with the logo centered. Covers the entire window
/// (including the status bar and home-indicator strip) until the app fades
/// it out.
private struct SplashScreen: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            Image("BaykalLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 200)
                .accessibilityLabel("Baykal Consulting")
        }
    }
}

/// Permanent banner at the bottom of the projects list. Full-width white
/// strip that extends through the home-indicator safe area, with the logo
/// centered inside.
private struct FooterLogoBar: View {
    var body: some View {
        Image("BaykalLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background {
                // .ignoresSafeArea(.bottom) on the background extends the
                // white through the home-indicator strip below the inset.
                Color.white.ignoresSafeArea(edges: .bottom)
            }
            .accessibilityLabel("Baykal Consulting")
    }
}
