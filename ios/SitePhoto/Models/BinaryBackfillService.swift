import Foundation
import Observation

/// Downloads missing photo + plan binaries from Cloudflare R2 onto a
/// device that has the manifest locally but not the actual files
/// (Build #5.49.1). Sibling to `PhotoSyncer` — operates on the same
/// projects but in the opposite direction: PhotoSyncer pushes new
/// captures up to R2, this pulls existing R2 objects back down.
///
/// Triggered after launch sync sweep, once auth + the manifest pull
/// have finished. Walks every project, looks for photos / plans
/// whose local file is missing, and fetches them via the server's
/// presigned-URL endpoints (same shape the web uses). No-ops cleanly
/// on a device that's already fully populated — every photo's
/// local-file check passes the `fileExists` guard before any
/// network is involved.
///
/// Fire-and-forget from the caller's perspective. Error toasts are
/// rate-limited (one per project per sweep) so a sustained R2
/// outage doesn't spam the user.
///
/// Use cases:
///  * **iOS Simulator** — no iCloud Drive; without backfill, plans
///    + photos sat as "missing" placeholders forever.
///  * **Fresh install on a real device** — same issue once iCloud
///    isn't carrying the binaries (e.g. user signed into a
///    different iCloud account on a new phone).
///  * **Restored device** — iCloud may take hours; backfill pulls
///    from R2 immediately so the user can review their work
///    without waiting on Apple's restore daemon.
@Observable
@MainActor
final class BinaryBackfillService {
    private let api: APIClient
    private let auth: AuthService
    private let store: ProjectStore
    private let toast: ToastCenter
    private let fileManager = FileManager.default

    /// Cap on parallel downloads. Mirrors PhotoSyncer's concurrency
    /// cap so the two services don't compete for bandwidth.
    private let maxConcurrent = 3

    /// Projects whose backfill we've already toasted an error for in
    /// the current sweep. Resets on each `backfillAll()` invocation.
    private var toastedProjects: Set<UUID> = []

    /// `true` while a backfill sweep is in flight. Lets the UI
    /// surface a "downloading…" indicator and prevents two sweeps
    /// from running concurrently.
    private(set) var isRunning: Bool = false
    /// Counts surfaced to the UI for the sticky progress chip.
    private(set) var progress: Progress = .zero

    struct Progress: Sendable {
        var totalFiles: Int = 0
        var downloadedFiles: Int = 0
        var failedFiles: Int = 0
        static let zero = Progress()
    }

    init(api: APIClient, auth: AuthService, store: ProjectStore, toast: ToastCenter) {
        self.api = api
        self.auth = auth
        self.store = store
        self.toast = toast
    }

    /// Walk every active project and download any missing photo /
    /// plan binaries. Idempotent — every download checks the local
    /// file first.
    func backfillAll() async { await backfill(projects: store.activeProjects) }

    func backfillProject(_ project: Project) async { await backfill(projects: [project]) }

    private func backfill(projects: [Project]) async {
        guard auth.session != nil else {
            print("[BinaryBackfill] skipped: not signed in")
            return
        }
        guard !isRunning else {
            print("[BinaryBackfill] skipped: already running")
            return
        }
        isRunning = true
        toastedProjects.removeAll()
        progress = .zero
        defer { isRunning = false }
        print("[BinaryBackfill] sweep starting across \(store.activeProjects.count) active project(s)")

        // Build the work list up front so progress reporting +
        // concurrency are honest. Thumbs are NOT network work items —
        // they're regenerated locally from the full image after the
        // download sweep (see the thumb pass below), which avoids a
        // redundant network round trip (the server's thumb endpoint
        // just falls back to the full image anyway, since iOS only
        // ever uploads the `photo` kind).
        var work: [Work] = []
        for project in projects {
            for asset in store.localAssets(in: project) where asset.kind != .thumb {
                if !fileManager.fileExists(atPath: asset.url.path) {
                    work.append(Work(projectId: project.id, projectName: project.name, kind: .asset(asset)))
                }
            }
        }

        // Network sweep for missing photos + plans (if any).
        if !work.isEmpty {
            print("[BinaryBackfill] queued \(work.count) missing file(s) for download")
            progress = Progress(totalFiles: work.count, downloadedFiles: 0, failedFiles: 0)

            // Bounded-concurrency runner — same shape useBatchRetag
            // uses on web. Up to `maxConcurrent` workers pull from the
            // shared iterator until exhausted.
            await withTaskGroup(of: Void.self) { group in
                var iterator = work.makeIterator()
                func launchNext() -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask { [self] in
                        await processOne(item)
                    }
                    return true
                }
                for _ in 0..<maxConcurrent { if !launchNext() { break } }
                for await _ in group { _ = launchNext() }
            }
        }

