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
    func backfillAll() async {
        guard auth.session != nil else { return }
        guard !isRunning else { return }
        isRunning = true
        toastedProjects.removeAll()
        progress = .zero
        defer { isRunning = false }

        // Build the work list up front so progress reporting +
        // concurrency are honest.
        var work: [Work] = []
        for project in store.activeProjects {
            for photo in project.photos {
                let url = store.imageURL(for: photo, in: project)
                if !fileManager.fileExists(atPath: url.path) {
                    work.append(Work(projectId: project.id,
                                     projectName: project.name,
                                     kind: .photo(photo)))
                }
            }
            for plan in project.floorPlans {
                let url = store.planImageURL(for: plan, in: project)
                if !fileManager.fileExists(atPath: url.path) {
                    work.append(Work(projectId: project.id,
                                     projectName: project.name,
                                     kind: .plan(plan)))
                }
            }
        }

        if work.isEmpty {
            progress = .zero
            return
        }

        progress = Progress(totalFiles: work.count, downloadedFiles: 0, failedFiles: 0)

        // Bounded-concurrency runner — same shape useBatchRetag uses
        // on web. Up to `maxConcurrent` workers pull from the shared
        // iterator until exhausted.
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
            case photo(Photo)
            case plan(FloorPlan)
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
        case .photo(let photo):
            await fetchPhotoIfMissing(photo, in: project, projectName: work.projectName)
        case .plan(let plan):
            await fetchPlanIfMissing(plan, in: project, projectName: work.projectName)
        }
    }

    private func fetchPhotoIfMissing(_ photo: Photo, in project: Project, projectName: String) async {
        let localURL = store.imageURL(for: photo, in: project)
        if fileManager.fileExists(atPath: localURL.path) {
            // Race: another sweep may have just downloaded it.
            progress.downloadedFiles += 1
            return
        }
        do {
            let resp = try await api.getPhotoImageURL(projectId: project.id, photoId: photo.id)
            guard let url = URL(string: resp.url) else {
                bumpFailed()
                return
            }
            let data = try await api.downloadBytesFromPresignedURL(url)
            try fileManager.createDirectory(at: localURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            try data.write(to: localURL, options: .atomic)
            progress.downloadedFiles += 1
        } catch APIClient.APIError.notAuthenticated {
            bumpFailed()
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            // Server doesn't have the file (project pushed but photo
            // never uploaded from any device). Not actionable; skip
            // silently.
            bumpFailed()
            return
        } catch {
            bumpFailed()
            surfaceErrorOnce(error, projectId: project.id, projectName: projectName, label: "photos")
        }
    }

    private func fetchPlanIfMissing(_ plan: FloorPlan, in project: Project, projectName: String) async {
        let localURL = store.planImageURL(for: plan, in: project)
        if fileManager.fileExists(atPath: localURL.path) {
            progress.downloadedFiles += 1
            return
        }
        do {
            let resp = try await api.getPlanImageURL(projectId: project.id, planId: plan.id)
            guard let url = URL(string: resp.url) else {
                bumpFailed()
                return
            }
            let data = try await api.downloadBytesFromPresignedURL(url)
            try fileManager.createDirectory(at: localURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            try data.write(to: localURL, options: .atomic)
            progress.downloadedFiles += 1
        } catch APIClient.APIError.notAuthenticated {
            bumpFailed()
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            bumpFailed()
            return
        } catch {
            bumpFailed()
            surfaceErrorOnce(error, projectId: project.id, projectName: projectName, label: "plans")
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
