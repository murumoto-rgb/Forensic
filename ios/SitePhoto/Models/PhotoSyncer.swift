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

    private func syncProject(_ project: Project) async {
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
        await preCheckUploadedPhotos(in: project)
        for photo in project.photos {
            await uploadIfNeeded(photo: photo, in: project, kind: .photo)
            if photo.thumbnailFilename != nil {
                await uploadIfNeeded(photo: photo, in: project, kind: .thumb)
            }
        }
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
        var unknownKeys: [String] = []
        for photo in project.photos {
            let photoKey = Self.objectKey(
                projectId: project.id, photoId: photo.id, kind: .photo)
            if !tracker.isUploaded(photoKey) {
                unknownKeys.append(photoKey)
            }
            if photo.thumbnailFilename != nil {
                let thumbKey = Self.objectKey(
                    projectId: project.id, photoId: photo.id, kind: .thumb)
                if !tracker.isUploaded(thumbKey) {
                    unknownKeys.append(thumbKey)
                }
            }
        }
        if unknownKeys.isEmpty { return }

        print("[PhotoSyncer] pre-checking \(unknownKeys.count) photo keys against R2 for project \(project.name)")

        let chunkSize = 500
        var existingCount = 0
        for chunkStart in stride(from: 0, to: unknownKeys.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, unknownKeys.count)
            let chunk = Array(unknownKeys[chunkStart..<chunkEnd])
            do {
                let resp = try await api.syncFilesCheck(objectKeys: chunk)
                tracker.markUploaded(resp.existing)
                existingCount += resp.existing.count
            } catch {
                // Per-photo loop is the fallback; idempotent on the
                // server. This is purely an optimisation; correctness
                // unaffected.
                print("[PhotoSyncer] sync-files-check chunk failed at offset \(chunkStart): \(error)")
                return
            }
        }
        print("[PhotoSyncer] pre-check done — \(existingCount)/\(unknownKeys.count) already in R2; per-photo loop will skip those")
    }

    private func uploadIfNeeded(photo: Photo, in project: Project, kind: FileKind) async {
        let objectKey = Self.objectKey(projectId: project.id,
                                        photoId: photo.id,
                                        kind: kind)

        if tracker.isUploaded(objectKey) { return }
        if inFlight.contains(objectKey) { return }
        inFlight.insert(objectKey)
        defer { inFlight.remove(objectKey) }

        // Resolve the on-disk URL for the bytes we need to upload.
        let fileURL: URL?
        switch kind {
        case .photo:
            fileURL = store.imageURL(for: photo, in: project)
        case .thumb:
            fileURL = store.thumbnailURL(for: photo, in: project)
        case .markupPng, .markupDrawing, .plan:
            // Not implemented in this PR; phase 3.
            return
        }
        guard let fileURL,
              fileManager.fileExists(atPath: fileURL.path) else {
            // File missing on disk — could be a partial trash purge
            // or a half-finished import. Skip silently; the user can
            // re-capture if it matters.
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Local read failure is unusual but recoverable; skip
            // this object and let the next sync pass retry.
            return
        }

        // Skip if it's somehow oversized — server would 400 anyway.
        guard data.count <= FILE_MAX_BYTES else { return }

        let sha256 = Self.sha256Hex(data: data)
        let contentType = Self.contentType(forExtension: fileURL.pathExtension)

        do {
            let urlResp = try await api.getUploadUrl(
                projectId: project.id,
                photoId: photo.id,
                kind: kind,
                sizeBytes: data.count,
                sha256: sha256,
                contentType: contentType
            )
            guard let uploadURL = URL(string: urlResp.uploadUrl) else {
                return
            }
            try await api.uploadBytesToPresignedURL(
                uploadURL, data: data, contentType: contentType)
            try await api.commitUpload(
                projectId: project.id,
                objectKey: urlResp.objectKey,
                photoId: photo.id,
                kind: kind,
                sizeBytes: data.count,
                sha256: sha256
            )
            tracker.markUploaded(urlResp.objectKey)
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
                                        kind: .plan)

        if tracker.isUploaded(objectKey) { return }
        if inFlight.contains(objectKey) { return }
        inFlight.insert(objectKey)
        defer { inFlight.remove(objectKey) }

        guard let fileURL = store.floorPlanURL(for: project, planID: plan.id),
              fileManager.fileExists(atPath: fileURL.path) else {
            // Plan referenced in the manifest but the rasterised image
            // file isn't on disk. Could be a manifest sync that
            // arrived before the plan-image file did (iCloud), or a
            // half-finished import. Skip; next sweep retries.
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return
        }

        guard data.count <= FILE_MAX_BYTES else { return }

        let sha256 = Self.sha256Hex(data: data)
        let contentType = Self.contentType(forExtension: fileURL.pathExtension)

        do {
            let urlResp = try await api.getUploadUrl(
                projectId: project.id,
                photoId: plan.id,
                kind: .plan,
                sizeBytes: data.count,
                sha256: sha256,
                contentType: contentType
            )
            guard let uploadURL = URL(string: urlResp.uploadUrl) else {
                return
            }
            try await api.uploadBytesToPresignedURL(
                uploadURL, data: data, contentType: contentType)
            try await api.commitUpload(
                projectId: project.id,
                objectKey: urlResp.objectKey,
                photoId: plan.id,
                kind: .plan,
                sizeBytes: data.count,
                sha256: sha256
            )
            tracker.markUploaded(urlResp.objectKey)
        } catch APIClient.APIError.notAuthenticated {
            return
        } catch APIClient.APIError.http(status: 404, _, _) {
            // Project hasn't been pushed to the server yet — same
            // race as photos. Next sweep picks it up.
            return
        } catch {
            #if DEBUG
            print("PhotoSyncer: plan upload failed for \(objectKey): \(error)")
            #endif
            return
        }
    }

    // MARK: - Helpers

    static func objectKey(projectId: UUID,
                          photoId: UUID,
                          kind: FileKind) -> String {
        "\(projectId.uuidString.lowercased())/\(photoId.uuidString.lowercased())/\(kind.rawValue)"
    }

    private static func sha256Hex(data: Data) -> String {
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
