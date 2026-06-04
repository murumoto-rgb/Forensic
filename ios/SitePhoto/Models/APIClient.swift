import Foundation

/// Thin REST client for the Forensic Fastify server.
///
/// Authenticates every request with the current Supabase JWT
/// (read live from `AuthService.currentJWT`, so token refresh by
/// supabase-swift is picked up automatically). On 401 the client
/// surfaces the error to the caller but does NOT auto-signout —
/// that would cascade-kick the user on any transient token blip
/// (rotation race, brief Supabase outage, web sign-out side-
/// effects). See the 401 branch in `send(...)` for details.
///
/// Date encoding/decoding is ISO-8601 (the wire format declared
/// in `packages/shared/src/validation.ts`). This is deliberately
/// different from `ProjectStore`'s on-disk encoder (which uses
/// the default Apple timestamp format) — server interop demands
/// ISO; on-disk backwards-compat demands deferredToDate. The
/// same `Project` struct round-trips through both.
@MainActor
final class APIClient {
    /// Top-level error surfaced to callers. Each case carries
    /// enough context to drive a toast message.
    enum APIError: Error, LocalizedError {
        case notAuthenticated
        case http(status: Int, code: String, message: String)
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in."
            case .http(_, _, let message):
                return message
            case .decoding(let err):
                return "Server response could not be parsed: \(err.localizedDescription)"
            case .transport(let err):
                return "Network error: \(err.localizedDescription)"
            }
        }
    }

    private let auth: AuthService
    private let session: URLSession
    private let baseURL: URL

    init(auth: AuthService, session: URLSession = .shared, baseURL: URL = ServerConfig.serverURL) {
        self.auth = auth
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: Encoders

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Endpoints

    func listProjects() async throws -> ProjectListResponse {
        try await request("GET", "/v1/projects", body: Optional<Empty>.none)
    }

    func getProject(id: UUID) async throws -> GetManifestResponse {
        try await request("GET", "/v1/projects/\(id.uuidString.lowercased())", body: Optional<Empty>.none)
    }

    /// Create-or-update a project on the server. `expectedRevision`
    /// is `nil` for first push (server creates the row), or the
    /// previous server revision for subsequent updates.
    @discardableResult
    func putProject(id: UUID,
                    project: Project,
                    expectedRevision: String?) async throws -> PutManifestResponse {
        let body = PutManifestRequest(project: project, expectedRevision: expectedRevision)
        return try await request("PUT",
                                  "/v1/projects/\(id.uuidString.lowercased())",
                                  body: body)
    }

    // MARK: Phase 2 — files (Cloudflare R2)

    /// Ask the server for a presigned R2 PUT URL the client can
    /// upload directly to. 15-min TTL on the URL.
    func getUploadUrl(projectId: UUID,
                      photoId: UUID,
                      kind: FileKind,
                      sizeBytes: Int,
                      sha256: String?,
                      contentType: String) async throws -> UploadUrlResponse {
        let body = UploadUrlRequest(
            photoId: photoId.uuidString.lowercased(),
            kind: kind,
            sizeBytes: sizeBytes,
            sha256: sha256,
            contentType: contentType
        )
        return try await request(
            "POST",
            "/v1/projects/\(projectId.uuidString.lowercased())/files/upload-url",
            body: body
        )
    }

    /// Record a successful upload in the server's `files` table.
    /// Called AFTER the R2 PUT succeeds.
    @discardableResult
    func commitUpload(projectId: UUID,
                      objectKey: String,
                      photoId: UUID,
                      kind: FileKind,
                      sizeBytes: Int,
                      sha256: String?) async throws -> CommitUploadResponse {
        let body = CommitUploadRequest(
            objectKey: objectKey,
            photoId: photoId.uuidString.lowercased(),
            kind: kind,
            sizeBytes: sizeBytes,
            sha256: sha256
        )
        return try await request(
            "POST",
            "/v1/projects/\(projectId.uuidString.lowercased())/files/commit",
            body: body
        )
    }

    /// Ask the server which of the given object keys are already in
    /// R2. Used at launch to skip re-uploads.
    func syncFilesCheck(objectKeys: [String]) async throws -> SyncFilesCheckResponse {
        try await request(
            "POST",
            "/v1/sync/files/check",
            body: SyncFilesCheckRequest(objectKeys: objectKeys)
        )
    }

    // MARK: Phase 4 — App-wide config sync (Build #5.36.1)

    /// Bulk fetch of every known `app_config` key. Called at launch
    /// so the device's local tag library + AI rules template can be
    /// reconciled with whatever the team's other devices have pushed
    /// while this device was offline. Missing keys are absent from
    /// the returned `entries` map — the caller treats those as
    /// "fall back to local" rather than empty.
    func getAppConfigBundle() async throws -> AppConfigBundleResponse {
        try await request("GET", "/v1/config", body: Optional<Empty>.none)
    }

    /// Push a tag library to the server. `expectedRevision` is `nil`
    /// on first push for this team, otherwise the revision from the
    /// most recent bundle fetch. Mismatch → 409 so the caller pulls
    /// + merges rather than clobbering newer edits the other
    /// platform may have made.
    @discardableResult
    func putTagLibrary(_ library: TagLibrary,
                       expectedRevision: String?) async throws -> AppConfigPutResponse {
        let body = AppConfigPutTagLibraryRequest(
            value: library,
            expectedRevision: expectedRevision
        )
        return try await request("PUT", "/v1/config/tagLibrary", body: body)
    }

    /// Push an AI rules template to the server. Wraps the bare string
    /// in `{text: …}` to match the shared `AIRulesTemplate` wire
    /// shape declared in `packages/shared/src/appConfig.ts`.
    @discardableResult
    func putAIRulesTemplate(_ text: String,
                            expectedRevision: String?) async throws -> AppConfigPutResponse {
        let body = AppConfigPutAIRulesTemplateRequest(
            value: AIRulesTemplateWire(text: text),
            expectedRevision: expectedRevision
        )
        return try await request("PUT", "/v1/config/aiRulesTemplate", body: body)
    }

    // MARK: Phase 4 — AI tagging proxy (Build #5.32.1)

    /// Forward an AI-tagging call through the Forensic backend. The
    /// server fetches the photo bytes from R2, calls Anthropic with the
    /// team key, and returns the concatenated text response. Parsing of
    /// that text into a `Result` happens client-side (in
    /// `ClaudeTaggingService.parseResult(fromText:)`) so the server can
    /// stay a thin pass-through.
    func tagPhoto(projectId: UUID,
                  photoId: UUID,
                  model: String,
                  systemPrompt: String,
                  userText: String,
                  maxTokens: Int? = nil) async throws -> AITagPhotoResponse {
        let body = AITagPhotoRequest(
            projectId: projectId.uuidString.lowercased(),
            photoId: photoId.uuidString.lowercased(),
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxTokens: maxTokens
        )
        return try await request("POST", "/v1/ai/tag-photo", body: body)
    }

    // MARK: Direct PUT to R2

    /// Upload bytes to an R2 presigned URL. No auth header — the
    /// signed query string IS the auth. The Content-Type MUST match
    /// what was passed to `getUploadUrl(contentType:)` or the
    /// signature won't validate.
    func uploadBytesToPresignedURL(_ url: URL,
                                    data: Data,
                                    contentType: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.http(
                status: code,
                code: "r2_upload_failed",
                message: "R2 upload returned \(code)"
            )
        }
    }

    // MARK: Core

    private struct Empty: Encodable {}

    private func request<TBody: Encodable, TResp: Decodable>(
        _ method: String,
        _ path: String,
        body: TBody?
    ) async throws -> TResp {
        guard let jwt = auth.currentJWT else {
            throw APIError.notAuthenticated
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            do {
                urlRequest.httpBody = try makeEncoder().encode(body)
            } catch {
                throw APIError.decoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, code: "unknown", message: "Non-HTTP response")
        }

        // 401: token is invalid or revoked. We deliberately do NOT
        // auto-signout here. A single transient 401 — from a token
        // rotation race, a brief Supabase outage, or a server-side
        // hiccup — should not cascade-clear the local session and
        // kick the user back to sign-in. The user is signed in
        // until they explicitly tap sign-out. If the token is
        // genuinely revoked, every subsequent call will surface
        // this same error message and they'll choose to re-auth.
        // This also keeps iOS isolated from web sign-out events:
        // even if the web's `scope: 'local'` logout briefly
        // affects iOS via some Supabase-side path, iOS won't
        // self-destruct.
        if httpResponse.statusCode == 401 {
            print("[APIClient] 401 on \(method) \(path) — surfacing as 'sign-in expired' (not auto-signing-out)")
            throw APIError.http(status: 401, code: "unauthorized", message: "Sign-in expired. Tap sign-out and back in if this persists.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // Try to surface the server's `ApiError` envelope.
            let errorEnvelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data)
            throw APIError.http(
                status: httpResponse.statusCode,
                code: errorEnvelope?.error ?? "unknown",
                message: errorEnvelope?.message ?? "Server returned \(httpResponse.statusCode)"
            )
        }

        do {
            return try makeDecoder().decode(TResp.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

// MARK: Wire shapes

/// Server's error envelope shape. Used to surface useful messages
/// from non-2xx responses. Optional-rich so we don't crash on a
/// truncated / unexpected error body.
private struct ServerErrorEnvelope: Decodable {
    let error: String?
    let message: String?
}

/// Request body for `PUT /v1/projects/:id`.
///
/// Custom `encode(to:)` so `expectedRevision: nil` emits an
/// explicit `null` on the wire (instead of being omitted). The
/// server's zod schema declares the field as `z.string().nullable()`
/// which accepts string-or-null but NOT undefined / missing.
struct PutManifestRequest: Encodable {
    let project: Project
    let expectedRevision: String?

    private enum CodingKeys: String, CodingKey {
        case project, expectedRevision
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(project, forKey: .project)
        try c.encode(expectedRevision, forKey: .expectedRevision)
    }
}

struct PutManifestResponse: Decodable {
    let revision: String
}

struct ProjectListResponse: Decodable {
    let projects: [ProjectListItem]
}

struct ProjectListItem: Decodable, Identifiable {
    let id: UUID
    let name: String
    let manifestSchemaVersion: Int
    let revision: String
    let createdAt: Date
    let updatedAt: Date
}

struct GetManifestResponse: Decodable {
    let project: Project
    let revision: String
}

// MARK: - Phase 2: Files (Cloudflare R2)

/// Categories of binary stored in R2. Must match the server's
/// FileKind in `packages/shared/src/api.ts` and the SQL CHECK
/// constraint in migration 0003. Wire format is the raw string.
enum FileKind: String, Codable {
    case photo
    case thumb
    case markupPng = "markup_png"
    case markupDrawing = "markup_drawing"
    case plan
}

/// Max bytes per upload (50 MB). Matches `FILE_MAX_BYTES` server-side.
let FILE_MAX_BYTES = 50 * 1024 * 1024

struct UploadUrlRequest: Encodable {
    let photoId: String
    let kind: FileKind
    let sizeBytes: Int
    let sha256: String?
    let contentType: String
}

struct UploadUrlResponse: Decodable {
    let uploadUrl: String
    let objectKey: String
    let expiresAt: String
}

struct CommitUploadRequest: Encodable {
    let objectKey: String
    let photoId: String
    let kind: FileKind
    let sizeBytes: Int
    let sha256: String?
}

struct CommitUploadResponse: Decodable {
    let ok: Bool
}

struct SyncFilesCheckRequest: Encodable {
    let objectKeys: [String]
}

struct SyncFilesCheckResponse: Decodable {
    let existing: [String]
}

struct PhotoUrlResponse: Decodable {
    let url: String
    let expiresAt: String
}

// MARK: - Phase 4: AI tagging proxy

/// Request body for `POST /v1/ai/tag-photo`. Mirrors
/// `AITagPhotoRequest` in `packages/shared/src/api.ts`.
struct AITagPhotoRequest: Encodable {
    let projectId: String
    let photoId: String
    let model: String
    let systemPrompt: String
    let userText: String
    let maxTokens: Int?
}

/// Response shape for `POST /v1/ai/tag-photo`. Mirrors
/// `AITagPhotoResponse` in `packages/shared/src/api.ts`.
struct AITagPhotoResponse: Decodable {
    let rawText: String
    let usage: Usage
    let durationMs: Int
    let model: String

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
    }
}

// MARK: - Phase 4: App-wide config sync (Build #5.36.1)

/// Server-side wrapper for the AI rules template. iOS keeps the
/// rules as a bare `String`; the wire shape wraps it in `{text: …}`
/// to match `AIRulesTemplate` in `packages/shared/src/appConfig.ts`
/// so the shared type can grow sibling fields without re-versioning
/// the wire.
struct AIRulesTemplateWire: Codable {
    let text: String
}

/// One entry in the `GET /v1/config` bundle response. The `value`
/// field shape depends on the key (TagLibrary for `tagLibrary`,
/// `{text: …}` for `aiRulesTemplate`). We decode the value lazily
/// via `decodeValue(as:)` so a future server-side key the iOS
/// client doesn't know about doesn't fail the whole bundle decode.
struct AppConfigBundleEntry: Decodable {
    let key: String
    let value: AnyDecodable
    let revision: String
    let updatedAt: String
}

/// Bulk response for `GET /v1/config`. Keys absent from the server
/// (i.e. nothing pushed yet) are absent from `entries` — the caller
/// treats those as "keep local."
struct AppConfigBundleResponse: Decodable {
    let entries: [String: AppConfigBundleEntry]
}

/// Common response shape for every successful `PUT /v1/config/:key`.
struct AppConfigPutResponse: Decodable {
    let revision: String
}

/// PUT body for `tagLibrary`. Custom Encodable so `expectedRevision:
/// nil` emits an explicit `null` (the server's zod accepts
/// string-or-null but NOT undefined), same discipline as
/// `PutManifestRequest`.
struct AppConfigPutTagLibraryRequest: Encodable {
    let value: TagLibrary
    let expectedRevision: String?

    private enum CodingKeys: String, CodingKey {
        case value, expectedRevision
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(expectedRevision, forKey: .expectedRevision)
    }
}

/// PUT body for `aiRulesTemplate`.
struct AppConfigPutAIRulesTemplateRequest: Encodable {
    let value: AIRulesTemplateWire
    let expectedRevision: String?

    private enum CodingKeys: String, CodingKey {
        case value, expectedRevision
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(expectedRevision, forKey: .expectedRevision)
    }
}

/// Box around an arbitrary JSON value so we can postpone the
/// per-key decode of `AppConfigBundleEntry.value` until the caller
/// dispatches on the key. Stores the raw bytes so any Decodable
/// shape can be re-decoded from them.
struct AnyDecodable: Decodable {
    /// JSON bytes for the value. Decoded into a concrete type by
    /// the caller (`decode(as:)`).
    let raw: Data

    init(from decoder: Decoder) throws {
        // The cleanest way to capture an unknown JSON sub-tree as
        // bytes is to decode into the dynamic `Any`-ish JSON
        // hierarchy (Dictionary / Array / scalar), then re-encode.
        // Using `JSONDecoder().decode(JSONValue.self, …)` from the
        // single-value container preserves the exact shape.
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        self.raw = try JSONEncoder().encode(value)
    }

    func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: raw)
    }
}

/// Recursive enum over the JSON type hierarchy. Used by
/// `AnyDecodable` so an unknown jsonb value can be captured
/// losslessly and re-decoded into a concrete Decodable later.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b); return
        }
        if let n = try? container.decode(Double.self) {
            self = .number(n); return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s); return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a); return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o); return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
