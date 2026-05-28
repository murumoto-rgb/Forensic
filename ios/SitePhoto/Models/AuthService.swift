import Foundation
import Observation
import Supabase

/// Owns the Supabase Auth session for the iOS app. Wraps the
/// `SupabaseClient` (publishable key) and surfaces a SwiftUI-friendly
/// `@Observable` view of:
///   * `isInitializing` — true on launch while we restore any
///     persisted session from the iOS Keychain.
///   * `session`        — non-nil when a user is signed in.
///   * `userEmail`      — convenience accessor for UI strings.
///
/// Sign-in / sign-up / sign-out are exposed as async throws methods
/// that propagate Supabase's own error types — `SignInSheet`
/// surfaces `error.localizedDescription` verbatim so the user sees
/// "Invalid login credentials" instead of a generic failure.
///
/// On launch, `bootstrap()` runs once: it tries to load any session
/// the Supabase SDK persisted (in Keychain) and applies it. If that
/// succeeds the user is already signed in; if not, `session` stays
/// nil and the app presents `SignInSheet`.
@Observable
@MainActor
final class AuthService {
    private(set) var session: Session?
    private(set) var isInitializing: Bool = true

    /// Underlying Supabase client. Other services (e.g. an eventual
    /// API client that signs requests with the current JWT) read the
    /// session through `currentJWT` rather than holding their own
    /// client.
    let supabase: SupabaseClient

    init() {
        // `emitLocalSessionAsInitialSession: true` opts into
        // supabase-swift's pending behaviour change (per their PR
        // #822): `auth.session` returns the locally-persisted
        // session immediately, even if expired, instead of trying
        // to refresh first. We surface the warning otherwise; with
        // this opt-in we read the local session and let the SDK's
        // background auto-refresh keep it fresh. If the refresh
        // fails (e.g. the token was revoked), the first
        // authenticated network call will return 401 and the
        // Phase 1B-2 API client will sign out at that point.
        let options = SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                emitLocalSessionAsInitialSession: true
            )
        )
        self.supabase = SupabaseClient(
            supabaseURL: ServerConfig.supabaseURL,
            supabaseKey: ServerConfig.supabasePublishableKey,
            options: options
        )
    }

    /// Called once from SitePhotoApp's launch task. Restores any
    /// persisted session (Supabase SDK stores it in Keychain by
    /// default) and then flips `isInitializing` so the UI can decide
    /// whether to present the sign-in sheet.
    func bootstrap() async {
        defer { isInitializing = false }
        do {
            let restored = try await supabase.auth.session
            self.session = restored
        } catch {
            // No persisted session, or it expired and refresh failed.
            // Either way: not signed in.
            self.session = nil
        }
    }

    /// Email + password sign-in. Throws on bad credentials, network
    /// failures, etc. — caller surfaces the error to the UI.
    func signIn(email: String, password: String) async throws {
        let newSession = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        self.session = newSession
    }

    /// Email + password sign-up. Returns `true` when Supabase requires
    /// an email confirmation step (the default Supabase configuration),
    /// in which case the UI shows a "check your inbox" message instead
    /// of dismissing. Returns `false` when sign-up immediately yields
    /// a session (e.g. confirmations disabled).
    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password
        )
        if let session = response.session {
            self.session = session
            return false
        }
        return true
    }

    /// Signs out + clears the persisted session.
    func signOut() async throws {
        try await supabase.auth.signOut()
        self.session = nil
    }

    /// Current user's email if signed in. Used by the projects-list
    /// header and the sign-out confirmation.
    var userEmail: String? {
        session?.user.email
    }

    /// Current access token. Used by the manifest-sync layer (lands
    /// in Phase 1B-2) to bearer-authenticate requests to the Forensic
    /// server. Returns nil when no session.
    var currentJWT: String? {
        session?.accessToken
    }
}
