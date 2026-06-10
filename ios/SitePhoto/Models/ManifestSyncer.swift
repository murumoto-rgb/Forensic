import Foundation
import Observation

/// Pushes local project manifests to the Forensic server when they
/// change, and pulls server-side changes back. Cloud-first as of
/// Build #5.119.1 — the server is the source of truth and a
/// deterministic 3-way merge at the server's PUT boundary makes
/// concurrent web + iOS edits safe.
///
/// Per-project state in `UserDefaults`:
///  - `sitephoto.serverRevision.<uuid>` — opaque server-issued
///    optimistic-concurrency token.
///  - `sitephoto.serverBase.<uuid>` — the encoded JSON of the
///    manifest the server last confirmed we held. Sent on every
///    PUT as `baseManifest` so the server can merge against current
///    truth; advances to the server's returned merged manifest
///    after each successful push.
///
/// Push flow:
///  - First-ever push for a project: no stored base → send legacy
///    request shape (no `baseManifest`), server runs the legacy
///    create / optimistic-concurrency path, response carries the
///    new revision only. We store the just-pushed manifest as the
///    base for the next push.
///  - Subsequent pushes: send `baseManifest = storedBase`, server
///    merges, returns merged manifest in `response.project`; we
///    adopt it (write to disk via a no-hook apply) and advance both
///    revision and base.
///  - 409 is now a degraded fallback (server-side CAS retries
///    handle the common race). The legacy refetch-and-clobber
///    retry is gone — local-wins is incompatible with cloud-first.
///
/// Pull flow (`pullIfNeeded`):
///  - If local manifest equals stored base (clean) → adopt server.
///  - If local differs from stored base (dirty across relaunch
///    too, because we compare on-disk to base instead of an
///    in-memory flag) → don't blind-replace; push instead. The
///    server merge will fold both sides cleanly.
///
/// Errors surface as toasts via `ToastCenter` — sync is
/// fire-and-forget from the caller's perspective.
@Observable
@MainActor
final class ManifestSyncer {
    private let api: APIClient
    private let auth: AuthService
    private let toast: ToastCenter
    /// Set on init by SitePhotoApp so the syncer can write pulled
    /// projects back to the local store. Weak to avoid a retain
    /// cycle (store keeps a strong ref to syncer via the
    /// onAfterSave closure).
    weak var store: ProjectStore?

    private let revisionKeyPrefix = "sitephoto.serverRevision."
    /// Per-project base snapshot — the manifest the server last
    /// confirmed we held. Sent on every PUT as `baseManifest` so the
    /// server can do a 3-way merge. Encoded as JSON `Data` under
    /// `sitephoto.serverBase.<uuid>` in UserDefaults. Build #5.119.1.
    private let baseKeyPrefix = "sitephoto.serverBase."
    /// In-memory set of project IDs whose local file has been
    /// modified since the last successful push. `pullAllFromServer`
    /// skips these so an in-progress local edit isn't clobbered by
    /// a pull. Cleared on successful push. The on-disk-vs-stored-base
    /// comparison in `pullIfNeeded` is the robust cross-relaunch
    /// equivalent — this in-memory flag is the same-session
    /// short-circuit.
    private var dirty: Set<UUID> = []

    /// Project IDs currently mid-sync. Lets the UI surface a
    /// "syncing" indicator later without races.
    private(set) var inFlight: Set<UUID> = []

    /// Project IDs whose last push failed on a transient error
    /// (Build #6.30.1 — the offline retry queue). Retried on app
    /// foreground via `retryPending()`. Deliberately session-scoped
    /// (not persisted): the launch sweep's `pushAllToServer()`
    /// already re-pushes everything on cold start, and the disk-vs-
    /// base dirty check protects those projects from pulls in the
    /// meantime — so persistence would duplicate an existing
    /// guarantee. What was missing was the *within-session* retry:
    /// a field save that failed on a dead spot used to stay
    /// unsynced until relaunch or a manual "Sync now".
    private(set) var pendingRetry: Set<UUID> = []

    init(api: APIClient, auth: AuthService, toast: ToastCenter) {
        self.api = api
        self.auth = auth
        self.toast = toast
    }

    // MARK: Public API

