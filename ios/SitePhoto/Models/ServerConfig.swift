import Foundation

/// Compile-time constants for the Forensic server stack.
///
/// All values here are "public" by design — the Supabase publishable
/// key and the public-facing URLs are meant to ship in the client
/// bundle. The Supabase **secret** key never lives in this app; it
/// only exists as an environment variable on the Render-hosted server.
///
/// If we later add staging / preview environments, this is where the
/// switch goes (e.g. Bundle-info-driven `#if DEBUG` blocks). For now,
/// single set of production URLs.
enum ServerConfig {
    /// Supabase project URL. Used for Auth (sign-in / session refresh).
    static let supabaseURL = URL(string: "https://dshuodvmorxrdfahjtjn.supabase.co")!

    /// Supabase publishable key. Resolves to the `authenticated` role
    /// (with RLS enforced) for signed-in users. Safe to ship in the
    /// binary — equivalent to the old "anon" key in the previous
    /// Supabase API-keys generation.
    static let supabasePublishableKey = "sb_publishable_VpFmVJJ8cYf4lM5UWWJTrA_ozZxFWlt"

    /// Base URL of the Forensic Fastify server (Render-hosted). All
    /// manifest sync calls land here; the server verifies the
    /// Supabase JWT and proxies to the database via the secret key.
    static let serverURL = URL(string: "https://forensic-server.onrender.com")!
}
