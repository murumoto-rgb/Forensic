import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store: ProjectStore
    @State private var location = LocationService()
    @State private var toastCenter = ToastCenter()
    @State private var auth = AuthService()

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
                .environment(auth)
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
                    // Auth bootstrap (restore persisted Supabase session
                    // from Keychain) runs concurrently with the project
                    // store load so the splash isn't sequentially gated.
                    async let authReady: Void = auth.bootstrap()
                    await store.loadInitial()
                    await authReady
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < minSplashDuration {
                        try? await Task.sleep(for: .seconds(minSplashDuration - elapsed))
                    }
                    splashDone = true
                }
                // Once the splash is dismissed, gate the rest of the
                // app behind a valid Supabase session. The sign-in
                // sheet auto-dismisses the moment `auth.session`
                // becomes non-nil (i.e. when the user signs in or
                // signs up + completes email confirmation).
                .fullScreenCover(isPresented: signInPresented) {
                    SignInSheet(auth: auth)
                }
        }
    }

    /// True when the splash is done AND there's no signed-in user.
    /// Binding is read-only — flipping it programmatically would be
    /// nonsensical (the cover is controlled by the auth state).
    private var signInPresented: Binding<Bool> {
        Binding(
            get: { splashDone && !auth.isInitializing && auth.session == nil },
            set: { _ in }
        )
    }
}

/// Loads the bundled `BaykalLogo` asset when available, otherwise
/// renders a "Baykal Consulting" text mark. The PNG file is intentionally
/// not committed (see commit 0451287's note) — until the user drops it
/// into `Assets.xcassets/BaykalLogo.imageset/`, this avoids the
/// "asset can't be found" runtime warning and gives a sensible
/// visible fallback.
struct BaykalLogo: View {
    var maxHeight: CGFloat
    var maxWidth: CGFloat?

    var body: some View {
        if let uiImage = UIImage(named: "BaykalLogo") {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .accessibilityLabel("Baykal Consulting")
        } else {
            Text("Baykal Consulting")
                .font(.system(size: max(12, maxHeight * 0.4),
                               weight: .semibold,
                               design: .serif))
                .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .accessibilityLabel("Baykal Consulting")
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
                BaykalLogo(maxHeight: 200, maxWidth: 280)
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

/// Permanent footer at the bottom of the projects list. The logo
/// floats on a thin material strip — small enough that it doesn't
/// crowd the projects list, but opaque enough that content scrolling
/// at the bottom of the list doesn't visually bleed through the logo.
private struct FooterLogoBar: View {
    var body: some View {
        BaykalLogo(maxHeight: 32, maxWidth: nil)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(.thinMaterial)
    }
}
