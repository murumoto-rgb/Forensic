import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Calls the Anthropic Messages API with a downsampled photo and asks
/// Claude to emit forensic-vocabulary tags. The single AI tagging path
/// in the app — on-device classification was tried and dropped because
/// the generic ImageNet-style labels couldn't carry forensic vocabulary.
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
    /// `Photo.tags` via the existing TagSuggestion/Tag pipeline; the full
    /// schema-2 analysis is persisted on `Photo.aiAnalysis` and drives the
    /// new editor / filter / batch-summary surfaces.
    ///
    /// On a JSON parse failure the service still returns a `Result` —
    /// `analysis.parseFailed = true`, `analysis.rawResponse` carries the
    /// offending text, and `suggestions` is empty. The caller persists
    /// the failed analysis on the photo and continues the batch.
    struct Result: Sendable {
        let suggestions: [TagSuggestion]
        let analysis: AIPhotoAnalysis
    }

    static func tag(imageURL: URL,
                    photoID: String = "",
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
            "max_tokens": 1500,
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
                            "text": userPrompt(photoID: photoID)
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
        return try parseResult(from: data, fallbackPhotoID: photoID)
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

    /// Short reinforcement appended after the user's guide. The schema-2
    /// prompt itself specifies the JSON shape in detail; this contract just
    /// re-emphasises "no code fences, no prose" because Claude occasionally
    /// adds them despite the guide's instructions.
    private static let outputContract = """
    OUTPUT FORMAT (reinforces the guide above; do not contradict it):

    Emit ONLY the single JSON object described in the guide. No prose \
    before or after, no markdown code fences, no commentary, no \
    explanation. Start your response with `{` and end it with `}`.
    """

    /// Per-photo user message. The photo's filename (when known) is passed
    /// in so the model can echo it back as `photo_id`, which the rest of
    /// the pipeline uses to correlate batch-summary entries with photos.
    private static func userPrompt(photoID: String) -> String {
        let trimmed = photoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let idLine = trimmed.isEmpty
            ? ""
            : "The photo_id for this image is \"\(trimmed)\". Use that exact value in the JSON.\n\n"
        return idLine + """
        Analyse this site photo using the schema and rules in the system \
        message above. Return only the JSON object — no prose, no code \
        fences.
        """
    }

    // MARK: - Response parsing

    private struct AnthropicResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    /// Confidence assigned to every tag Claude emits. The schema doesn't
    /// ask Claude to qualify its individual tag picks (per-tag probability)
    /// — `aiAnalysis.confidence` covers that at the photo level. We use a
    /// single high score that comfortably clears the default 50% threshold.
    private static let bucketConfidence: Double = 0.9

    /// Decode the Anthropic envelope, extract the JSON object Claude
    /// emitted, decode it, validate it, and convert it into a `Result`.
    /// On a parse failure the function still returns a `Result` — the
    /// analysis is empty, `parseFailed` is true, and `rawResponse` carries
    /// the original text — so the batch loop can persist it and continue
    /// rather than aborting on a single bad photo.
    ///
    /// HTTP / network errors still throw (those are batch-control signals
    /// that the retry loop above catches). Only schema/JSON failures
    /// degrade to a soft `parseFailed` result.
    private static func parseResult(from data: Data,
                                     fallbackPhotoID: String) throws -> Result {
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
            return softFailure(rawResponse: "(empty content)",
                               photoID: fallbackPhotoID,
                               reason: "Claude returned no text content.")
        }

        // Strip code fences first, then take the slice between the first
        // `{` and last `}`. Tolerates models that wrap JSON in ```json …
        // fences or add a stray "Here's the analysis:" prefix.
        let stripped = stripCodeFences(text)
        guard let braceStart = stripped.firstIndex(of: "{"),
              let braceEnd   = stripped.lastIndex(of: "}"),
              braceStart <= braceEnd else {
            return softFailure(rawResponse: text,
                               photoID: fallbackPhotoID,
                               reason: "No JSON object found in Claude's response.")
        }
        let jsonSlice = String(stripped[braceStart...braceEnd])
        guard let bytes = jsonSlice.data(using: .utf8) else {
            return softFailure(rawResponse: text,
                               photoID: fallbackPhotoID,
                               reason: "JSON slice was not valid UTF-8.")
        }

        let payload: ClaudePayload
        do {
            payload = try JSONDecoder().decode(ClaudePayload.self, from: bytes)
        } catch {
            return softFailure(rawResponse: text,
                               photoID: fallbackPhotoID,
                               reason: "JSON decode failed: \(error.localizedDescription)")
        }

        // Build the analysis. `parseFailed = false` here — even if the
        // validator finds issues, the JSON itself parsed cleanly.
        let analysis = AIPhotoAnalysis(
            photoID: payload.resolvedPhotoID(fallback: fallbackPhotoID),
            primaryTags: payload.primary_tags ?? [],
            secondaryTagsByPrimary: payload.secondary_tags_by_primary ?? [:],
            locationInferred: payload.location_inferred?.trimmed ?? "",
            orientationCue: payload.orientation_cue?.trimmed ?? "",
            scalePresent: payload.scale_present ?? .unknown(""),
            measurementVisible: payload.measurement_visible?.trimmed.nonEmpty,
            summaryObservation: payload.summary_observation?.trimmed ?? "",
            captionDraft: payload.caption_draft?.trimmed ?? "",
            recommendedUse: payload.recommended_use ?? .unknown(""),
            confidence: payload.confidence ?? .unknown(""),
            confidenceNote: payload.confidence_note?.trimmed ?? "",
            likelyCompanion: payload.likely_companion ?? .unknown(""),
            reviewerFlag: payload.reviewer_flag?.trimmed ?? "",
            validationErrors: [],   // filled by validator below
            rawResponse: text,
            parseFailed: false
        )

        var validated = analysis
        validated.validationErrors = AIResponseValidator.validate(validated)

        return Result(suggestions: suggestions(from: validated),
                      analysis: validated)
    }

    /// Build the soft-failure result returned when JSON decoding fails.
    /// Empty analysis with `parseFailed = true` and the raw response
    /// captured so the user can revisit it later.
    private static func softFailure(rawResponse: String,
                                     photoID: String,
                                     reason: String) -> Result {
        var failed = AIPhotoAnalysis.empty
        failed.photoID = photoID
        failed.rawResponse = rawResponse
        failed.parseFailed = true
        failed.validationErrors = [reason]
        #if DEBUG
        print("Claude parse failure for \(photoID): \(reason)")
        #endif
        return Result(suggestions: [], analysis: failed)
    }

    /// Convert the validated analysis into the existing TagSuggestion
    /// pipeline so the rest of the app's tag UI works unchanged. Each
    /// primary becomes a primary-level suggestion (parentTag = nil), each
    /// non-"None" secondary becomes a secondary-level suggestion linked
    /// back to its primary via parentTag.
    private static func suggestions(from a: AIPhotoAnalysis) -> [TagSuggestion] {
        var out: [TagSuggestion] = []
        for primary in a.primaryTags {
            let pTrim = stripLeadingNumber(
                primary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !pTrim.isEmpty else { continue }
            out.append(TagSuggestion(
                label: pTrim,
                confidence: bucketConfidence,
                source: .claude,
                parentTag: nil
            ))
            // Match the secondary lookup against both the original key Claude
            // returned and the normalised primary, so a numbered key like
            // "1. Drainage / Grading" still finds its secondaries even after
            // the suggestion's parentTag has been cleaned up.
            let key = a.secondaryTagsByPrimary.keys.first {
                let normalised = stripLeadingNumber($0).lowercased()
                return $0.lowercased() == pTrim.lowercased()
                    || normalised == pTrim.lowercased()
            }
            for sec in a.secondaryTagsByPrimary[key ?? ""] ?? [] {
                let sTrim = sec.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sTrim.isEmpty, sTrim.lowercased() != "none" else { continue }
                out.append(TagSuggestion(
                    label: sTrim,
                    confidence: bucketConfidence,
                    source: .claude,
                    parentTag: pTrim
                ))
            }
        }
        return out
    }

    /// Strip a leading "N. " (one or more digits + period + optional spaces)
    /// from a primary tag name. The forensic guide used to list primaries
    /// with numbers, and Claude sometimes echoed those numbers back into
    /// `primary_tags` — the result was duplicate tags differing only by the
    /// "N. " prefix. Defensive: even though the prompt no longer numbers
    /// primaries, this guarantees that a future model variant that slips one
    /// in won't recreate the bug.
    private static func stripLeadingNumber(_ s: String) -> String {
        guard let match = s.range(
            of: #"^\d+\.\s*"#,
            options: .regularExpression
        ) else { return s }
        return String(s[match.upperBound...])
    }

    /// Shape of the JSON object the schema-2 prompt asks Claude to emit.
    /// Every field optional so a missing key in the response doesn't crash
    /// decoding — the validator surfaces missing-required-field issues
    /// after-the-fact.
    private struct ClaudePayload: Decodable {
        let photo_id: String?
        let primary_tags: [String]?
        let secondary_tags_by_primary: [String: [String]]?
        let location_inferred: String?
        let orientation_cue: String?
        let scale_present: ScalePresent?
        let measurement_visible: String?
        let summary_observation: String?
        let caption_draft: String?
        let recommended_use: RecommendedUse?
        let confidence: Confidence?
        let confidence_note: String?
        let likely_companion: LikelyCompanion?
        let reviewer_flag: String?

        func resolvedPhotoID(fallback: String) -> String {
            let echoed = photo_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return echoed.isEmpty ? fallback : echoed
        }
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
    /// in C). The thumbnail is redrawn into an opaque RGB context before
    /// encoding so ImageIO doesn't carry a useless alpha channel through the
    /// JPEG path — JPEG can't store alpha and the premultiplied buffer would
    /// double the encode-time memory cost.
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
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        guard let opaque = makeOpaqueRGB(from: thumb) else { return nil }

        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buf, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, opaque, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }

    /// Redraw `image` into an opaque sRGB bitmap context so the resulting
    /// CGImage has no alpha channel. Lets `CGImageDestinationAddImage`
    /// encode straight to JPEG without ImageIO logging an `AlphaPremulLast`
    /// warning and without keeping a 4-byte-per-pixel premultiplied buffer
    /// alive during encode.
    private static func makeOpaqueRGB(from image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        // 8-bit RGBA with the alpha channel ignored = opaque RGB packed in
        // 4 bytes/pixel. The "X" alpha tells CG to skip the alpha byte
        // entirely — JPEG output sees no alpha at all.
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
              | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

private extension String {
    /// Whitespace-trimmed copy. Used when normalising every string field
    /// pulled out of the Claude payload before it lands in the analysis
    /// struct.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Returns nil for empty strings, the receiver otherwise. Used so an
    /// optional chain like `payload.measurement_visible?.trimmed.nonEmpty`
    /// resolves to nil for both missing-and blank-string responses.
    var nonEmpty: String? { isEmpty ? nil : self }
}
