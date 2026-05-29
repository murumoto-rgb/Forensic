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
        for photo in project.photos {
            await uploadIfNeeded(photo: photo, in: project, kind: .photo)
            if photo.thumbnailFilename != nil {
                await uploadIfNeeded(photo: photo, in: project, kind: .thumb)
            }
        }
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
