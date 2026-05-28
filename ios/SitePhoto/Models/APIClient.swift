import Foundation

/// Thin REST client for the Forensic Fastify server.
///
/// Authenticates every request with the current Supabase JWT
/// (read live from `AuthService.currentJWT`, so token refresh by
/// supabase-swift is picked up automatically). On 401 the client
/// calls `auth.signOut()` so the UI falls back to the sign-in
/// sheet — same pattern as the web's `api.ts`.
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

        // 401: token is invalid or revoked. Sign out so the UI
        // shows the sign-in sheet; the user signs in again with
        // a fresh session.
        if httpResponse.statusCode == 401 {
            Task { try? await auth.signOut() }
            throw APIError.http(status: 401, code: "unauthorized", message: "Sign-in expired. Please sign in again.")
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
