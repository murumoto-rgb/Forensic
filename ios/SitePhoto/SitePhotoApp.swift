import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store: ProjectStore
    @State private var location = LocationService()
    @State private var toastCenter = ToastCenter()
    @State private var auth = AuthService()
    @State private var syncer: ManifestSyncer
    @State private var photoSyncer: PhotoSyncer
    @State private var appConfigSyncer: AppConfigSyncer
    @State private var backfillService: BinaryBackfillService

    init() {
        let toast = ToastCenter()
        let store = ProjectStore()
        let auth = AuthService()
        let api = APIClient(auth: auth)
        let syncer = ManifestSyncer(api: api, auth: auth, toast: toast)
        syncer.store = store          // Phase 2 pull-from-server writeback
        let photoSyncer = PhotoSyncer(api: api,
                                       auth: auth,
                                       store: store,
                                       toast: toast)
        let appConfigSyncer = AppConfigSyncer(api: api, auth: auth, toast: toast)
        let backfillService = BinaryBackfillService(api: api,
                                                     auth: auth,
                                                     store: store,
                                                     toast: toast)
        store.toastCenter = toast
        // Lets the AI-tagging dispatch reach the team-server proxy when
        // the user has flipped the Settings toggle on (Build #5.33.1).
        store.apiClient = api
        // Wire saves → manifest sync + photo upload. Fire-and-forget;
        // each runs its own retries / toast policy.
        store.onAfterSave = { [weak syncer, weak photoSyncer] project in
            syncer?.sync(project)
            photoSyncer?.sync(project)
        }
        // Hook tagLibrary / aiRulesTemplate mutations to the app-
        // config syncer (Build #5.36.1). Setting up via the syncer's
        // own binder method keeps the closure capture inside the
        // syncer rather than this constructor.
        appConfigSyncer.bindToStore(store)
        _toastCenter = State(initialValue: toast)
        _store = State(initialValue: store)
        _auth = State(initialValue: auth)
        _syncer = State(initialValue: syncer)
        _photoSyncer = State(initialValue: photoSyncer)
        _appConfigSyncer = State(initialValue: appConfigSyncer)
        _backfillService = State(initialValue: backfillService)
    }

    /// True once the white splash screen has faded out.
    @State private var splashDone = false

    /// Drives the foreground retry of failed manifest pushes
    /// (Build #6.30.1 — the offline retry queue).
    @Environment(\.scenePhase) private var scenePhase

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
            ContentView()
                .environment(store)
                .environment(location)
                .environment(toastCenter)
                .environment(auth)
                .environment(syncer)
                .environment(photoSyncer)
                .environment(appConfigSyncer)
                .environment(backfillService)
                .tint(accent)
                .overlay {
                    if !splashDone {
                        // SplashScreen is rendered inside `.overlay`,
                        // which makes it a sibling of ContentView — it
                        // doesn't inherit environment values applied
                        // below it in the modifier chain. Pass `store`
                        // explicitly so the live `loadStatus` line works.
                        SplashScreen(store: store)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    ToastBanner()
                        .environment(toastCenter)
                }
                .animation(.easeInOut(duration: 0.5), value: splashDone)
                // Build #6.30.1: a save that failed on a dead spot
                // used to stay unsynced until relaunch or a manual
                // "Sync now". Returning to the foreground is the
                // natural "network is probably back" moment — retry
                // the queue then. No-op when the queue is empty.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, splashDone {
                        syncer.retryPending()
                    }
                }
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

                    // After splash dismisses, kick off the launch
                    // sync sweep: pull → push → photo upload.
                    //
                    //  * pull first so we don't trample server-side
                    //    edits with our local state.
                    //  * push second so every local project exists
                    //    on the server BEFORE PhotoSyncer asks for
                    //    upload URLs (the upload-url endpoint 404s
                    //    when the project isn't in the projects
                    //    table — happens for projects created before
                    //    Phase 1B-2 shipped that never had their
                    //    manifest synced).
                    //  * photo upload last, once everything the
                    //    server cares about is in place.
                    if auth.session != nil {
                        Task {
                            // App config first — the manifest pull may
                            // surface projects that reference tag-
                            // library IDs the local seed doesn't carry
                            // yet, and pulling the library first means
                            // those references resolve cleanly.
                            await appConfigSyncer.pullAllFromServer()
                            await syncer.pullAllFromServer()
                            await syncer.pushAllToServer()
                            await photoSyncer.syncAll()
                            // Backfill any photos / plans whose
                            // manifest is present but whose binary
                            // never landed locally (simulator,
                            // fresh install, restored device). Last
                            // step so manifests + uploads finish
                            // first — backfill is the gentlest
                            // operation, no chance to interfere with
                            // the user's edits.
                            await backfillService.backfillAll()
                        }
                    }
                }
                // Once the splash is dismissed, gate the rest of the
                // app behind a valid Supabase session. The sign-in
                // sheet auto-dismisses the moment `auth.session`
                // becomes non-nil (i.e. when the user signs in or
                // signs up + completes email confirmation).
                .fullScreenCover(isPresented: signInPresented) {
                    SignInSheet(auth: auth)
                }
                // Trigger pull-from-server + photo upload sweep
                // whenever a session becomes available — either
                // because Keychain restore succeeded (covered by the
                // launch trigger above) OR the user just signed in
                // via the SignInSheet (NOT covered by the launch
                // trigger, because at the time it ran `auth.session`
                // was still nil — bootstrap had completed but the
                // user hadn't authenticated yet). Both passes are
                // idempotent so a double-fire on the persisted-
                // session case is harmless.
                .onChange(of: auth.session?.user.id) { _, newUserId in
                    guard newUserId != nil else { return }
                    Task {
                        await appConfigSyncer.pullAllFromServer()
                        await syncer.pullAllFromServer()
                        await syncer.pushAllToServer()
                        await photoSyncer.syncAll()
                        await backfillService.backfillAll()
                    }
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
/// Renders the current `ProjectStore.loadStatus` so the engineer can
/// see which stage is running (or stuck) on a slow launch.
///
/// `store` is passed in as a parameter rather than read from
/// `@Environment` because SwiftUI's `.overlay { … }` content does
/// not inherit environment values applied to the modified view (only
/// values applied to the outer composite are visible). The
/// `@Observable` macro means property reads inside `body` still
/// drive re-renders when `store.loadStatus` changes.
private struct SplashScreen: View {
    let store: ProjectStore

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 24) {
                BaykalLogo(maxHeight: 200, maxWidth: 280)
                ProgressView()
                    .controlSize(.regular)
                    // Match the navy from the logo so it reads as part of
                    // the same identity rather than a system grey spinner.
                    .tint(Color(red: 0.06, green: 0.16, blue: 0.31))
                // Live status from ProjectStore.loadInitial() — updates
                // through "Checking iCloud Drive…", "Loading projects…",
                // etc. as each stage runs.
                Text(store.loadStatus)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.31))
                    .padding(.horizontal, 32)
                Text("First launch can take a few minutes while iCloud sets up. Do not navigate away from this screen. If \"Checking iCloud Drive…\" stays for more than 2 minutes, that's a sign iOS's iCloud daemon is stuck — usually only seen in the simulator. Force-quit + relaunch the app, or run on a real device.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.31).opacity(0.7))
                    .padding(.horizontal, 32)
            }
        }
    }
}

