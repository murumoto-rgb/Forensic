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

    static func tag(imageURL: URL) async throws -> [TagSuggestion] {
        guard let key = KeychainStore.loadAnthropicKey(), !key.isEmpty else {
            throw Error.missingAPIKey
        }
        guard let jpegData = downsampleAsJPEG(url: imageURL,
                                                maxDimension: maxImageDimension,
                                                quality: 0.85) else {
            throw Error.imageEncodingFailed
        }
        let base64 = jpegData.base64EncodedString()

        let body: [String: Any] = [
            "model":      model,
            "max_tokens": 600,
            "system":     systemPrompt,
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
        req.timeoutInterval = 30

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

    private static let systemPrompt = """
    You tag forensic site-documentation photographs. The photographer is an \
    inspector capturing damage, conditions, building components, or scene \
    overviews for a report.

    Look at the image and identify every relevant forensic tag. Draw from \
    these categories — but you may also use other concise forensic terms \
    when none of these fit:

    Damage type: water damage, mold, fire damage, smoke damage, structural \
    crack, settlement crack, rot, leak, impact damage, vandalism, missing \
    component, deterioration

    Material: drywall, concrete, brick, wood, hardwood floor, tile, carpet, \
    vinyl, metal, glass, asphalt, plaster, stone, shingle, siding, \
    insulation

    Room or area: kitchen, bathroom, bedroom, living room, dining room, \
    basement, attic, garage, hallway, stairs, exterior, roof, closet, \
    laundry room, yard, deck

    Building system or component: HVAC, plumbing, electrical, foundation, \
    framing, flooring, ceiling, wall, window, door, fireplace, water \
    heater, appliance, gutter, fence

    Severity (only when damage is clearly visible): minor, moderate, severe

    Output ONLY a JSON array with no surrounding prose, code fences, or \
    explanation. Each element must be an object with exactly two keys:

      {"label": "<tag>", "confidence": <0.0–1.0>}

    Use lower-case labels with spaces (not underscores). Limit to the 8 \
    most relevant tags. Do not invent damage if the photo only shows an \
    overview.
    """

    private static let userPrompt = """
    Tag this forensic site photo. Return only the JSON array.
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
