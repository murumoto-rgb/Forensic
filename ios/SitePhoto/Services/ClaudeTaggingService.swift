import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Calls the Anthropic Messages API with a downsampled photo and asks
/// Claude to emit forensic-vocabulary tags. Used as the on-demand AI
/// backend; for free, on-device classification we use `VisionTaggingService`.
enum ClaudeTaggingService {

    /// Errors surfaced to the UI. The user sees the rawValue.
    enum Error: Swift.Error, LocalizedError {
        case missingAPIKey
        case imageEncodingFailed
        case network(String)
        case http(status: Int, body: String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an Anthropic API key in Settings before using AI tagging."
            case .imageEncodingFailed:
                return "Couldn't read the photo for analysis."
            case .network(let m):
                return "Network error: \(m)"
            case .http(let status, let body):
                return "Anthropic API error (\(status)): \(body.prefix(200))"
            case .malformedResponse(let m):
                return "Couldn't read the AI response: \(m)"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let model = "claude-sonnet-4-6"
    /// 1024 px on the longest side keeps image-token cost in the $0.003–
    /// $0.005 range while preserving enough detail for damage recognition.
    private static let maxImageDimension: CGFloat = 1024

    /// Result returned by a single Claude vision call. Tags flow into
    /// `Photo.tags` via the existing TagSuggestion/Tag pipeline; metadata
    /// (severity, observation, follow-up) is stored on the `Photo` for
    /// display in the tag editor.
    struct Result: Sendable {
        let suggestions: [TagSuggestion]
        let metadata: Metadata
    }

    struct Metadata: Sendable {
        let primaryCategory: String?
        let severity: String?
        let observation: String?
        let followUp: String?
        /// Free-form per-photo confidence label ("High" / "Medium" / "Low")
        /// — kept for backward compatibility with prompts that ask for it.
        /// The bucket prompt doesn't populate this.
        let confidenceLabel: String?
    }

    static func tag(imageURL: URL,
                    instructions: String? = nil) async throws -> Result {
        guard let key = KeychainStore.loadAnthropicKey(), !key.isEmpty else {
            throw Error.missingAPIKey
        }
        guard let jpegData = downsampleAsJPEG(url: imageURL,
                                                maxDimension: maxImageDimension,
                                                quality: 0.85) else {
            throw Error.imageEncodingFailed
        }
        let base64 = jpegData.base64EncodedString()

        // Build the system message as a content-blocks array so we can attach
        // `cache_control` to the (long, stable) instructions block. With
        // ephemeral caching enabled, every photo after the first in a 5-min
        // window pays only ~10% of the prompt-token cost — a big win when
        // batch-tagging dozens of photos with the long forensic guide.
        let guide = (instructions?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? AIInstructions.defaultText

        let cachedSystemText = systemPreamble + "\n\n" + guide + "\n\n" + outputContract

        let body: [String: Any] = [
            "model":      model,
            "max_tokens": 800,
            "system": [
                [
                    "type": "text",
                    "text": cachedSystemText,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type":       "base64",
                                "media_type": "image/jpeg",
                                "data":       base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key,           forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion,    forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload
        req.timeoutInterval = 60

        let data = try await sendWithRetry(req)
        return try parseResult(from: data)
    }

    /// Send the request, retrying on 429 (rate limit) and 5xx (transient
    /// server errors) with exponential backoff. Honours the `Retry-After`
    /// header when present. Other 4xx responses fail immediately — they
    /// won't fix themselves.
    private static func sendWithRetry(_ req: URLRequest,
                                       maxRetries: Int = 4) async throws -> Data {
        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                // Network-class error — retry a couple of times for transient
                // blips (Wi-Fi handoff, DNS hiccup) before giving up.
                if attempt < maxRetries {
                    try await Task.sleep(for: .seconds(backoffSeconds(attempt: attempt)))
                    attempt += 1
                    continue
                }
                throw Error.network(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw Error.network("No HTTP response")
            }
            if http.statusCode == 200 {
                return data
            }

            let retryable = (http.statusCode == 429) || (http.statusCode >= 500 && http.statusCode < 600)
            if retryable && attempt < maxRetries {
                let delay = retryAfterSeconds(in: http) ?? backoffSeconds(attempt: attempt)
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
                continue
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: http.statusCode, body: bodyStr)
        }
    }

    /// Anthropic returns Retry-After either as integer seconds or as an
    /// HTTP-date. We only handle the seconds form — good enough for the
    /// rate-limit case we see in practice.
    private static func retryAfterSeconds(in http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw) else { return nil }
        return min(seconds, 30)  // cap so a misconfigured response can't stall the batch forever
    }

    /// 1s → 2s → 4s → 8s, with a small random jitter so 5 concurrent
    /// requests hitting the same 429 don't all retry in lock-step.
    private static func backoffSeconds(attempt: Int) -> Double {
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        return base + jitter
    }

    // MARK: - Prompt

    /// Short framing prepended to the user's tagging guide. Sets the role
    /// without prescribing vocabulary — the project guide does that.
    private static let systemPreamble = """
    You are an AI assistant tagging forensic site-investigation \
    photographs. The user has supplied a project-specific tagging guide \
    below. Read it carefully and use its vocabulary, categories, and tone \
    of voice when describing what you see.
    """

    /// Strict output contract appended after the user's guide. Emphasises
    /// the "regardless of what the guide says" override so editing the
    /// project instructions can't accidentally break parsing.
    private static let outputContract = """
    OUTPUT FORMAT (this overrides any conflicting format instructions in \
    the tagging guide above — the guide above describes the tagging \
    *intent*; this section describes the literal output you must emit):

    Output ONLY a single JSON object. No prose, no code fences, no \
    explanation, no leading or trailing text.

    The object must have exactly these keys:

      {
        "buckets":  ["<exact bucket name>", ...],   // 1–2 entries
        "severity": "<None|Minor|Moderate|Significant|Severe|Cannot Determine>"
      }

    Rules:
      - Use ONLY bucket names exactly as listed in the guide above. Do \
    not paraphrase, abbreviate, or invent new buckets. Match casing and \
    punctuation (e.g. "Foundation or slab crack", not "foundation crack").
      - Use no more than 2 buckets per photo unless the photo clearly \
    shows multiple unrelated conditions.
      - `severity` is one of the six allowed values, spelled exactly.
      - Do not include any other keys. No `confidence`, `observation`, \
    `recommended_follow_up`, or any other field — those are not part of \
    this contract.
    """

    private static let userPrompt = """
    Categorize this site photo using the project's tagging guide. Return \
    only the JSON object, nothing else.
    """

    // MARK: - Response parsing

    private struct AnthropicResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    /// Shape of the JSON object we ask Claude to emit per photo. All fields
    /// optional in the decoder so a missing/extra key in Claude's output
    /// doesn't blow up the whole response.
    private struct ClaudePayload: Decodable {
        let buckets: [String]?
        let severity: String?
    }

    /// Confidence assigned to every bucket Claude emits. The bucket prompt
    /// doesn't ask Claude to qualify its picks — it's a controlled
    /// categorisation rather than a probabilistic finding — so we use a
    /// single high score that comfortably clears the default 50% threshold.
    private static let bucketConfidence: Double = 0.9

    private static func parseResult(from data: Data) throws -> Result {
        let envelope: AnthropicResponse
        do {
            envelope = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw Error.malformedResponse("envelope: \(error)")
        }
        let text = envelope.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
        guard !text.isEmpty else {
            throw Error.malformedResponse("empty content")
        }

        // Claude sometimes wraps JSON in code fences despite the system
        // prompt asking it not to. Strip ``` fences and surrounding prose
        // before decoding.
        let stripped = stripCodeFences(text)
        guard let braceStart = stripped.firstIndex(of: "{"),
              let braceEnd   = stripped.lastIndex(of: "}"),
              braceStart <= braceEnd else {
            throw Error.malformedResponse("no object found in: \(stripped.prefix(160))")
        }
        let jsonSlice = String(stripped[braceStart...braceEnd])
        guard let bytes = jsonSlice.data(using: .utf8) else {
            throw Error.malformedResponse("non-utf8 object slice")
        }

        let payload: ClaudePayload
        do {
            payload = try JSONDecoder().decode(ClaudePayload.self, from: bytes)
        } catch {
            throw Error.malformedResponse("object decode: \(error)")
        }

        var suggestions: [TagSuggestion] = []
        for raw in payload.buckets ?? [] {
            let bucket = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bucket.isEmpty else { continue }
            suggestions.append(TagSuggestion(
                label: bucket,
                confidence: bucketConfidence,
                source: .claude
            ))
        }

        let metadata = Metadata(
            primaryCategory: nil,
            severity:        payload.severity?.trimmingCharacters(in: .whitespacesAndNewlines),
            observation:     nil,
            followUp:        nil,
            confidenceLabel: nil
        )

        return Result(suggestions: suggestions, metadata: metadata)
    }

    private static func stripCodeFences(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "```json") { t.removeSubrange(t.startIndex..<r.upperBound) }
        else if let r = t.range(of: "```") { t.removeSubrange(t.startIndex..<r.upperBound) }
        if let r = t.range(of: "```", options: .backwards) {
            t.removeSubrange(r.lowerBound..<t.endIndex)
        }
        return t
    }

    // MARK: - Image downsampling

    /// Read the image at `url`, downsample to fit `maxDimension` on its long
    /// side, and re-encode as JPEG. Avoids loading the full-resolution photo
    /// into memory (`CGImageSourceCreateThumbnailAtIndex` does this work
    /// in C).
    private static func downsampleAsJPEG(url: URL,
                                          maxDimension: CGFloat,
                                          quality: CGFloat) -> Data? {
        let srcOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxDimension,
            kCGImageSourceCreateThumbnailWithTransform:   true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buf, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cg, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }
}
