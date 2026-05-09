import Foundation

struct Photo: Identifiable, Codable, Hashable {
    let id: UUID
    var sequenceNumber: Int
    var timestamp: Date
    var imageFilename: String
    var thumbnailFilename: String?
    var localXFeet: Double?
    var localYFeet: Double?
    var planPixelX: Double?
    var planPixelY: Double?
    var headingDegrees: Double?
    var positionSource: PositionSource
    var groupID: UUID?
    var isPrimary: Bool
    var cameraZoom: Double
    var lensName: String?
    var flashMode: FlashMode
    var aiDescription: String?
    /// Severity bucket Claude assigned to the most relevant distress in the
    /// photo. One of: None, Minor, Moderate, Significant, Severe, Cannot
    /// Determine. Stored verbatim so the UI can show it as Claude returned
    /// it.
    var aiSeverity: String?
    /// One-sentence report-style observation Claude wrote about the photo
    /// — uses cautious language ("visible", "appears", etc.).
    var aiObservation: String?
    /// One-sentence follow-up recommendation Claude wrote (e.g. "Correlate
    /// with elevation survey", "Field-measure crack width").
    var aiFollowUp: String?
    /// User-confirmed tags (what shows up on the row, in filters, in the PDF).
    /// Each carries a confidence — `1.0` for manually-typed/confirmed tags,
    /// the originating AI score for accepted suggestions. The threshold
    /// slider in Settings filters which of these actually render.
    var tags: [Tag]
    /// AI-generated tag candidates that haven't been confirmed yet. Persisted
    /// so the user can come back later and accept/reject without re-running
    /// the analysis. Empty array (not nil) when none are pending.
    var pendingSuggestions: [TagSuggestion]

    init(id: UUID = UUID(), sequenceNumber: Int, imageFilename: String) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.timestamp = Date()
        self.imageFilename = imageFilename
        self.thumbnailFilename = nil
        self.localXFeet = nil
        self.localYFeet = nil
        self.planPixelX = nil
        self.planPixelY = nil
        self.headingDegrees = nil
        self.positionSource = .none
        self.groupID = nil
        self.isPrimary = false
        self.cameraZoom = 1.0
        self.lensName = nil
        self.flashMode = .auto
        self.aiDescription = nil
        self.aiSeverity = nil
        self.aiObservation = nil
        self.aiFollowUp = nil
        self.tags = []
        self.pendingSuggestions = []
    }

    /// Tolerate manifests written before tags existed — decode the new fields
    /// as empty when missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                 = try c.decode(UUID.self,              forKey: .id)
        self.sequenceNumber     = try c.decode(Int.self,               forKey: .sequenceNumber)
        self.timestamp          = try c.decode(Date.self,              forKey: .timestamp)
        self.imageFilename      = try c.decode(String.self,            forKey: .imageFilename)
        self.thumbnailFilename  = try c.decodeIfPresent(String.self,   forKey: .thumbnailFilename)
        self.localXFeet         = try c.decodeIfPresent(Double.self,   forKey: .localXFeet)
        self.localYFeet         = try c.decodeIfPresent(Double.self,   forKey: .localYFeet)
        self.planPixelX         = try c.decodeIfPresent(Double.self,   forKey: .planPixelX)
        self.planPixelY         = try c.decodeIfPresent(Double.self,   forKey: .planPixelY)
        self.headingDegrees     = try c.decodeIfPresent(Double.self,   forKey: .headingDegrees)
        self.positionSource     = try c.decode(PositionSource.self,    forKey: .positionSource)
        self.groupID            = try c.decodeIfPresent(UUID.self,     forKey: .groupID)
        self.isPrimary          = try c.decode(Bool.self,              forKey: .isPrimary)
        self.cameraZoom         = try c.decode(Double.self,            forKey: .cameraZoom)
        self.lensName           = try c.decodeIfPresent(String.self,   forKey: .lensName)
        self.flashMode          = try c.decode(FlashMode.self,         forKey: .flashMode)
        self.aiDescription      = try c.decodeIfPresent(String.self,   forKey: .aiDescription)
        self.aiSeverity         = try c.decodeIfPresent(String.self,   forKey: .aiSeverity)
        self.aiObservation      = try c.decodeIfPresent(String.self,   forKey: .aiObservation)
        self.aiFollowUp         = try c.decodeIfPresent(String.self,   forKey: .aiFollowUp)
        // tags has shipped in two formats — legacy `[String]` (no
        // confidence) and the current `[Tag]`. Decode whichever the
        // manifest contains, treating legacy entries as confidence 1.0
        // (manual / confirmed) so they pass any threshold the user sets.
        if let typed = try? c.decode([Tag].self, forKey: .tags) {
            self.tags = typed
        } else if let legacy = try? c.decode([String].self, forKey: .tags) {
            self.tags = legacy.map { Tag(label: $0, confidence: 1.0) }
        } else {
            self.tags = []
        }
        self.pendingSuggestions = try c.decodeIfPresent([TagSuggestion].self,
                                                        forKey: .pendingSuggestions) ?? []
    }
}

/// A tag attached to a photo. `label` is the display string (case
/// preserved as the user / AI typed it). `confidence` is 1.0 for
/// manually-added tags and the originating AI score (0.0–1.0) for
/// accepted suggestions. A threshold slider in Settings filters which
/// tags actually render.
struct Tag: Codable, Hashable {
    var label: String
    var confidence: Double

    init(label: String, confidence: Double = 1.0) {
        self.label = label
        self.confidence = max(0, min(1, confidence))
    }
}

enum PositionSource: String, Codable, Hashable {
    case manual
    case gps
    case none
}

enum FlashMode: String, Codable, Hashable, CaseIterable {
    case auto
    case on
    case off
}

/// One AI-generated tag candidate awaiting user confirmation.
struct TagSuggestion: Codable, Hashable, Identifiable {
    var label: String
    var confidence: Double
    var source: TagSource

    var id: String { "\(source.rawValue):\(label.lowercased())" }
}

enum TagSource: String, Codable, Hashable {
    /// On-device Apple Vision (`VNClassifyImageRequest`). Generic and free.
    case vision
    /// Cloud Claude vision call. Forensic-aware but requires an API key.
    case claude
}
