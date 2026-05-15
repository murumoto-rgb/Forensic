import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store: ProjectStore
    @State private var location = LocationService()
    @State private var toastCenter = ToastCenter()

    init() {
        let toast = ToastCenter()
        let store = ProjectStore()
        store.toastCenter = toast
        _toastCenter = State(initialValue: toast)
        _store = State(initialValue: store)
    }

    /// True once the white splash screen has faded out.
    @State private var splashDone = false

    /// Reported by ContentView via .onChange(path.isEmpty). True only when
    /// the navigation stack is at its root (the projects list). Drives
    /// whether the white logo banner is shown at the bottom.
    @State private var atRoot: Bool = true

    /// Minimum time the splash stays visible — prevents a flash if iCloud
    /// is already warm and loadInitial finishes in milliseconds.
    private let minSplashDuration: TimeInterval = 1.0

    /// User-selected accent hex (palette curated in `AppearanceSettings`).
    /// Bound through `@AppStorage` so the tint live-updates everywhere
    /// the moment the user picks a new colour in Settings.
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentHex: String = AppearanceSettings.defaultAccentHex
    private var accent: Color {
        Color(bucketHex: accentHex) ?? Color(bucketHex: AppearanceSettings.defaultAccentHex)!
    }

    var body: some Scene {
        WindowGroup {
            ContentView(atRoot: $atRoot)
                .environment(store)
                .environment(location)
                .environment(toastCenter)
                .tint(accent)
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
                .overlay(alignment: .top) {
                    ToastBanner()
                        .environment(toastCenter)
                }
                .animation(.easeInOut(duration: 0.5), value: splashDone)
                .task {
                    let start = Date()
                    await store.loadInitial()
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < minSplashDuration {
                        try? await Task.sleep(for: .seconds(minSplashDuration - elapsed))
                    }
                    splashDone = true
                }
        }
    }
}

/// Full white background with the logo centered + a loading indicator
/// underneath. Covers the entire window until the app fades it out.
private struct SplashScreen: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 28) {
                Image("BaykalLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 200)
                    .accessibilityLabel("Baykal Consulting")
                ProgressView()
                    .controlSize(.regular)
                    // Match the navy from the logo so it reads as part of
                    // the same identity rather than a system grey spinner.
                    .tint(Color(red: 0.06, green: 0.16, blue: 0.31))
                Text("Please wait. First launch may take a few minutes while iCloud sets up. Do not navigate away from this screen.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.31))
                    .padding(.horizontal, 32)
            }
        }
    }
}

/// Permanent footer at the bottom of the projects list. Sits below the
/// list's scroll content with a solid grouped-background fill so list
/// rows can't scroll up underneath the logo.
private struct FooterLogoBar: View {
    var body: some View {
        Image("BaykalLogo")
            .resizable()
            .scaledToFit()
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .background(Color(.systemGroupedBackground))
            .accessibilityLabel("Baykal Consulting")
    }
}
