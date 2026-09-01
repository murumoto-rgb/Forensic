import Foundation
import CryptoKit
import Observation

/// Uploads project photo binaries to Cloudflare R2 via the server's
/// presigned-URL endpoints. Sibling to `ManifestSyncer` — operates
/// on the same project-save events but pushes the photo files, not
/// the manifest JSON.
///
/// Triggers:
///   * After every `ProjectStore.save(_:)` — uploads any photos
///     newly added/modified for that project that aren't already in
///     R2 (tracked via `UploadedFileTracker`).
///   * On app launch (after auth + project load) via `syncAll()` —
///     does a "what's missing?" sweep across every project so a
///     fresh install or restored device gradually backfills.
///
/// Fire-and-forget from the caller's perspective. Errors surface
/// via `ToastCenter`. The actual binary upload goes
/// **iOS → R2 directly**; the server only issues the presigned URL
/// and records the commit. The server's bandwidth bill stays at
/// zero regardless of photo size.
@Observable
@MainActor
final class PhotoSyncer {
    private let api: APIClient
    private let auth: AuthService
    private let store: ProjectStore
    private let toast: ToastCenter
    private let tracker = UploadedFileTracker()
    private let fileManager = FileManager.default

    /// Object keys currently being uploaded. Prevents two sync
    /// passes (e.g. launch sweep + a fresh save) from double-
    /// uploading the same photo.
    private(set) var inFlight: Set<String> = []

    init(api: APIClient,
         auth: AuthService,
         store: ProjectStore,
         toast: ToastCenter) {
        self.api = api
        self.auth = auth
        self.store = store
        self.toast = toast
    }

    // MARK: - Public API

    /// Upload any not-yet-uploaded binaries for this project.
    /// Fire-and-forget.
    func sync(_ project: Project) {
        guard auth.session != nil else { return }
        Task {
            await syncProject(project)
        }
    }

    /// Background sweep across every active project. Called from
    /// launch and on pull-to-refresh. Awaits the full sweep so the
    /// caller can show progress, but the caller is free to ignore
    /// the return.
    func syncAll() async {
        guard auth.session != nil else { return }
        for project in store.activeProjects {
            await syncProject(project)
        }
    }

    /// Clear the per-device "already uploaded" cache. Called on
    /// sign-out so a different user signing in on the same device
    /// doesn't believe their photos are already in someone else's
    /// R2 bucket.
    func resetUploadCache() {
        tracker.resetAll()
    }

    // MARK: - Internals