        // Local thumb-regeneration pass (Build #5.53.1, moved off
        // the main actor in #5.54.1). Runs AFTER the download sweep
        // so every full image that was going to land is on disk.
        // For each photo whose manifest names a thumb that's missing
        // locally, regenerate it from the full image — no network.
        // This is what makes the photo LIST show real thumbnails
        // instead of grey placeholders; the list renders the thumb
        // file, not the full image (which only the lightbox loads).
        //
        // Building the (imagePath, thumbPath) work list happens on
        // MainActor (reads `store.activeProjects` + per-project
        // helpers), but the heavy CG decode / downsample / encode
        // work runs in a detached background task so the UI stays
        // responsive while 1000+ thumbs process.
        var thumbWorkList: [ThumbWork] = []
        for project in projects {
            for photo in project.photos + project.trashedPhotos {
                guard let thumbURL = store.thumbnailURL(for: photo, in: project),
                      !fileManager.fileExists(atPath: thumbURL.path) else { continue }
                let imageURL = store.imageURL(for: photo, in: project)
                thumbWorkList.append(ThumbWork(
                    imagePath: imageURL.path,
                    thumbPath: thumbURL.path
                ))
            }
        }
        let snapshot = thumbWorkList   // immutable copy captured by the detached task
        let (thumbsRegenerated, thumbsStillMissing) = await Task.detached(priority: .background) {
            var regen = 0
            var missing = 0
            for w in snapshot {
                if Self.regenerateThumbnail(imagePath: w.imagePath, thumbPath: w.thumbPath) {
                    regen += 1
                } else {
                    missing += 1
                }
            }
            return (regen, missing)
        }.value
        if thumbsRegenerated > 0 || thumbsStillMissing > 0 {
            print("[BinaryBackfill] thumb pass: regenerated \(thumbsRegenerated), still missing \(thumbsStillMissing) (full image absent)")
        }

        // Summary toast — single per-sweep notification so the user
        // can confirm the run happened even when no individual error
        // toast fires. The chip in the projects-list footer also
        // stays visible after completion (Build #5.50.1) so the
        // counts persist visually.
        let downloaded = progress.downloadedFiles
        let failed = progress.failedFiles
        let total = progress.totalFiles

        if total == 0 && thumbsRegenerated == 0 {
            print("[BinaryBackfill] sweep done: nothing missing locally")
            toast.post("Backfill: nothing missing locally — all files already on disk.", kind: .info)
            return
        }

