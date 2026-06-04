import Foundation
import Observation

/// Syncs the two app-wide config keys iOS knows how to push and pull
/// — `tagLibrary` and `aiRulesTemplate` — between this device's
/// `ProjectStore` and the Forensic server's `/v1/config` endpoint
/// (Build #5.36.1; backed by the `app_config` Supabase table from
/// migration 0004).
///
/// Sync model:
/// - **Pull on launch.** After the auth bootstrap finishes, fetch
///   the bundle. For every key the server has, overwrite the local
///   value via `ProjectStore.applyServer*` (bypasses the change
///   hook so the pull doesn't echo back as a push). Cache the
///   returned `revision` per key in `UserDefaults` so subsequent
///   pushes can claim it.
/// - **Push on mutation.** `SitePhotoApp.init` wires
///   `store.onTagLibraryChanged` / `onAIRulesTemplateChanged` to
///   this syncer's queue methods. Each mutation drops the value
///   into a debounced send window (300 ms — matches the
///   `ProjectStore.save(_:)` cadence). On send, the cached
///   revision is included as `expectedRevision`; on 409 we refetch
///   and retry once with the freshly-pulled revision.
///
/// Errors surface as toasts. The syncer is fire-and-forget from the
/// caller's perspective — `ProjectStore` mutations don't await it.
@Observable
@MainActor
final class AppConfigSyncer {
    private let api: APIClient
    private let auth: AuthService
    private let toast: ToastCenter
    /// Set on init by `SitePhotoApp` so the syncer can apply pulled
    /// values back. Weak to avoid a retain cycle (store keeps a
    /// strong ref to syncer via the on-changed closures).
    weak var store: ProjectStore?

    private let revisionKeyPrefix = "sitephoto.appConfigRevision."

    /// Pending values keyed by `app_config` key. Coalesces multiple
    /// rapid mutations into a single push (e.g. the user edits a
    /// few tag library rows in quick succession — only the final
    /// state hits the network).
    private var pendingTagLibrary: TagLibrary?
    private var pendingAIRulesTemplate: String?

    /// Debounce window. Matches the 300 ms `ProjectStore` save
    /// cadence so a coalesced burst of "edit, edit, edit" produces
    /// one push, not three.
    private static let debounceDelay: Duration = .milliseconds(300)
    private var pendingTagLibraryTask: Task<Void, Never>?
    private var pendingAIRulesTemplateTask: Task<Void, Never>?

    /// Keys currently mid-push. Lets the UI surface a "syncing"
    /// indicator later without races. Same pattern `ManifestSyncer`
    /// uses for project IDs.
    private(set) var inFlight: Set<String> = []

    init(api: APIClient, auth: AuthService, toast: ToastCenter) {
        self.api = api
        self.auth = auth
        self.toast = toast
    }

    // MARK: Public API

    /// Wire the syncer to a `ProjectStore`. Called once at app boot
    /// by `SitePhotoApp.init`. After this returns, every
    /// tagLibrary / aiRulesTemplate mutation through the store
    /// triggers a debounced push.
    func bindToStore(_ store: ProjectStore) {
        self.store = store
        store.onTagLibraryChanged = { [weak self] library in
            self?.queuePushTagLibrary(library)
        }
        store.onAIRulesTemplateChanged = { [weak self] text in
            self?.queuePushAIRulesTemplate(text)
        }
    }

    /// Pull every known key from the server and apply locally. Called
    /// at launch after the auth bootstrap completes (same pattern
    /// `ManifestSyncer.pullAllFromServer()` uses for projects).
    /// No-ops cleanly when not signed in or when the server has
    /// nothing for this team yet.
    func pullAllFromServer() async {
        guard auth.session != nil else { return }
        guard let store else { return }
        let bundle: AppConfigBundleResponse
        do {
            bundle = try await api.getAppConfigBundle()
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "app config")
            return
        }