    func syncProject(_ project: Project) async {
        guard auth.session != nil, !store.isReadOnly(project), !store.hasUnsavedChanges(projectID: project.id) else { return }
        await preCheckUploadedPhotos(in: project)
        // Plans first — small N (1-5 per project), so they complete
        // in seconds even on a fresh install where the per-device
        // UploadedFileTracker is empty. The web canvas backgrounds
        // can render before the photo sweep starts.
        for plan in project.floorPlans {
            await uploadPlanIfNeeded(plan: plan, in: project)
        }
        // Photos: bulk-pre-check what R2 already has and mark those
        // in the tracker so the per-photo loop short-circuits.
        // Critical on a fresh install where the user has 1000s of
        // photos already uploaded from a previous install — without
        // the pre-check we'd do 1000s of redundant getUploadUrl →
        // R2 PUT → commitUpload round-trips.
        // Build #6.6.1: bounded-concurrency upload window. The old
        // loop uploaded strictly one object at a time — and each
        // photo is 3 sequential round-trips (getUploadUrl → R2 PUT →
        // commitUpload), so a large backfill spent nearly all its
        // wall-clock waiting on network latency. Four photos in
        // flight overlap those waits; state stays MainActor-
        // serialized and the `inFlight` set still dedupes against
        // overlapping sweeps. Width 4 is enough to hide latency
        // without saturating a field uplink or hammering the server.
        let photos = project.photos + project.trashedPhotos
        let maxConcurrent = 4
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < photos.count && nextIndex < maxConcurrent {
                let photo = photos[nextIndex]
                group.addTask { await self.uploadPhotoAndThumb(photo, in: project) }
                nextIndex += 1
            }
            while await group.next() != nil {
                if nextIndex < photos.count {
                    let photo = photos[nextIndex]
                    group.addTask { await self.uploadPhotoAndThumb(photo, in: project) }
                    nextIndex += 1
                }
            }
        }
    }

    /// One photo's upload unit — full-res then thumb, sequential
    /// within the unit so a thumb never lands before its photo.
    private func uploadPhotoAndThumb(_ photo: Photo, in project: Project) async {
        await uploadIfNeeded(photo: photo, in: project, kind: .photo)
        if photo.thumbnailFilename != nil {
            await uploadIfNeeded(photo: photo, in: project, kind: .thumb)
        }
        if photo.markupOverlayFilename != nil { await uploadIfNeeded(photo: photo, in: project, kind: .markupPng) }
        if photo.markupDrawingFilename != nil { await uploadIfNeeded(photo: photo, in: project, kind: .markupDrawing) }
    }

    /// Ask the server which of this project's photo + thumb object
    /// keys are already in R2, and mark those as uploaded in the
    /// local tracker. Reduces the per-photo loop from N network
    /// round-trips to (N / 500) + photo-actual-uploads.
    ///
    /// Skips keys the tracker already considers uploaded (no point
    /// re-checking the steady-state case). Chunks at 500 to respect
    /// the server's `SyncFilesCheckBodySchema.objectKeys.max(500)`
    /// cap. On any chunk failure, falls back silently — the per-
    /// photo loop will run normally, which is the old (correct but
    /// slow) behaviour.
    private func preCheckUploadedPhotos(in project: Project) async {
        // Logical tracker keys include the manifest filename. Replacing a plan
        // or markup must never inherit the previous image's upload receipt.
        // Verification must query object storage. A registry row can survive
        // an R2 deletion, so marking it here would permanently suppress the
        // recovery upload on a fresh tracker.
        guard let health = try? await api.projectHealth(id: project.id, verify: true) else { return }
        let keys = Self.verifiedUploadedKeys(projectId: project.id, health: health)
        tracker.markUploaded(keys)
    }

    /// Returns only assets confirmed present in object storage. Registry-only
    /// and unverified results deliberately remain eligible for re-upload.
    static func verifiedUploadedKeys(projectId: UUID,
                                     health: ProjectHealthResponse) -> [String] {
        health.assets.compactMap { asset -> String? in
            guard asset.state == "available",
                  asset.objectKey?.split(separator: "/").count == 4,
                  let entityID = UUID(uuidString: asset.entityId) else { return nil }
            return Self.objectKey(projectId: projectId, photoId: entityID, kind: asset.kind) + "/" + asset.filename
        }
    }

    private func uploadIfNeeded(photo: Photo, in project: Project, kind: FileKind) async {
        // Resolve the on-disk URL for the bytes we need to upload.
        let fileURL: URL?
        switch kind {
        case .photo:
            fileURL = store.imageURL(for: photo, in: project)
        case .thumb:
            fileURL = store.thumbnailURL(for: photo, in: project)
        case .markupPng:
            fileURL = photo.markupOverlayFilename.map { store.markupsFolder(for: project).appending(path: $0) }
        case .markupDrawing:
            fileURL = photo.markupDrawingFilename.map { store.markupsFolder(for: project).appending(path: $0) }
        case .plan: return
        }
        guard let fileURL,
              fileManager.fileExists(atPath: fileURL.path) else {
            // File missing on disk — could be a partial trash purge
            // or a half-finished import. Skip silently; the user can
            // re-capture if it matters.
            return
        }

        let objectKey = Self.objectKey(projectId: project.id, photoId: photo.id, kind: kind) + "/" + fileURL.lastPathComponent
        guard !tracker.isUploaded(objectKey), !inFlight.contains(objectKey) else { return }
        inFlight.insert(objectKey)
        defer { inFlight.remove(objectKey) }

        // Build #6.6.1: read + hash off the MainActor. With the
        // 4-wide upload window these used to interleave on the main
        // thread between network awaits — a multi-MB read + SHA-256
        // per photo is enough to drop frames during a backfill.
        let data: Data
        let sha256: String
        do {
            let url = fileURL
            (data, sha256) = try await Task.detached(priority: .utility) {
                let d = try Data(contentsOf: url)
                return (d, Self.sha256Hex(data: d))
            }.value
        } catch {
            // Local read failure is unusual but recoverable; skip
            // this object and let the next sync pass retry.
            return
        }

        // Skip if it's somehow oversized — server would 400 anyway.
        guard data.count <= FILE_MAX_BYTES else { return }

        let contentType = Self.contentType(forExtension: fileURL.pathExtension)

        do {
            let urlResp = try await api.getUploadUrl(
                projectId: project.id,
                photoId: photo.id,
                kind: kind,
                sizeBytes: data.count,
                sha256: sha256,
                contentType: contentType, sourceFilename: fileURL.lastPathComponent
            )
            guard let uploadURL = URL(string: urlResp.uploadUrl) else {
                return
            }
            try await api.uploadBytesToPresignedURL(
                uploadURL, data: data, contentType: contentType, requiredHeaders: urlResp.requiredHeaders ?? [:])
            try await api.commitUpload(
                projectId: project.id,
                objectKey: urlResp.objectKey,
                photoId: photo.id,
                kind: kind,
                sizeBytes: data.count,
                sha256: sha256, sourceFilename: fileURL.lastPathComponent
            )
            tracker.markUploaded(objectKey)
        } catch APIClient.APIError.notAuthenticated {
            // Sign-in sheet is (or about to be) showing; just stop.
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            // Project hasn't been pushed to the server yet. Happens
            // when a brand-new project's manifest sync hasn't
            // completed (per-save race) — the next syncAll sweep
            // (after pushAllToServer) will pick it up. Silently
            // skip; don't toast or log.
            return
        } catch {
            // Don't toast every per-photo failure — at hundreds of
            // photos that would spam the user. Drop a single
            // aggregate toast at most once per project per sweep.
            // (Simplest: log to console; promote to toast in a
            // follow-up if real-world usage shows we need it.)
            #if DEBUG
            print("PhotoSyncer: upload failed for \(objectKey): \(error)")
            #endif
            return
        }
    }

    /// Plan-image equivalent of `uploadIfNeeded`. Same iOS → R2
    /// direct-upload pattern; the only differences are (1) the
    /// on-disk source comes from `store.floorPlanURL(for:planID:)`
    /// rather than the photos folder, and (2) the object key uses
    /// the plan UUID in the `photoId` slot (the server's
    /// `files` table reuses the column for plan IDs when
    /// `kind == "plan"`, matching how PR #34's plans route reads
    /// it back out).
    private func uploadPlanIfNeeded(plan: FloorPlan, in project: Project) async {
        let objectKey = Self.objectKey(projectId: project.id,
                                        photoId: plan.id,
                                        kind: .plan) + "/" + plan.imageFilename

        if tracker.isUploaded(objectKey) {
            print("[PhotoSyncer] plan skip — tracker says already uploaded: \(objectKey)")
            return
        }
        if inFlight.contains(objectKey) {
            print("[PhotoSyncer] plan skip — already in flight: \(objectKey)")
            return
        }
        inFlight.insert(objectKey)
        defer { inFlight.remove(objectKey) }

        guard let fileURL = store.floorPlanURL(for: project, planID: plan.id) else {
            toast.post(
                "Plan \"\(plan.label)\": no URL on disk (manifest references it, but the rasterised image hasn't been generated yet).",
                kind: .warning
            )
            print("[PhotoSyncer] plan URL is nil for \(plan.label) (\(plan.id))")
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            toast.post(
                "Plan \"\(plan.label)\": image file missing at \(fileURL.lastPathComponent). iOS hasn't rasterised the PDF yet.",
                kind: .warning
            )
            print("[PhotoSyncer] plan file missing at \(fileURL.path)")
            return
        }

        let data: Data
        let sha256: String
        do {
            (data, sha256) = try await Task.detached(priority: .utility) {
                let bytes = try Data(contentsOf: fileURL)
                return (bytes, Self.sha256Hex(data: bytes))
            }.value
        } catch {
            toast.post("Plan \"\(plan.label)\": failed to read bytes: \(error.localizedDescription)", kind: .warning)
            print("[PhotoSyncer] plan read failed: \(error)")
            return
        }

        guard data.count <= FILE_MAX_BYTES else {
            toast.post("Plan \"\(plan.label)\": \(data.count / 1024 / 1024)MB exceeds the upload cap.", kind: .warning)
            return
        }

        let contentType = Self.contentType(forExtension: fileURL.pathExtension)
        print("[PhotoSyncer] plan upload starting: \(objectKey) — \(data.count) bytes, \(contentType)")

        do {
            let urlResp = try await api.getUploadUrl(
                projectId: project.id,
                photoId: plan.id,
                kind: .plan,
                sizeBytes: data.count,
                sha256: sha256,
                contentType: contentType, sourceFilename: fileURL.lastPathComponent
            )
            guard let uploadURL = URL(string: urlResp.uploadUrl) else {
                toast.post("Plan \"\(plan.label)\": server returned invalid upload URL.", kind: .warning)
                return
            }
            try await api.uploadBytesToPresignedURL(
                uploadURL, data: data, contentType: contentType, requiredHeaders: urlResp.requiredHeaders ?? [:])
            try await api.commitUpload(
                projectId: project.id,
                objectKey: urlResp.objectKey,
                photoId: plan.id,
                kind: .plan,
                sizeBytes: data.count,
                sha256: sha256, sourceFilename: fileURL.lastPathComponent
            )
            tracker.markUploaded(objectKey)
            print("[PhotoSyncer] plan upload OK: \(urlResp.objectKey)")
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            // Project hasn't been pushed to the server yet — same
            // race as photos. Next sweep picks it up.
            print("[PhotoSyncer] plan upload deferred (project not on server yet): \(objectKey)")
            return
        } catch {
            // Plans are few-per-project (vs hundreds of photos), so
            // an error toast per failure is appropriate noise level.
            toast.post(
                "Plan \"\(plan.label)\" upload failed: \(error.localizedDescription)",
                kind: .warning
            )
            print("[PhotoSyncer] plan upload failed for \(objectKey): \(error)")
            return
        }
    }

    // MARK: - Helpers

    static func objectKey(projectId: UUID,
                          photoId: UUID,
                          kind: FileKind) -> String {
        "\(projectId.uuidString.lowercased())/\(photoId.uuidString.lowercased())/\(kind.rawValue)"
    }

    // `nonisolated` (Build #6.6.1): statics on a @MainActor class are
    // MainActor-isolated by default, and this is called from the
    // detached read+hash task. Pure function — no state touched.
    private nonisolated static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic":         return "image/heic"
        case "png":          return "image/png"
        case "pdf":          return "application/pdf"
        default:             return "application/octet-stream"
        }
    }
}