        let thumbTail = thumbsRegenerated > 0 ? " Rebuilt \(thumbsRegenerated) thumbnail(s)." : ""
        let summary: String
        if failed == 0 {
            summary = "Backfill: downloaded \(downloaded) of \(total) files.\(thumbTail)"
        } else if downloaded > 0 {
            summary = "Backfill: downloaded \(downloaded) of \(total) files.\(thumbTail) \(failed) couldn't be downloaded — they may not have been uploaded from any device yet."
        } else {
            summary = "Backfill couldn't download any of \(total) missing files.\(thumbTail) Likely those files were never uploaded to the backend, or the server hasn't recorded them in the files table yet."
        }
        let kind: Toast.Kind = failed > 0 ? .warning : .info
        toast.post(summary, kind: kind)
    }

    /// Reset any state that's tied to the current sign-in. Called from
    /// Settings → Sign out so the next user starts clean.
    func reset() {
        toastedProjects.removeAll()
        progress = .zero
    }

    // MARK: - Internals

    private struct Work: Sendable {
        let projectId: UUID
        let projectName: String
        let kind: Kind
        enum Kind: Sendable {
            case asset(LocalProjectAsset)
        }
    }

    /// Path-only unit of work for the off-main thumb-regen pass.
    /// `Sendable` because it holds only `String` values, so a
    /// `Task.detached` can capture an array of these without
    /// crossing actor boundaries with reference types.
    private struct ThumbWork: Sendable {
        let imagePath: String
        let thumbPath: String
    }

    /// Background-safe thumbnail regenerator (Build #5.54.1). Pure
    /// file I/O + Core Graphics / ImageIO — no observable-state
    /// access, no actor isolation needed. Called from a detached
    /// background Task in `backfillAll()`'s thumb pass so the main
    /// thread stays responsive while 1000+ thumbs process.
    ///
    /// Returns true when a thumb file ended up on disk (either
    /// already existed or was just written); false when the full
    /// image was absent or the downsample failed.
    nonisolated private static func regenerateThumbnail(
        imagePath: String,
        thumbPath: String
    ) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: thumbPath) { return true }
        guard fm.fileExists(atPath: imagePath),
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
              let thumbData = ProjectStore.makeThumbnail(from: imageData, maxPixelSize: 256) else {
            return false
        }
        let thumbURL = URL(fileURLWithPath: thumbPath)
        do {
            try fm.createDirectory(at: thumbURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try thumbData.write(to: thumbURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func processOne(_ work: Work) async {
        // Resolve the project from store at execution time — the
        // store may have updated since we queued (project pulled,
        // photo removed, etc.). If the project is gone, skip.
        guard let project = store.activeProjects.first(where: { $0.id == work.projectId }) else {
            return
        }
        switch work.kind {
        case .asset(let asset):
            await fetchAssetIfMissing(asset, in: project)
        }
    }

    private func fetchAssetIfMissing(_ asset: LocalProjectAsset, in project: Project) async {
        if fileManager.fileExists(atPath: asset.url.path) {
            progress.downloadedFiles += 1
            return
        }
        do {
            let response = try await api.assetURL(projectID: project.id, asset: asset)
            guard let url = URL(string: response.url) else { bumpFailed(); return }
            let data = try await api.downloadBytesFromPresignedURL(url)
            // An edit or restore while the network was busy invalidates the
            // destination. Never write new plan bytes under an old filename.
            guard let latest = store.project(withID: project.id),
                  store.localAssets(in: latest).contains(where: { $0.id == asset.id && $0.filename == asset.filename }) else {
                bumpFailed(); return
            }
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: asset.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: asset.url, options: .atomic)
            }.value
            progress.downloadedFiles += 1
        } catch {
            bumpFailed()
            surfaceErrorOnce(error, projectId: project.id, projectName: project.name, label: asset.filename)
        }
    }

    private func bumpFailed() {
        progress.failedFiles += 1
    }

    private func surfaceErrorOnce(_ error: Error, projectId: UUID, projectName: String, label: String) {
        guard !toastedProjects.contains(projectId) else { return }
        toastedProjects.insert(projectId)
        let message: String
        if let apiError = error as? APIClient.APIError {
            message = "Couldn't download \(label) for \"\(projectName)\": \(apiError.localizedDescription)"
        } else {
            message = "Couldn't download \(label) for \"\(projectName)\": \(error.localizedDescription)"
        }
        toast.post(message, kind: .warning)
    }
}