    /// Push a single project to the server. Fire-and-forget — the
    /// caller doesn't block waiting for the network. Toasts on
    /// error.
    func sync(_ project: Project) {
        guard auth.session != nil else { return }
        let id = project.id
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        dirty.insert(id)  // local edit pending until push succeeds

        Task {
            defer { inFlight.remove(id) }
            do {
                try await pushOnce(project: project)
                dirty.remove(id)
                pendingRetry.remove(id)
            } catch APIClient.APIError.notAuthenticated {
                // Silently skip when not signed in — the sign-in
                // sheet is already (or about to be) present.
                return
            } catch {
                // Build #6.30.1: queue for the foreground retry. The
                // toast still fires so the user knows the save hasn't
                // synced yet; the retry clears it silently when the
                // network returns.
                pendingRetry.insert(id)
                surfaceError(error, projectName: project.name)
            }
        }
    }

    /// Re-push every project whose last push failed (Build #6.30.1).
    /// Called when the app returns to the foreground. Each retry uses
    /// the project's *current* in-memory state (not a stale snapshot)
    /// so edits made since the failure ride along; `pushOnce`'s merge
    /// path keeps it lossless against server-side changes.
    func retryPending() {
        guard auth.session != nil, let store, !pendingRetry.isEmpty else { return }
        let ids = pendingRetry
        for id in ids {
            guard let project = store.project(withID: id)
                    ?? store.deletedProjects.first(where: { $0.id == id }) else {
                // Project vanished locally (e.g. permanently deleted)
                // — nothing to push.
                pendingRetry.remove(id)
                continue
            }
            sync(project)
        }
    }

    /// Walk the server's project list and pull anything where the
    /// server's revision differs from what we have locally cached
    /// AND the local project isn't dirty (i.e. has no unsynced
    /// edits). Called from launch and pull-to-refresh.
    ///
    /// On 409 during a parallel push (very unlikely in practice
    /// because syncs are serialized through `inFlight`), the
    /// existing push retry path handles it; we just skip projects
    /// that are inFlight at this moment.
    func pullAllFromServer() async {
        guard auth.session != nil else { return }
        let response: ProjectListResponse
        do {
            response = try await api.listProjects()
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, projectName: "project list")
            return
        }