        if let entry = bundle.entries["tagLibrary"] {
            do {
                let library = try entry.value.decode(as: TagLibrary.self)
                store.applyServerTagLibrary(library)
                storeRevision(entry.revision, for: "tagLibrary")
            } catch {
                surfaceError(error, label: "tag library")
            }
        }
        if let entry = bundle.entries["aiRulesTemplate"] {
            do {
                let wire = try entry.value.decode(as: AIRulesTemplateWire.self)
                store.applyServerAIRulesTemplate(wire.text)
                storeRevision(entry.revision, for: "aiRulesTemplate")
            } catch {
                surfaceError(error, label: "AI rules template")
            }
        }
    }

    /// Clear all stored revisions. Called on sign-out so the next
    /// user (or a fresh sign-in by the same user) starts clean.
    /// Same shape as `ManifestSyncer.resetRevisions()`.
    func resetRevisions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(revisionKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        pendingTagLibrary = nil
        pendingAIRulesTemplate = nil
        pendingTagLibraryTask?.cancel()
        pendingAIRulesTemplateTask?.cancel()
    }

    // MARK: Queue + debounce

    private func queuePushTagLibrary(_ library: TagLibrary) {
        guard auth.session != nil else { return }
        pendingTagLibrary = library
        pendingTagLibraryTask?.cancel()
        pendingTagLibraryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.pushTagLibraryIfPending()
        }
    }

    private func queuePushAIRulesTemplate(_ text: String) {
        guard auth.session != nil else { return }
        pendingAIRulesTemplate = text
        pendingAIRulesTemplateTask?.cancel()
        pendingAIRulesTemplateTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.pushAIRulesTemplateIfPending()
        }
    }

    private func pushTagLibraryIfPending() async {
        guard let library = pendingTagLibrary else { return }
        pendingTagLibrary = nil
        await pushTagLibrary(library)
    }

    private func pushAIRulesTemplateIfPending() async {
        guard let text = pendingAIRulesTemplate else { return }
        pendingAIRulesTemplate = nil
        await pushAIRulesTemplate(text)
    }

    // MARK: Push + 409 retry

    private func pushTagLibrary(_ library: TagLibrary) async {
        let key = "tagLibrary"
        guard !inFlight.contains(key) else {
            // Re-queue — the next debounce window will pick it up.
            queuePushTagLibrary(library)
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let resp = try await api.putTagLibrary(library,
                                                    expectedRevision: storedRevision(for: key))
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryTagLibrary(library)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "tag library")
        }
    }

    private func pushAIRulesTemplate(_ text: String) async {
        let key = "aiRulesTemplate"
        guard !inFlight.contains(key) else {
            queuePushAIRulesTemplate(text)
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let resp = try await api.putAIRulesTemplate(text,
                                                         expectedRevision: storedRevision(for: key))
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryAIRulesTemplate(text)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "AI rules template")
        }
    }

    private func refetchAndRetryTagLibrary(_ library: TagLibrary) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            if let entry = bundle.entries["tagLibrary"] {
                storeRevision(entry.revision, for: "tagLibrary")
            } else {
                clearRevision(for: "tagLibrary")
            }
            let resp = try await api.putTagLibrary(library,
                                                    expectedRevision: storedRevision(for: "tagLibrary"))
            storeRevision(resp.revision, for: "tagLibrary")
        } catch {
            surfaceError(error, label: "tag library")
        }
    }

    private func refetchAndRetryAIRulesTemplate(_ text: String) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            if let entry = bundle.entries["aiRulesTemplate"] {
                storeRevision(entry.revision, for: "aiRulesTemplate")
            } else {
                clearRevision(for: "aiRulesTemplate")
            }
            let resp = try await api.putAIRulesTemplate(text,
                                                         expectedRevision: storedRevision(for: "aiRulesTemplate"))
            storeRevision(resp.revision, for: "aiRulesTemplate")
        } catch {
            surfaceError(error, label: "AI rules template")
        }
    }

    // MARK: Revision storage

    private func storedRevision(for key: String) -> String? {
        UserDefaults.standard.string(forKey: revisionKeyPrefix + key)
    }

    private func storeRevision(_ revision: String, for key: String) {
        UserDefaults.standard.set(revision, forKey: revisionKeyPrefix + key)
    }

    private func clearRevision(for key: String) {
        UserDefaults.standard.removeObject(forKey: revisionKeyPrefix + key)
    }

    private func surfaceError(_ error: Error, label: String) {
        let message: String
        if let apiError = error as? APIClient.APIError {
            message = "Sync failed for \(label): \(apiError.localizedDescription)"
        } else {
            message = "Sync failed for \(label): \(error.localizedDescription)"
        }
        toast.post(message, kind: .warning)
    }
}
