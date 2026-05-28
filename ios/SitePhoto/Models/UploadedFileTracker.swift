import Foundation

/// Per-device cache of "object keys we've already successfully
/// uploaded to R2 + registered with the server's `files` table."
/// Backed by `UserDefaults` so it survives app relaunches but is
/// scoped to this install (a fresh install starts from zero and
/// re-uploads anything it has locally that the server already
/// knows about — the server's commit endpoint is idempotent, so
/// re-uploads cost bandwidth but don't corrupt state).
///
/// Keyed by the R2 object key (`<projectId>/<photoId>/<kind>`)
/// rather than by photo id alone — different `kind` values for
/// the same photo upload independently (e.g. `photo` and `thumb`
/// might land in different sync passes).
///
/// On sign-out, `resetAll()` clears the cache so a subsequent
/// sign-in (which might be a different user) doesn't believe its
/// files are already uploaded to someone else's R2.
final class UploadedFileTracker {
    private let prefix = "sitephoto.r2.uploaded."

    /// True if we've previously uploaded + committed this object key.
    /// Cheap: a single UserDefaults lookup.
    func isUploaded(_ objectKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefix + objectKey)
    }

    /// Mark the object as uploaded so future sync passes skip it.
    /// Idempotent.
    func markUploaded(_ objectKey: String) {
        UserDefaults.standard.set(true, forKey: prefix + objectKey)
    }

    /// Bulk-mark a set of keys as uploaded — called when the server
    /// tells us via `/v1/sync/files/check` that something we were
    /// about to upload is already there.
    func markUploaded(_ objectKeys: [String]) {
        let defaults = UserDefaults.standard
        for key in objectKeys {
            defaults.set(true, forKey: prefix + key)
        }
    }

    /// Forget every uploaded marker. Called on sign-out — prevents
    /// a new sign-in on the same device from skipping uploads that
    /// the new user's R2 bucket doesn't have.
    func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
