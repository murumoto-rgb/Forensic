import Foundation
import Observation

/// Syncs the app-wide config keys iOS knows how to push and pull
/// — `tagLibrary`, `aiRulesTemplate`, `reportBranding` (#6.2.1),
/// and `aiPromptTemplates` (#6.3.1) — between this device's
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
    private var pendingReportBranding: ReportBranding?
    private var pendingAIPromptTemplates: [AIPromptTemplate]?

    /// Debounce window. Matches the 300 ms `ProjectStore` save
    /// cadence so a coalesced burst of "edit, edit, edit" produces
    /// one push, not three.
    private static let debounceDelay: Duration = .milliseconds(300)
    private var pendingTagLibraryTask: Task<Void, Never>?
    private var pendingAIRulesTemplateTask: Task<Void, Never>?
    private var pendingReportBrandingTask: Task<Void, Never>?
    private var pendingAIPromptTemplatesTask: Task<Void, Never>?

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
        store.onReportBrandingChanged = { [weak self] branding in
            self?.queuePushReportBranding(branding)
        }
        store.onAIPromptTemplatesChanged = { [weak self] templates in
            self?.queuePushAIPromptTemplates(templates)
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
        } else {
            // Seed-on-empty (Build #5.47.1). Server has no value for
            // this key yet — push our local copy (which on a fresh
            // install is the bundled default) so the team's web
            // admin pages and any future thin clients see a baseline
            // immediately, without waiting for the engineer to
            // explicitly edit and re-save. Idempotent across devices:
            // first push wins, others get a 409 and `pushTagLibrary`'s
            // refetch-and-retry path lands the same content with the
            // freshly-pulled revision.
            await pushTagLibrary(store.tagLibrary)
        }
        if let entry = bundle.entries["aiRulesTemplate"] {
            do {
                let wire = try entry.value.decode(as: AIRulesTemplateWire.self)
                store.applyServerAIRulesTemplate(wire.text)
                storeRevision(entry.revision, for: "aiRulesTemplate")
            } catch {
                surfaceError(error, label: "AI rules template")
            }
        } else {
            // Seed-on-empty — same shape as the tagLibrary branch
            // above. Pushes whichever local value the store carries
            // (bundled default on a fresh install, or the engineer's
            // customised text on a returning install whose previous
            // push pre-dated this code).
            await pushAIRulesTemplate(store.aiRulesTemplate)
        }

        if let entry = bundle.entries["reportBranding"] {
            do {
                let wire = try entry.value.decode(as: ReportBrandingWire.self)
                store.applyServerReportBranding(wire)
                storeRevision(entry.revision, for: "reportBranding")
            } catch {
                surfaceError(error, label: "report branding")
            }
        } else if store.reportBranding.hasContent {
            // Seed-on-empty, but only when this device actually has
            // customised branding. Unlike tagLibrary there is no
            // bundled default worth pushing — seeding an all-null
            // row would serve nobody.
            await pushReportBranding(store.reportBranding)
        }

        if let entry = bundle.entries["aiPromptTemplates"] {
            do {
                let wire = try entry.value.decode(as: AIPromptTemplateLibraryWire.self)
                store.applyServerAIPromptTemplates(wire.templates)
                storeRevision(entry.revision, for: "aiPromptTemplates")
            } catch {
                surfaceError(error, label: "AI prompt templates")
            }
        } else {
            // Seed-on-empty — same philosophy as tagLibrary: a fresh
            // team gets this device's templates (the bundled starter
            // pack on a fresh install, or the engineer's customised
            // set) as the baseline the web admin page shows.
            await pushAIPromptTemplates(store.aiPromptTemplates)
        }

        // Read-only default mirrors (Build #5.48.1). iOS Swift owns
        // the canonical defaults (`AIRulesTemplate.defaultText` and
        // `TagLibrary.defaultSeeds`); on every launch we push them
        // up to a separate pair of app_config keys so the web admin
        // pages have a "Restore default" source. Upsert idempotency
        // means a no-op when the values match, and a TestFlight
        // ship with a new bundled default propagates to web on the
        // first launch of the new build.
        await pushTagLibraryDefault(TagLibrary.defaultSeeds)
        await pushAIRulesTemplateDefault(AIRulesTemplate.defaultText)
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
        pendingReportBranding = nil
        pendingAIPromptTemplates = nil
        pendingTagLibraryTask?.cancel()
        pendingAIRulesTemplateTask?.cancel()
        pendingReportBrandingTask?.cancel()
        pendingAIPromptTemplatesTask?.cancel()
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

    private func queuePushReportBranding(_ branding: ReportBranding) {
        guard auth.session != nil else { return }
        pendingReportBranding = branding
        pendingReportBrandingTask?.cancel()
        pendingReportBrandingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.pushReportBrandingIfPending()
        }
    }

    private func pushReportBrandingIfPending() async {
        guard let branding = pendingReportBranding else { return }
        pendingReportBranding = nil
        await pushReportBranding(branding)
    }

    private func queuePushAIPromptTemplates(_ templates: [AIPromptTemplate]) {
        guard auth.session != nil else { return }
        pendingAIPromptTemplates = templates
        pendingAIPromptTemplatesTask?.cancel()
        pendingAIPromptTemplatesTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.pushAIPromptTemplatesIfPending()
        }
    }

    private func pushAIPromptTemplatesIfPending() async {
        guard let templates = pendingAIPromptTemplates else { return }
        pendingAIPromptTemplates = nil
        await pushAIPromptTemplates(templates)
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

    private func pushReportBranding(_ branding: ReportBranding) async {
        let key = "reportBranding"
        guard !inFlight.contains(key) else {
            queuePushReportBranding(branding)
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let resp = try await api.putReportBranding(branding.wireValue,
                                                        expectedRevision: storedRevision(for: key))
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryReportBranding(branding)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "report branding")
        }
    }

    private func pushAIPromptTemplates(_ templates: [AIPromptTemplate]) async {
        let key = "aiPromptTemplates"
        guard !inFlight.contains(key) else {
            queuePushAIPromptTemplates(templates)
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let resp = try await api.putAIPromptTemplates(templates,
                                                           expectedRevision: storedRevision(for: key))
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryAIPromptTemplates(templates)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "AI prompt templates")
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

    private func refetchAndRetryReportBranding(_ branding: ReportBranding) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            var toPush = branding
            if let entry = bundle.entries["reportBranding"] {
                storeRevision(entry.revision, for: "reportBranding")
                // Adopt the server's logo path on conflict — iOS can't
                // change the logo over the wire, so the server's value
                // is by definition the newer intent for that field.
                // Text overrides stay local-wins (the active editor).
                if let wire = try? entry.value.decode(as: ReportBrandingWire.self) {
                    toPush.logoStoragePath = wire.logoStoragePath
                }
            } else {
                clearRevision(for: "reportBranding")
            }
            let resp = try await api.putReportBranding(toPush.wireValue,
                                                        expectedRevision: storedRevision(for: "reportBranding"))
            storeRevision(resp.revision, for: "reportBranding")
            // Keep the adopted logo path locally so the next push
            // round-trips the value the server now holds — but build
            // it from the store's *current* state, not `toPush`, so
            // any text edit the user made while this retry was in
            // flight isn't rolled back.
            if let storeRef = store {
                var local = storeRef.reportBranding
                local.logoStoragePath = toPush.logoStoragePath
                storeRef.applyServerReportBranding(local.wireValue)
            }
        } catch {
            surfaceError(error, label: "report branding")
        }
    }

    private func refetchAndRetryAIPromptTemplates(_ templates: [AIPromptTemplate]) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            if let entry = bundle.entries["aiPromptTemplates"] {
                storeRevision(entry.revision, for: "aiPromptTemplates")
            } else {
                clearRevision(for: "aiPromptTemplates")
            }
            let resp = try await api.putAIPromptTemplates(templates,
                                                           expectedRevision: storedRevision(for: "aiPromptTemplates"))
            storeRevision(resp.revision, for: "aiPromptTemplates")
        } catch {
            surfaceError(error, label: "AI prompt templates")
        }
    }

    // MARK: Default-snapshot push (Build #5.48.1)
    //
    // The `*Default` keys carry the iOS-bundled defaults exactly as
    // Swift constants. Web's "Restore default" button reads from
    // them. Nothing else writes them — the source of truth is iOS
    // code, and they're pushed up at every launch via
    // `pullAllFromServer()`. Idempotent: if the server already has
    // the same value, the upsert is a no-op content-wise.

    private func pushTagLibraryDefault(_ library: TagLibrary) async {
        let key = "tagLibraryDefault"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let resp = try await api.putTagLibraryDefault(
                library,
                expectedRevision: storedRevision(for: key)
            )
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryTagLibraryDefault(library)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "tag library default")
        }
    }

    private func pushAIRulesTemplateDefault(_ text: String) async {
        let key = "aiRulesTemplateDefault"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let resp = try await api.putAIRulesTemplateDefault(
                text,
                expectedRevision: storedRevision(for: key)
            )
            storeRevision(resp.revision, for: key)
        } catch APIClient.APIError.http(status: 409, _, _) {
            await refetchAndRetryAIRulesTemplateDefault(text)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch {
            surfaceError(error, label: "AI rules template default")
        }
    }

    private func refetchAndRetryTagLibraryDefault(_ library: TagLibrary) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            if let entry = bundle.entries["tagLibraryDefault"] {
                storeRevision(entry.revision, for: "tagLibraryDefault")
            } else {
                clearRevision(for: "tagLibraryDefault")
            }
            let resp = try await api.putTagLibraryDefault(
                library,
                expectedRevision: storedRevision(for: "tagLibraryDefault")
            )
            storeRevision(resp.revision, for: "tagLibraryDefault")
        } catch {
            surfaceError(error, label: "tag library default")
        }
    }

    private func refetchAndRetryAIRulesTemplateDefault(_ text: String) async {
        do {
            let bundle = try await api.getAppConfigBundle()
            if let entry = bundle.entries["aiRulesTemplateDefault"] {
                storeRevision(entry.revision, for: "aiRulesTemplateDefault")
            } else {
                clearRevision(for: "aiRulesTemplateDefault")
            }
            let resp = try await api.putAIRulesTemplateDefault(
                text,
                expectedRevision: storedRevision(for: "aiRulesTemplateDefault")
            )
            storeRevision(resp.revision, for: "aiRulesTemplateDefault")
        } catch {
            surfaceError(error, label: "AI rules template default")
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
