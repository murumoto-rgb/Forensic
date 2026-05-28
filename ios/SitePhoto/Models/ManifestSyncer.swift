import Foundation
import Observation

/// Pushes local project manifests to the Forensic server when they
/// change. Single direction for Phase 1B-2 — iOS → server only. The
/// server's project-list endpoint is what the web app reads, so this
/// is what makes iOS-captured work appear on the web.
///
/// Server-side revision tokens are tracked per-project in
/// `UserDefaults` under the prefix `sitephoto.serverRevision.`. On
/// first push for a project, `expectedRevision` is `nil` (server
/// creates the row). On subsequent pushes, the stored revision is
/// sent and rotated to whatever the server returned. On 409
/// (mismatch from another device having modified the row), the
/// syncer refetches the current revision via `GET /v1/projects/:id`
/// and retries the PUT once — that retry overwrites whatever was
/// on the server. Proper merge logic is a Phase 2+ concern;
/// pre-multi-user this never trips.
///
/// Errors surface as toasts via `ToastCenter` — sync is
/// fire-and-forget from the caller's perspective.
@Observable
@MainActor
final class ManifestSyncer {
    private let api: APIClient
    private let auth: AuthService
    private let toast: ToastCenter

    private let revisionKeyPrefix = "sitephoto.serverRevision."

    /// Project IDs currently mid-sync. Lets the UI surface a
    /// "syncing" indicator later without races.
    private(set) var inFlight: Set<UUID> = []

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

        Task {
            defer { inFlight.remove(id) }
            do {
                try await pushOnce(project: project)
            } catch APIClient.APIError.http(status: 409, _, _) {
                // Stale revision — refetch and retry once.
                do {
                    try await refetchRevisionAndRetry(project: project)
                } catch {
                    surfaceError(error, projectName: project.name)
                }
            } catch APIClient.APIError.notAuthenticated {
                // Silently skip when not signed in — the sign-in
                // sheet is already (or about to be) present.
                return
            } catch {
                surfaceError(error, projectName: project.name)
            }
        }
    }

    /// Clear all stored revisions. Called on sign-out so the next
    /// user (or a fresh sign-in by the same user) starts clean.
    func resetRevisions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(revisionKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Internals

    private func pushOnce(project: Project) async throws {
        let expectedRevision = storedRevision(for: project.id)
        let response = try await api.putProject(
            id: project.id,
            project: project,
            expectedRevision: expectedRevision
        )
        storeRevision(response.revision, for: project.id)
    }

    private func refetchRevisionAndRetry(project: Project) async throws {
        let current = try await api.getProject(id: project.id)
        storeRevision(current.revision, for: project.id)
        let response = try await api.putProject(
            id: project.id,
            project: project,
            expectedRevision: current.revision
        )
        storeRevision(response.revision, for: project.id)
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