        for item in response.projects {
            await pullIfNeeded(item: item)
        }
    }

    /// Push every local project to the server. Idempotent — projects
    /// that match server's current revision are no-ops (server bumps
    /// revision regardless, but the wire shape is unchanged from
    /// what the server already stored).
    ///
    /// Called at launch AFTER `pullAllFromServer` so we don't race
    /// in the "server is ahead" case, and BEFORE `PhotoSyncer.syncAll`
    /// so every project exists on the server when photo uploads
    /// start asking for `/files/upload-url` (which 404s on unknown
    /// projects). Without this pass, projects created before iOS
    /// gained the manifest-sync layer (Phase 1B-2) never reach the
    /// server, and their photos generate a 404 storm on
    /// upload-url.
    func pushAllToServer() async {
        guard auth.session != nil else { return }
        guard let store else { return }
        for project in store.activeProjects {
            await pushAwait(project: project)
        }
    }

    /// Clear all stored revisions and base snapshots. Called on
    /// sign-out so the next user (or a fresh sign-in by the same
    /// user) starts clean.
    func resetRevisions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix(revisionKeyPrefix) || key.hasPrefix(baseKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        dirty.removeAll()
    }

    // MARK: Internals

    /// Cloud-first push. Sends `baseManifest = storedBase` when
    /// available (server runs 3-way merge); falls back to legacy
    /// shape on the very first push for a project (no stored base
    /// yet — the server's legacy path runs, and we capture the
    /// just-pushed manifest as the base for next time).
    private func pushOnce(project: Project) async throws {
        let expectedRevision = storedRevision(for: project.id)
        let base = storedBase(for: project.id)
        let response = try await api.putProject(
            id: project.id,
            project: project,
            expectedRevision: expectedRevision,
            baseManifest: base
        )
        storeRevision(response.revision, for: project.id)
        // Adopt the server's merged result so future edits base on
        // what the server now holds. If the server skipped merge
        // (legacy path, first push), fall back to the just-pushed
        // manifest as the new base.
        if let merged = response.project {
            storeBase(merged, for: project.id)
            store?.applyServerProject(merged)
        } else {
            storeBase(project, for: project.id)
        }
    }

    /// Awaitable equivalent of `sync(_:)` — used by
    /// `pushAllToServer()` so we know every project is on the
    /// server before kicking off photo upload.
    private func pushAwait(project: Project) async {
        let id = project.id
        if inFlight.contains(id) { return }
        inFlight.insert(id)
        dirty.insert(id)
        defer { inFlight.remove(id) }

        do {
            try await pushOnce(project: project)
            dirty.remove(id)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, projectName: project.name)
        }
    }

    private func pullIfNeeded(item: ProjectListItem) async {
        let id = item.id
        // Don't trample an in-flight push.
        if inFlight.contains(id) { return }
        // No-op when server matches local.
        if storedRevision(for: id) == item.revision { return }

        // Robust dirty check: same-session in-memory flag OR the
        // on-disk manifest differs from the stored base (survives
        // relaunch). Either way, defer to a push so the server can
        // merge — never blind-replace.
        if dirty.contains(id) || hasUnpushedLocalEdits(id: id) {
            if let project = store?.project(withID: id) {
                await pushAwait(project: project)
            }
            return
        }

        // Clean local — adopt server.
        do {
            let resp = try await api.getProject(id: id)
            storeRevision(resp.revision, for: id)
            storeBase(resp.project, for: id)
            store?.applyServerProject(resp.project)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            // Server says it's gone — could be a soft-delete or
            // access change. Skip silently for Phase 2; clean up
            // local copy in a later phase.
            return
        } catch {
            surfaceError(error, projectName: item.name)
        }
    }

    /// Compare the project's on-disk manifest to the stored base
    /// snapshot. Returns true when they differ (the user made
    /// edits the server hasn't seen yet). Returns false when there's
    /// no stored base — in that case the dirty-set in-memory flag
    /// is the only signal we have for this session.
    private func hasUnpushedLocalEdits(id: UUID) -> Bool {
        guard let baseData = UserDefaults.standard.data(forKey: baseKey(for: id)) else {
            return false
        }
        guard let project = store?.project(withID: id) else {
            return false
        }
        guard let localData = try? encoder().encode(project) else {
            return false
        }
        // Re-encode both through a canonical encoder so key-order
        // differences from old saves don't register as edits.
        guard let canonicalBase = canonicalize(baseData),
              let canonicalLocal = canonicalize(localData) else {
            return localData != baseData
        }
        return canonicalLocal != canonicalBase
    }

    /// Decode-then-re-encode through the same encoder so two
    /// equivalent JSON blobs compare equal regardless of dictionary
    /// key order. Used only by the dirty check.
    private func canonicalize(_ data: Data) -> Data? {
        guard let project = try? decoder().decode(Project.self, from: data) else {
            return nil
        }
        return try? encoder().encode(project)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func storedRevision(for id: UUID) -> String? {
        UserDefaults.standard.string(forKey: revisionKey(for: id))
    }

    private func storeRevision(_ revision: String, for id: UUID) {
        UserDefaults.standard.set(revision, forKey: revisionKey(for: id))
    }

    private func revisionKey(for id: UUID) -> String {
        revisionKeyPrefix + id.uuidString.lowercased()
    }

    private func storedBase(for id: UUID) -> Project? {
        guard let data = UserDefaults.standard.data(forKey: baseKey(for: id)) else {
            return nil
        }
        return try? decoder().decode(Project.self, from: data)
    }

    private func storeBase(_ project: Project, for id: UUID) {
        guard let data = try? encoder().encode(project) else { return }
        UserDefaults.standard.set(data, forKey: baseKey(for: id))
    }

    private func baseKey(for id: UUID) -> String {
        baseKeyPrefix + id.uuidString.lowercased()
    }

    private func surfaceError(_ error: Error, projectName: String) {
        let message: String
        if let apiError = error as? APIClient.APIError {
            message = "Sync failed for \"\(projectName)\": \(apiError.localizedDescription)"
        } else {
            message = "Sync failed for \"\(projectName)\": \(error.localizedDescription)"
        }
        toast.post(message, kind: .warning)
    }
}
