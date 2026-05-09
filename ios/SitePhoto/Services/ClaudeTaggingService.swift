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

    static func tag(imageURL: URL,
                    instructions: String? = nil) async throws -> [TagSuggestion] {
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Error.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.network("No HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: http.statusCode, body: bodyStr)
        }

        return try parseSuggestions(from: data)
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
    /// project instructions can't accidentally break tag-array parsing.
    private static let outputContract = """
    OUTPUT FORMAT (this overrides any conflicting format instructions in \
    the tagging guide above):

    Output ONLY a JSON array. No prose, no code fences, no explanation, no \
    leading or trailing text.

    Each array element must be an object with exactly these two keys:

      {"label": "<tag>", "confidence": <0.0–1.0>}

    Tag rules:
      - Draw vocabulary from the families and categories in the guide \
    above. Use the exact tag identifiers it lists (e.g. \
    `interior_sheetrock_crack`, `crack_wider_at_bottom`) — these are the \
    canonical labels for this project.
      - When the guide doesn't have an exact tag for what you see, you may \
    introduce a concise compound tag in the same style (lowercase, \
    underscores between words, e.g. `crack_on_concrete_foundation`, \
    `water_damage_on_drywall_ceiling`). Always include the substrate or \
    location when describing damage so a reviewer can tell `crack on \
    concrete` apart from `crack on sheetrock`.
      - Limit to roughly 12 of the most relevant tags per photo. Don't \
    invent damage that isn't clearly visible.
      - Confidence reflects how clearly the feature is visible in the \
    photo, not how serious it is.
    """

    private static let userPrompt = """
    Tag this site photo using the project's tagging guide. Return only the \
    JSON array, nothing else.
    """

    // MARK: - Response parsing

    private struct AnthropicResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct LabelEntry: Decodable {
        let label: String
        let confidence: Double
    }

    private static func parseSuggestions(from data: Data) throws -> [TagSuggestion] {
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
        guard let bracketStart = stripped.firstIndex(of: "["),
              let bracketEnd   = stripped.lastIndex(of: "]"),
              bracketStart <= bracketEnd else {
            throw Error.malformedResponse("no array found in: \(stripped.prefix(120))")
        }
        let jsonSlice = String(stripped[bracketStart...bracketEnd])
        guard let bytes = jsonSlice.data(using: .utf8) else {
            throw Error.malformedResponse("non-utf8 array slice")
        }
        let entries: [LabelEntry]
        do {
            entries = try JSONDecoder().decode([LabelEntry].self, from: bytes)
        } catch {
            throw Error.malformedResponse("array decode: \(error)")
        }

        return entries
            .map { e in
                TagSuggestion(
                    label: e.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: max(0, min(1, e.confidence)),
                    source: .claude
                )
            }
            .filter { !$0.label.isEmpty }
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
